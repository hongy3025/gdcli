//! transport.rs — LSP JSON-RPC 传输层
//!
//! 【这个文件的作用】
//! 负责通过 TCP 与 Godot LSP 服务器建立连接，发送/接收 JSON-RPC 消息。
//! 实现了 LSP 协议规定的基于长度前缀的消息帧格式（Content-Length Header）。
//!
//! 【JSON-RPC 与 LSP 消息格式】
//! LSP 使用 JSON-RPC 2.0 作为通信协议，消息通过 TCP 传输。
//! 每条消息前有一个 HTTP 风格的头部：
//!   Content-Length: <字节数>\r\n
//!   \r\n
//!   <JSON 正文>
//!
//! 【异步编程基础】
//! Rust 中异步代码用 async/await 编写，配合 tokio 运行时执行。
//! - async fn 返回一个 Future（待执行的任务）
//! - .await 挂起当前任务，等待异步操作完成
//! - tokio::spawn 把任务放到后台执行

// ==================== 导入 ====================

use anyhow::{anyhow, Result};
/// BytesMut 是可动态增长的字节缓冲区，适合处理网络流数据
use bytes::BytesMut;
use serde_json::{json, Value};
use std::collections::HashMap;
/// AtomicI64：线程安全的 64 位整数，可无锁并发读写
use std::sync::atomic::{AtomicI64, Ordering};
/// Arc（Atomic Reference Counted）是线程安全的引用计数智能指针，
/// 多个线程可以共享同一个数据的所有权
use std::sync::Arc;
use std::time::Duration;
/// tokio 提供的异步 IO trait：AsyncReadExt（扩展读取）、AsyncWriteExt（扩展写入）
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
/// broadcast：一对多广播通道；oneshot：一次性发送/接收通道；Mutex：异步互斥锁
use tokio::sync::{broadcast, oneshot, Mutex};
use tokio::task::JoinHandle;

// ==================== 消息缓冲区 ====================

/// 【MessageBuffer — 滚动消息缓冲区】
///
/// TCP 是字节流协议，没有消息边界。LSP 规定用 Content-Length 头部划分消息，
/// 但一次 read 可能收到：不到一条消息、刚好一条、多条、半条等。
/// MessageBuffer 负责把收到的字节累积起来，按需提取出完整的 JSON body。
///
/// 【BytesMut 说明】
/// BytesMut 来自 bytes crate，是可增长的连续字节缓冲区。
/// 它比 Vec<u8> 更适合网络编程，因为支持高效的分割（split_to）和引用计数。
pub struct MessageBuffer {
    buf: BytesMut,
}

impl MessageBuffer {
    pub fn new() -> Self {
        Self { buf: BytesMut::new() }
    }

    /// 把新收到的字节追加到缓冲区尾部
    pub fn append(&mut self, chunk: &[u8]) {
        self.buf.extend_from_slice(chunk);
    }

    /// 尝试从缓冲区中读取一条完整的 LSP 消息。
    ///
    /// 返回 Ok(Some(body)) — 成功提取出一条消息
    /// 返回 Ok(None)      — 数据还不够一条完整消息
    /// 返回 Err(...)      — 数据格式错误（如非法 UTF-8、缺少 Content-Length）
    ///
    /// 【find_double_crlf】
    /// LSP 头部以 \r\n\r\n 结束，找到它才能确定头部占多少字节。
    ///
    /// 【std::str::from_utf8】
    /// 把字节切片转为 &str。如果字节不是合法 UTF-8 会返回 Err。
    /// 这里用 map_err 把错误转为 anyhow::Error。
    pub fn try_read_message(&mut self) -> Result<Option<String>> {
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

/// 在字节缓冲区中查找 \r\n\r\n 的位置。
///
/// 这是 LSP 消息头部和正文的分隔符。
/// 如果缓冲区长度小于 4 字节，直接返回 None。
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

// ==================== LSP 消息结构 ====================

/// 【Notification — 服务器推送的通知】
///
/// LSP 服务器可以主动向客户端推送消息（如诊断信息），不需要客户端请求。
/// 通知有 method（方法名）和 params（参数），但没有 id（不需要回复）。
#[derive(Debug, Clone)]
pub struct Notification {
    pub method: String,
    pub params: Value,
}

/// 【LspError — LSP 协议层面的错误】
///
/// JSON-RPC 响应中的 error 对象，包含错误代码和消息。
/// 实现了 Display 和 Error trait，可以与 anyhow 等错误处理库集成。
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

// ==================== 传输核心 ====================

/// 等待中的请求映射表。
///
/// 【类型别名说明】
/// type PendingMap = ... 是给复杂类型起个别名，提高可读性。
/// 这个类型的意思是：
///   - Arc<Mutex<...>>：线程安全共享的互斥锁保护的数据
///   - HashMap<i64, oneshot::Sender<...>>：用请求 id 映射到一次性发送器
///   - oneshot::Sender：只能发送一次值的通道发送端
///
/// 【为什么用 oneshot？】
/// 每个 request 对应唯一一个 response，用 oneshot 通道把 response
/// 从读取线程传回调用 request() 的异步任务，非常贴切。
type PendingMap = Arc<Mutex<HashMap<i64, oneshot::Sender<std::result::Result<Value, LspError>>>>>;

/// 【LspTransport — LSP TCP 传输管理器】
///
/// 封装了与 LSP 服务器的 TCP 连接，提供：
///   - request()：发送请求并等待响应
///   - notify()：发送通知（不需要响应）
///   - subscribe()：订阅服务器主动推送的通知
///   - shutdown()：优雅关闭连接
///
/// 【字段说明】
/// - writer：对 TCP 写入半边的共享引用，多个任务可能并发写，需要 Mutex 保护
/// - next_id：自增的请求 ID，用 AtomicI64 保证线程安全无锁递增
/// - pending：存放等待响应的请求，读取线程收到响应后通过 oneshot 回调
/// - notif_tx：广播发送器，用于分发服务器推送的通知给多个订阅者
/// - _reader：读取循环的 JoinHandle，持有它防止任务被过早释放
pub struct LspTransport {
    writer: Arc<Mutex<OwnedWriteHalf>>,
    next_id: AtomicI64,
    pending: PendingMap,
    notif_tx: broadcast::Sender<Notification>,
    _reader: JoinHandle<()>,
}

impl LspTransport {
    /// 连接到 LSP 服务器。
    ///
    /// 【流程】
    /// 1. 用 tokio::time::timeout 设置 5 秒连接超时
    /// 2. TCP 连接成功后拆分为读半边和写半边
    /// 3. 创建广播通道和 pending 映射表
    /// 4. 启动后台读取循环（reader_loop）
    /// 5. 返回 LspTransport 的 Arc 共享引用
    ///
    /// 【Arc<Self>】
    /// 返回 Arc 是因为调用者通常需要把 Transport 共享给多个异步任务使用。
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

    /// 订阅服务器推送的通知。
    ///
    /// 【broadcast::Receiver】
    /// 每次调用 subscribe() 都会创建一个新的接收器，可以独立接收通知。
    /// 适合"一个生产者，多个消费者"的场景。
    pub fn subscribe(&self) -> broadcast::Receiver<Notification> {
        self.notif_tx.subscribe()
    }

    /// 发送一个 JSON-RPC request，并等待服务器的 response。
    ///
    /// 【流程】
    /// 1. fetch_add 获取并递增唯一请求 ID
    /// 2. 创建一个 oneshot 通道，把 Sender 存到 pending 表中
    /// 3. 构造 JSON-RPC 请求报文并发送
    /// 4. 等待 oneshot Receiver 收到响应
    ///
    /// 【Ordering::SeqCst】
    /// 原子操作的内存顺序：SeqCst（顺序一致性）是最安全的默认选项，
    /// 保证所有线程看到的操作顺序一致。
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

    /// 发送一个 JSON-RPC notification（不需要响应）。
    ///
    /// 与 request 的区别：没有 id 字段，服务器不会发回 response。
    /// 用于打开文件、保存文件、初始化完成等场景。
    pub async fn notify(&self, method: &str, params: Value) -> Result<()> {
        let msg = json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        });
        self.send(&msg).await
    }

    /// 底层的 TCP 发送函数。
    ///
    /// 把 JSON Value 序列化为字节，加上 Content-Length 头部，写入 TCP 流。
    /// 用 Mutex 保护 writer，保证同一时间只有一个任务在写 socket。
    async fn send(&self, msg: &Value) -> Result<()> {
        let body = serde_json::to_vec(msg)?;
        let header = format!("Content-Length: {}\r\n\r\n", body.len());
        let mut w = self.writer.lock().await;
        w.write_all(header.as_bytes()).await?;
        w.write_all(&body).await?;
        w.flush().await?;
        Ok(())
    }

    /// 关闭 TCP 写入端。
    ///
    /// 调用后对方会收到 EOF，读取循环随之结束。
    pub async fn shutdown(&self) {
        let mut w = self.writer.lock().await;
        let _ = w.shutdown().await;
    }
}

// ==================== 后台读取循环 ====================

/// 后台读取任务：持续从 TCP 读半边读取字节，解析出完整消息并分发。
///
/// 【loop 说明】
/// loop { ... } 是 Rust 中的无限循环，内部用 break 跳出。
///
/// 【match reader.read(&mut chunk).await】
///   - Ok(0)：对方关闭连接，退出循环
///   - Ok(n)：读到 n 字节，追加到缓冲区
///   - Err(_)：读出错，退出循环
///
/// 【内层 loop】
/// 一次 read 可能收到多条消息，所以用内层循环尽可能多地提取完整消息。
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
    // 连接关闭：reject 所有还在等待响应的请求
    let mut p = pending.lock().await;
    for (_, tx) in p.drain() {
        let _ = tx.send(Err(LspError { code: -1, message: "Connection closed".into() }));
    }
}

/// 分发一条解析好的 JSON-RPC 消息。
///
/// 【流程】
/// 1. 把 JSON 字符串反序列化为 Value
/// 2. 如果有 id 字段：说明是 response，找到对应的 pending 请求，通过 oneshot 发送结果
///    - 如果 JSON 中有 error：包装成 LspError 发送 Err
///    - 否则：取 result 字段发送 Ok
/// 3. 如果没有 id 但有 method：说明是服务器推送的 notification，广播给所有订阅者
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

// ==================== 单元测试 ====================

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
