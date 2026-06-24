//! tokio HTTP server + 跨线程请求队列。
//!
//! ServerCore 是与 godot 无关的核心，可独立测试；GdApiServer (lib.rs) 是其 Gd 包装。
//!
//! 核心架构：
//! - 使用 tokio 异步运行时处理 TCP 连接
//! - 请求通过 mpsc 通道从异步线程传递到主线程
//! - 响应通过 oneshot 通道从主线程返回到异步线程
//! - 支持端口探测：从指定端口开始逐个尝试，直到找到可用端口

use crate::http::{parse_request, write_response, ParsedRequest};
use crate::queue::{HttpResponse, PendingMap, PendingRequest};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot};

/// 端口探测上限：从 port_hint 开始最多尝试 64 个端口。
const PORT_PROBE_LIMIT: u16 = 64;

/// 默认请求处理超时时间（毫秒）。
const DEFAULT_TIMEOUT_MS: u64 = 30_000;

/// 接受连接后的读取超时时间（毫秒）。
const ACCEPT_READ_TIMEOUT_MS: u64 = 5_000;

/// HTTP 服务器核心结构体。
///
/// 与 Godot 无关的纯 Rust 实现，负责：
/// - 启动/停止 tokio 运行时
/// - 管理 TCP 监听器和连接处理
/// - 通过通道传递请求到主线程
/// - 管理待响应请求的映射表
pub struct ServerCore {
    /// tokio 异步运行时（None 表示服务器未启动）
    runtime: Option<Runtime>,
    /// 关闭信号发送器（发送后服务器停止接受新连接）
    shutdown_tx: Option<oneshot::Sender<()>>,
    /// 请求接收通道（从异步线程接收待处理请求）
    in_rx: Option<mpsc::Receiver<PendingRequest>>,
    /// 待响应请求映射表（ID → oneshot 发送器）
    pending: PendingMap,
    /// 实际监听的端口号
    actual_port: Option<u16>,
    /// 期望的认证 token（None 表示不校验）
    expected_token: Option<String>,
}

impl Default for ServerCore {
    fn default() -> Self {
        Self::new()
    }
}

impl ServerCore {
    /// 创建新的 ServerCore 实例（未启动状态）。
    pub fn new() -> Self {
        Self {
            runtime: None,
            shutdown_tx: None,
            in_rx: None,
            pending: PendingMap::default(),
            actual_port: None,
            expected_token: None,
        }
    }

    /// 启动 HTTP 服务器。
    ///
    /// 从 port_hint 开始逐个端口尝试绑定，最多尝试 PORT_PROBE_LIMIT 次。
    /// 成功后启动异步接受循环，返回实际监听的端口号。
    ///
    /// # Arguments
    /// * `port_hint` - 期望的起始端口号
    ///
    /// # Returns
    /// 实际监听的端口号
    ///
    /// # Errors
    /// - 服务器已在运行
    /// - tokio 运行时创建失败
    /// - 在探测范围内无可用端口
    pub fn start(&mut self, port_hint: u16, token: Option<String>) -> Result<u16, String> {
        if self.runtime.is_some() {
            return Err("already running".into());
        }
        self.expected_token = token;
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

        // 从环境变量读取超时配置，支持自定义
        let timeout_ms: u64 = std::env::var("GDAPI_HANDLER_TIMEOUT_MS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(DEFAULT_TIMEOUT_MS);

        let id_counter = Arc::new(AtomicU64::new(1));
        let expected_token = self.expected_token.clone();
        rt.spawn(accept_loop(listener, in_tx, id_counter, timeout_ms, shutdown_rx, expected_token));

        self.runtime = Some(rt);
        self.shutdown_tx = Some(shutdown_tx);
        self.in_rx = Some(in_rx);
        self.actual_port = Some(port);
        Ok(port)
    }

    /// 停止 HTTP 服务器。
    ///
    /// 发送关闭信号，清空待响应请求，关闭 tokio 运行时。
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

    /// 检查服务器是否正在运行。
    pub fn is_running(&self) -> bool {
        self.runtime.is_some()
    }

    /// 获取服务器监听的端口号。
    ///
    /// # Returns
    /// 端口号，服务器未启动时返回 -1
    pub fn port(&self) -> i32 {
        self.actual_port.map(|p| p as i32).unwrap_or(-1)
    }

    /// 主线程 poll：非阻塞 try_recv。返回原始 PendingRequest 供测试用。
    pub fn poll_request_raw(&mut self) -> Option<PendingRequest> {
        let rx = self.in_rx.as_mut()?;
        rx.try_recv().ok()
    }

    /// 发送 HTTP 响应（原始数据格式）。
    ///
    /// # Arguments
    /// * `id` - 请求 ID
    /// * `status` - HTTP 状态码
    /// * `headers` - 响应头列表
    /// * `body` - 响应体字节
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

    /// 供 GdApiServer 调用：poll 并把 resp_tx 转入 pending map，返回不含 resp_tx 的视图。
    ///
    /// 将内部的 PendingRequest 转换为 GDScript 友好的 RequestView，
    /// 同时将响应通道存入 pending 映射表，等待后续 send_response 调用。
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

/// 给 GdApiServer 用的请求视图：剥离了 resp_tx，剩下纯数据。
///
/// 这个结构体可以直接暴露给 GDScript，不包含 Rust 特有的通道类型。
pub struct RequestView {
    /// 请求 ID（用于发送响应）
    pub id: u64,
    /// HTTP 方法（GET、POST 等）
    pub method: String,
    /// 请求路径
    pub path: String,
    /// 请求头列表（键值对）
    pub headers: Vec<(String, String)>,
    /// 请求体字节
    pub body: Vec<u8>,
}

/// 异步接受循环：持续监听新连接，为每个连接生成处理任务。
///
/// 使用 tokio::select! 同时监听关闭信号和新连接。
async fn accept_loop(
    listener: TcpListener,
    in_tx: mpsc::Sender<PendingRequest>,
    id_counter: Arc<AtomicU64>,
    timeout_ms: u64,
    mut shutdown_rx: oneshot::Receiver<()>,
    expected_token: Option<String>,
) {
    loop {
        tokio::select! {
            _ = &mut shutdown_rx => break,
            accept = listener.accept() => {
                match accept {
                    Ok((stream, _)) => {
                        let tx = in_tx.clone();
                        let id_c = id_counter.clone();
                        let token = expected_token.clone();
                        tokio::spawn(handle_connection(stream, tx, id_c, timeout_ms, token));
                    }
                    Err(_) => break,
                }
            }
        }
    }
}

/// 处理单个 TCP 连接的完整生命周期。
///
/// 流程：
/// 1. 读取并解析 HTTP 请求（带超时）
/// 2. 将请求通过通道发送到主线程
/// 3. 等待主线程处理完成并返回响应
/// 4. 将响应写回客户端
async fn handle_connection(
    mut stream: tokio::net::TcpStream,
    in_tx: mpsc::Sender<PendingRequest>,
    id_counter: Arc<AtomicU64>,
    timeout_ms: u64,
    expected_token: Option<String>,
) {
    let mut buf = Vec::with_capacity(8192);
    // 带超时的请求读取
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

    // 处理读取结果
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

    // 解析 HTTP 请求
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

    // 校验 token
    if let Some(ref expected) = expected_token {
        let auth_header = req.headers.iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("authorization"))
            .map(|(_, v)| v.as_str());

        match auth_header {
            Some(val) if val == format!("Bearer {}", expected) => {},
            _ => {
                let _ = stream.write_all(&write_response(401, &[], b"{\"error\":\"unauthorized\"}")).await;
                return;
            }
        }
    }

    // 分配请求 ID 并发送到主线程
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

    // 等待响应（带超时）
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

    // 发送响应并关闭连接
    let bytes = write_response(resp.status, &resp.headers, &resp.body);
    let _ = stream.write_all(&bytes).await;
    let _ = stream.shutdown().await;
}
