//! HTTP 请求队列和待响应映射表。
//!
//! 本模块提供线程安全的请求传递机制：
//! - `PendingRequest`: 待处理的 HTTP 请求，包含响应通道
//! - `HttpResponse`: HTTP 响应数据结构
//! - `PendingMap`: 待响应请求的映射表，用于异步等待响应

use std::collections::HashMap;
use tokio::sync::oneshot;

/// 待处理的 HTTP 请求。
///
/// 包含请求的所有数据以及一个 oneshot 响应通道。
/// 当主线程处理完请求后，通过 `resp_tx` 发送响应。
#[derive(Debug)]
pub struct PendingRequest {
    /// 请求 ID（用于匹配响应）
    pub id: u64,
    /// HTTP 方法（GET、POST 等）
    pub method: String,
    /// 请求路径
    pub path: String,
    /// 请求头列表（键已转为小写）
    pub headers: Vec<(String, String)>,
    /// 请求体字节
    pub body: Vec<u8>,
    /// 响应发送通道（处理完成后发送响应）
    pub resp_tx: oneshot::Sender<HttpResponse>,
}

/// HTTP 响应数据结构。
///
/// 包含状态码、响应头和响应体。
#[derive(Debug, Clone)]
pub struct HttpResponse {
    /// HTTP 状态码（如 200、404、500）
    pub status: u16,
    /// 响应头列表
    pub headers: Vec<(String, String)>,
    /// 响应体字节
    pub body: Vec<u8>,
}

/// 待响应请求的映射表。
///
/// 存储已发送到主线程但尚未收到响应的请求。
/// 键为请求 ID，值为对应的 oneshot 响应发送器。
///
/// 线程安全性：此结构体在单线程（主线程）中使用，
/// 通过 `ServerCore` 的 `pending` 字段持有。
#[derive(Default)]
pub struct PendingMap {
    inner: HashMap<u64, oneshot::Sender<HttpResponse>>,
}

impl PendingMap {
    /// 插入一个新的待响应请求。
    ///
    /// # Arguments
    /// * `id` - 请求 ID
    /// * `tx` - 响应发送通道
    pub fn insert(&mut self, id: u64, tx: oneshot::Sender<HttpResponse>) {
        self.inner.insert(id, tx);
    }

    /// 取出指定 ID 的响应通道。
    ///
    /// 取出后该 ID 不再存在于映射表中。
    ///
    /// # Arguments
    /// * `id` - 请求 ID
    ///
    /// # Returns
    /// 对应的响应发送通道，如果不存在返回 None
    pub fn take(&mut self, id: u64) -> Option<oneshot::Sender<HttpResponse>> {
        self.inner.remove(&id)
    }

    /// 清空所有待响应请求，向每个通道发送 503 响应。
    ///
    /// 在服务器关闭时调用，确保所有等待中的连接能收到错误响应。
    pub fn drain_503(&mut self) {
        for (_, tx) in self.inner.drain() {
            let _ = tx.send(HttpResponse {
                status: 503,
                headers: vec![("content-type".into(), "application/json".into())],
                body: br#"{"error":"server shutting down"}"#.to_vec(),
            });
        }
    }
}
