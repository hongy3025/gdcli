//! tokio HTTP server + 跨线程请求队列。
//!
//! ServerCore 是与 godot 无关的核心，可独立测试；GdApiServer (lib.rs) 是其 Gd 包装。

use crate::http::{parse_request, write_response, ParsedRequest};
use crate::queue::{HttpResponse, PendingMap, PendingRequest};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot};

const PORT_PROBE_LIMIT: u16 = 64;
const DEFAULT_TIMEOUT_MS: u64 = 30_000;
const ACCEPT_READ_TIMEOUT_MS: u64 = 5_000;

pub struct ServerCore {
    runtime: Option<Runtime>,
    shutdown_tx: Option<oneshot::Sender<()>>,
    in_rx: Option<mpsc::Receiver<PendingRequest>>,
    pending: PendingMap,
    actual_port: Option<u16>,
}

impl Default for ServerCore {
    fn default() -> Self {
        Self::new()
    }
}

impl ServerCore {
    pub fn new() -> Self {
        Self {
            runtime: None,
            shutdown_tx: None,
            in_rx: None,
            pending: PendingMap::default(),
            actual_port: None,
        }
    }

    /// 从 port_hint 逐个 +1 尝试，最多 64 次。成功返回端口；失败返回 Err。
    pub fn start(&mut self, port_hint: u16) -> Result<u16, String> {
        if self.runtime.is_some() {
            return Err("already running".into());
        }
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| format!("tokio rt: {}", e))?;

        // bind 同步完成（在 rt.block_on 中），便于上报实际端口
        let listener = rt.block_on(async move {
            for offset in 0..PORT_PROBE_LIMIT {
                let port = port_hint + offset;
                match TcpListener::bind(("127.0.0.1", port)).await {
                    Ok(l) => return Ok((l, port)),
                    Err(_) => continue,
                }
            }
            Err("no available port in probe range".to_string())
        });
        let (listener, port) = listener?;

        let (in_tx, in_rx) = mpsc::channel::<PendingRequest>(256);
        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();

        let timeout_ms: u64 = std::env::var("GDAPI_HANDLER_TIMEOUT_MS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(DEFAULT_TIMEOUT_MS);

        let id_counter = Arc::new(AtomicU64::new(1));
        rt.spawn(accept_loop(listener, in_tx, id_counter, timeout_ms, shutdown_rx));

        self.runtime = Some(rt);
        self.shutdown_tx = Some(shutdown_tx);
        self.in_rx = Some(in_rx);
        self.actual_port = Some(port);
        Ok(port)
    }

    pub fn stop(&mut self) {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(());
        }
        self.pending.drain_503();
        if let Some(rt) = self.runtime.take() {
            rt.shutdown_background();
        }
        self.in_rx = None;
        self.actual_port = None;
    }

    pub fn is_running(&self) -> bool {
        self.runtime.is_some()
    }

    pub fn port(&self) -> i32 {
        self.actual_port.map(|p| p as i32).unwrap_or(-1)
    }

    /// 主线程 poll：非阻塞 try_recv。返回原始 PendingRequest 供测试用。
    pub fn poll_request_raw(&mut self) -> Option<PendingRequest> {
        let rx = self.in_rx.as_mut()?;
        rx.try_recv().ok()
    }

    pub fn send_response_raw(
        &mut self,
        id: u64,
        status: u16,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
    ) {
        if let Some(tx) = self.pending.take(id) {
            let _ = tx.send(HttpResponse { status, headers, body });
        }
    }

    /// 供 GdApiServer 调用：poll 并把 resp_tx 转入 pending map，返回不含 resp_tx 的 view。
    pub fn poll_for_godot(&mut self) -> Option<RequestView> {
        let req = self.poll_request_raw()?;
        let id = req.id;
        self.pending.insert(id, req.resp_tx);
        Some(RequestView {
            id,
            method: req.method,
            path: req.path,
            headers: req.headers,
            body: req.body,
        })
    }
}

/// 给 GdApiServer 用的视图：剥离了 resp_tx，剩下纯数据。
pub struct RequestView {
    pub id: u64,
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

async fn accept_loop(
    listener: TcpListener,
    in_tx: mpsc::Sender<PendingRequest>,
    id_counter: Arc<AtomicU64>,
    timeout_ms: u64,
    mut shutdown_rx: oneshot::Receiver<()>,
) {
    loop {
        tokio::select! {
            _ = &mut shutdown_rx => break,
            accept = listener.accept() => {
                match accept {
                    Ok((stream, _)) => {
                        let tx = in_tx.clone();
                        let id_c = id_counter.clone();
                        tokio::spawn(handle_connection(stream, tx, id_c, timeout_ms));
                    }
                    Err(_) => break,
                }
            }
        }
    }
}

async fn handle_connection(
    mut stream: tokio::net::TcpStream,
    in_tx: mpsc::Sender<PendingRequest>,
    id_counter: Arc<AtomicU64>,
    timeout_ms: u64,
) {
    let mut buf = Vec::with_capacity(8192);
    let read_result = tokio::time::timeout(
        Duration::from_millis(ACCEPT_READ_TIMEOUT_MS),
        async {
            loop {
                let mut chunk = [0u8; 4096];
                let n = stream.read(&mut chunk).await?;
                if n == 0 {
                    return Ok::<(), std::io::Error>(());
                }
                buf.extend_from_slice(&chunk[..n]);
                match parse_request(&buf) {
                    Ok(Some(_)) => return Ok(()),
                    Ok(None) => continue,
                    Err(e) => return Err(e),
                }
            }
        },
    )
    .await;

    let parsed = match read_result {
        Ok(Ok(())) => parse_request(&buf),
        Ok(Err(e)) => Err(e),
        Err(_) => {
            let _ = stream
                .write_all(&write_response(400, &[], b"{\"error\":\"read timeout\"}"))
                .await;
            return;
        }
    };

    let req: ParsedRequest = match parsed {
        Ok(Some(r)) => r,
        Ok(None) => {
            let _ = stream
                .write_all(&write_response(400, &[], b"{\"error\":\"incomplete request\"}"))
                .await;
            return;
        }
        Err(e) => {
            let status = if e.to_string().contains("16 MiB") { 413 } else { 400 };
            let body = format!("{{\"error\":{:?}}}", e.to_string());
            let _ = stream.write_all(&write_response(status, &[], body.as_bytes())).await;
            return;
        }
    };

    let id = id_counter.fetch_add(1, Ordering::Relaxed);
    let (resp_tx, resp_rx) = oneshot::channel::<HttpResponse>();
    let pending = PendingRequest {
        id,
        method: req.method,
        path: req.path,
        headers: req.headers,
        body: req.body,
        resp_tx,
    };

    if in_tx.send(pending).await.is_err() {
        let _ = stream
            .write_all(&write_response(503, &[], b"{\"error\":\"server shutting down\"}"))
            .await;
        return;
    }

    let resp = match tokio::time::timeout(Duration::from_millis(timeout_ms), resp_rx).await {
        Ok(Ok(r)) => r,
        Ok(Err(_)) => HttpResponse {
            status: 503,
            headers: vec![],
            body: br#"{"error":"server dropped"}"#.to_vec(),
        },
        Err(_) => HttpResponse {
            status: 504,
            headers: vec![("content-type".into(), "application/json".into())],
            body: br#"{"error":"handler timeout"}"#.to_vec(),
        },
    };

    let bytes = write_response(resp.status, &resp.headers, &resp.body);
    let _ = stream.write_all(&bytes).await;
    let _ = stream.shutdown().await;
}
