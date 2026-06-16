use anyhow::{anyhow, Result};
use bytes::BytesMut;

/// 滚动缓冲区：从 TCP 字节流中解出一个完整 JSON-RPC body。
pub struct MessageBuffer {
    buf: BytesMut,
}

impl MessageBuffer {
    pub fn new() -> Self {
        Self { buf: BytesMut::new() }
    }

    pub fn append(&mut self, chunk: &[u8]) {
        self.buf.extend_from_slice(chunk);
    }

    /// 尝试读出一个 body（UTF-8 字符串）。返回 None 表示数据不足。
    pub fn try_read_message(&mut self) -> Result<Option<String>> {
        // 找 \r\n\r\n
        let sep = match find_double_crlf(&self.buf) {
            Some(i) => i,
            None => return Ok(None),
        };
        let header_str = std::str::from_utf8(&self.buf[..sep])
            .map_err(|_| anyhow!("invalid header bytes"))?;
        let mut content_length: Option<usize> = None;
        for line in header_str.split("\r\n") {
            if let Some((k, v)) = line.split_once(':') {
                if k.eq_ignore_ascii_case("Content-Length") {
                    content_length = v.trim().parse().ok();
                }
            }
        }
        let len = content_length.ok_or_else(|| anyhow!("missing Content-Length"))?;
        let body_start = sep + 4;
        let total = body_start + len;
        if self.buf.len() < total {
            return Ok(None);
        }
        let body = std::str::from_utf8(&self.buf[body_start..total])
            .map_err(|_| anyhow!("invalid body utf-8"))?
            .to_string();
        let _ = self.buf.split_to(total);
        Ok(Some(body))
    }
}

fn find_double_crlf(buf: &[u8]) -> Option<usize> {
    if buf.len() < 4 {
        return None;
    }
    for i in 0..=buf.len() - 4 {
        if buf[i] == b'\r' && buf[i + 1] == b'\n' && buf[i + 2] == b'\r' && buf[i + 3] == b'\n' {
            return Some(i);
        }
    }
    None
}

use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::{broadcast, oneshot, Mutex};
use tokio::task::JoinHandle;

#[derive(Debug, Clone)]
pub struct Notification {
    pub method: String,
    pub params: Value,
}

#[derive(Debug, Clone)]
pub struct LspError {
    pub code: i64,
    pub message: String,
}

impl std::fmt::Display for LspError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "LSP error {}: {}", self.code, self.message)
    }
}

impl std::error::Error for LspError {}

type PendingMap = Arc<Mutex<HashMap<i64, oneshot::Sender<std::result::Result<Value, LspError>>>>>;

pub struct LspTransport {
    writer: Arc<Mutex<OwnedWriteHalf>>,
    next_id: AtomicI64,
    pending: PendingMap,
    notif_tx: broadcast::Sender<Notification>,
    _reader: JoinHandle<()>,
}

impl LspTransport {
    pub async fn connect(host: &str, port: u16) -> Result<Arc<Self>> {
        let stream = tokio::time::timeout(
            Duration::from_secs(5),
            TcpStream::connect((host, port)),
        )
        .await
        .map_err(|_| anyhow!("Connection to {}:{} timed out after 5000ms", host, port))?
        .map_err(|e| anyhow!("Connection to {}:{} failed: {}", host, port, e))?;

        let (read_half, write_half) = stream.into_split();
        let (notif_tx, _) = broadcast::channel(64);
        let pending: PendingMap = Arc::new(Mutex::new(HashMap::new()));

        let reader_handle = tokio::spawn(reader_loop(read_half, pending.clone(), notif_tx.clone()));

        Ok(Arc::new(Self {
            writer: Arc::new(Mutex::new(write_half)),
            next_id: AtomicI64::new(1),
            pending,
            notif_tx,
            _reader: reader_handle,
        }))
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Notification> {
        self.notif_tx.subscribe()
    }

    pub async fn request(&self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(id, tx);

        let msg = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        });
        self.send(&msg).await?;

        match rx.await {
            Ok(Ok(v)) => Ok(v),
            Ok(Err(e)) => Err(anyhow::Error::new(e)),
            Err(_) => Err(anyhow!("Connection closed")),
        }
    }

    pub async fn notify(&self, method: &str, params: Value) -> Result<()> {
        let msg = json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        });
        self.send(&msg).await
    }

    async fn send(&self, msg: &Value) -> Result<()> {
        let body = serde_json::to_vec(msg)?;
        let header = format!("Content-Length: {}\r\n\r\n", body.len());
        let mut w = self.writer.lock().await;
        w.write_all(header.as_bytes()).await?;
        w.write_all(&body).await?;
        w.flush().await?;
        Ok(())
    }

    pub async fn shutdown(&self) {
        let mut w = self.writer.lock().await;
        let _ = w.shutdown().await;
    }
}

async fn reader_loop(
    mut reader: OwnedReadHalf,
    pending: PendingMap,
    notif_tx: broadcast::Sender<Notification>,
) {
    let mut buf = MessageBuffer::new();
    let mut chunk = [0u8; 8192];
    loop {
        match reader.read(&mut chunk).await {
            Ok(0) => break,
            Ok(n) => buf.append(&chunk[..n]),
            Err(_) => break,
        }
        loop {
            match buf.try_read_message() {
                Ok(Some(body)) => dispatch(&body, &pending, &notif_tx).await,
                Ok(None) => break,
                Err(_) => break,
            }
        }
    }
    // 连接关闭：reject 所有 pending
    let mut p = pending.lock().await;
    for (_, tx) in p.drain() {
        let _ = tx.send(Err(LspError { code: -1, message: "Connection closed".into() }));
    }
}

async fn dispatch(body: &str, pending: &PendingMap, notif_tx: &broadcast::Sender<Notification>) {
    let v: Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => return,
    };
    if let Some(id) = v.get("id").and_then(|x| x.as_i64()) {
        let mut p = pending.lock().await;
        if let Some(tx) = p.remove(&id) {
            if let Some(err) = v.get("error") {
                let code = err.get("code").and_then(|x| x.as_i64()).unwrap_or(-1);
                let message = err
                    .get("message")
                    .and_then(|x| x.as_str())
                    .unwrap_or("unknown")
                    .to_string();
                let _ = tx.send(Err(LspError { code, message }));
            } else {
                let result = v.get("result").cloned().unwrap_or(Value::Null);
                let _ = tx.send(Ok(result));
            }
            return;
        }
    }
    if let Some(method) = v.get("method").and_then(|x| x.as_str()) {
        let params = v.get("params").cloned().unwrap_or(Value::Null);
        let _ = notif_tx.send(Notification {
            method: method.to_string(),
            params,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(body: &str) -> Vec<u8> {
        format!("Content-Length: {}\r\n\r\n{}", body.len(), body).into_bytes()
    }

    #[test]
    fn single_complete_message() {
        let mut buf = MessageBuffer::new();
        buf.append(&frame(r#"{"jsonrpc":"2.0","id":1,"result":null}"#));
        let msg = buf.try_read_message().unwrap().expect("should read");
        assert!(msg.contains(r#""id":1"#));
    }

    #[test]
    fn split_across_chunks() {
        let mut buf = MessageBuffer::new();
        let full = frame(r#"{"a":1}"#);
        let (a, b) = full.split_at(8);
        buf.append(a);
        assert!(buf.try_read_message().unwrap().is_none());
        buf.append(b);
        let msg = buf.try_read_message().unwrap().expect("should read");
        assert_eq!(msg, r#"{"a":1}"#);
    }

    #[test]
    fn back_to_back_messages() {
        let mut buf = MessageBuffer::new();
        let mut combined = frame(r#"{"a":1}"#);
        combined.extend(frame(r#"{"b":2}"#));
        buf.append(&combined);
        assert_eq!(buf.try_read_message().unwrap().unwrap(), r#"{"a":1}"#);
        assert_eq!(buf.try_read_message().unwrap().unwrap(), r#"{"b":2}"#);
        assert!(buf.try_read_message().unwrap().is_none());
    }

    #[test]
    fn missing_content_length_errors() {
        let mut buf = MessageBuffer::new();
        buf.append(b"Foo: bar\r\n\r\nbody");
        assert!(buf.try_read_message().is_err());
    }

    use tokio::io::AsyncReadExt;
    use tokio::net::TcpListener;

    async fn read_one_message(stream: &mut tokio::net::TcpStream) -> String {
        let mut buf = MessageBuffer::new();
        let mut chunk = [0u8; 4096];
        loop {
            let n = stream.read(&mut chunk).await.unwrap();
            buf.append(&chunk[..n]);
            if let Some(msg) = buf.try_read_message().unwrap() {
                return msg;
            }
        }
    }

    #[tokio::test]
    async fn request_response_roundtrip() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();

        let server = tokio::spawn(async move {
            let (mut s, _) = listener.accept().await.unwrap();
            let req = read_one_message(&mut s).await;
            assert!(req.contains("\"method\":\"ping\""));
            let resp = r#"{"jsonrpc":"2.0","id":1,"result":{"pong":true}}"#;
            let frame = format!("Content-Length: {}\r\n\r\n{}", resp.len(), resp);
            tokio::io::AsyncWriteExt::write_all(&mut s, frame.as_bytes()).await.unwrap();
        });

        let t = LspTransport::connect("127.0.0.1", port).await.unwrap();
        let v = t.request("ping", json!({})).await.unwrap();
        assert_eq!(v["pong"], json!(true));
        server.await.unwrap();
    }

    #[tokio::test]
    async fn notification_broadcast() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();

        let server = tokio::spawn(async move {
            let (mut s, _) = listener.accept().await.unwrap();
            let notif = r#"{"jsonrpc":"2.0","method":"hello","params":{"x":1}}"#;
            let frame = format!("Content-Length: {}\r\n\r\n{}", notif.len(), notif);
            tokio::io::AsyncWriteExt::write_all(&mut s, frame.as_bytes()).await.unwrap();
            tokio::time::sleep(Duration::from_millis(200)).await;
        });

        let t = LspTransport::connect("127.0.0.1", port).await.unwrap();
        let mut rx = t.subscribe();
        let n = tokio::time::timeout(Duration::from_secs(2), rx.recv()).await.unwrap().unwrap();
        assert_eq!(n.method, "hello");
        assert_eq!(n.params["x"], json!(1));
        server.await.unwrap();
    }
}
