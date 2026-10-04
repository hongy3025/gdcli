//! HTTP 请求队列和待响应映射表。
//!
//! 本模块提供线程安全的请求传递机制：
//! - `PendingRequest`: 待处理的 HTTP 请求，包含响应通道
//! - `HttpResponse`: HTTP 响应数据结构
//! - `PendingMap`: 待响应请求的映射表，用于异步等待响应

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::sync::oneshot;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum CancelReason {
    Timeout = 1,
    Disconnected = 2,
    Shutdown = 3,
}

type CancelHook = Box<dyn FnOnce(CancelReason) + Send>;

/// One deadline and cancellation owner, from HTTP enqueue through terminal work.
pub struct RequestControl {
    pub deadline: Instant,
    reason: AtomicU8,
    response_claimed: AtomicBool,
    hook: Mutex<Option<CancelHook>>,
}

impl std::fmt::Debug for RequestControl {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RequestControl")
            .field("deadline", &self.deadline)
            .finish()
    }
}

impl RequestControl {
    pub fn new(deadline: Instant) -> Arc<Self> {
        Arc::new(Self {
            deadline,
            reason: AtomicU8::new(0),
            response_claimed: AtomicBool::new(false),
            hook: Mutex::new(None),
        })
    }

    /// Atomically enqueue a response before its deadline/cancellation can win.
    /// The enqueue closure runs while holding the same lock used by cancel().
    pub fn claim_response<T>(
        &self,
        enqueue: impl FnOnce() -> Result<T, String>,
    ) -> Result<T, String> {
        let mut slot = self
            .hook
            .lock()
            .expect("request cancellation lock poisoned");
        if self.reason().is_some() {
            return Err("request expired or cancelled before response send".to_string());
        }
        if self.deadline <= Instant::now() {
            self.cancel_while_locked(&mut slot, CancelReason::Timeout);
            return Err("request expired or cancelled before response send".to_string());
        }
        let value = enqueue()?;
        self.response_claimed.store(true, Ordering::Release);
        Ok(value)
    }

    pub fn response_claimed(&self) -> bool {
        self.response_claimed.load(Ordering::Acquire)
    }

    fn cancel_while_locked(&self, slot: &mut Option<CancelHook>, reason: CancelReason) {
        if self
            .reason
            .compare_exchange(0, reason as u8, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            if let Some(hook) = slot.take() {
                hook(reason);
            }
        }
    }

    pub fn reason(&self) -> Option<CancelReason> {
        match self.reason.load(Ordering::Acquire) {
            1 => Some(CancelReason::Timeout),
            2 => Some(CancelReason::Disconnected),
            3 => Some(CancelReason::Shutdown),
            _ => None,
        }
    }

    pub fn cancel(&self, reason: CancelReason) {
        // Serialize cleanup, response delivery, and registration: whichever
        // acquires this lock first owns the terminal outcome.
        let mut slot = self
            .hook
            .lock()
            .expect("request cancellation lock poisoned");
        if self.response_claimed.load(Ordering::Acquire) {
            return;
        }
        if self
            .reason
            .compare_exchange(0, reason as u8, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            if let Some(hook) = slot.take() {
                hook(reason);
            }
        }
    }

    pub fn run_if_active<T>(
        &self,
        start: impl FnOnce() -> Result<(T, CancelHook), String>,
    ) -> Result<T, String> {
        // Hold the cancellation lock across spawn and hook registration. Otherwise
        // a timeout could finish HTTP while a not-yet-registered child starts.
        let mut slot = self
            .hook
            .lock()
            .expect("request cancellation lock poisoned");
        if self.reason().is_some() || self.deadline <= Instant::now() {
            return Err("request cancelled before process start".to_string());
        }
        let (value, hook) = start()?;
        *slot = Some(hook);
        Ok(value)
    }

    pub fn remaining_ms(&self) -> u64 {
        self.deadline
            .saturating_duration_since(Instant::now())
            .as_millis() as u64
    }
}

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
    pub control: Arc<RequestControl>,
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
    inner: HashMap<u64, PendingEntry>,
}

struct PendingEntry {
    tx: oneshot::Sender<HttpResponse>,
    control: Arc<RequestControl>,
}

impl PendingMap {
    /// 插入一个新的待响应请求。
    ///
    /// # Arguments
    /// * `id` - 请求 ID
    /// * `tx` - 响应发送通道
    pub fn insert(
        &mut self,
        id: u64,
        tx: oneshot::Sender<HttpResponse>,
        control: Arc<RequestControl>,
    ) {
        self.inner.insert(id, PendingEntry { tx, control });
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
        self.inner.remove(&id).map(|entry| entry.tx)
    }

    pub fn control(&self, id: u64) -> Option<Arc<RequestControl>> {
        self.inner.get(&id).map(|entry| Arc::clone(&entry.control))
    }

    /// 清理已超过响应期限的请求，返回清理数量。
    pub fn remove_expired(&mut self, now: Instant) -> usize {
        let before = self.inner.len();
        self.inner.retain(|_, entry| {
            if entry.control.deadline <= now {
                entry.control.cancel(CancelReason::Timeout);
            } else if entry.tx.is_closed() {
                entry.control.cancel(CancelReason::Disconnected);
            }
            entry.control.reason().is_none()
        });
        before - self.inner.len()
    }

    /// 返回当前待响应请求数量。
    pub fn len(&self) -> usize {
        self.inner.len()
    }

    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    /// 清空所有待响应请求，向每个通道发送 503 响应。
    ///
    /// 在服务器关闭时调用，确保所有等待中的连接能收到错误响应。
    pub fn drain_503(&mut self) {
        for (_, entry) in self.inner.drain() {
            entry.control.cancel(CancelReason::Shutdown);
            let _ = entry.tx.send(HttpResponse {
                status: 503,
                headers: vec![("content-type".into(), "application/json".into())],
                body: br#"{"error":"server shutting down"}"#.to_vec(),
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Barrier;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn cleanup_expired_removes_only_deadline_reached_entries() {
        let mut pending = PendingMap::default();
        let now = Instant::now();
        let (expired_tx, mut expired_rx) = oneshot::channel();
        let (active_tx, mut active_rx) = oneshot::channel();

        pending.insert(
            1,
            expired_tx,
            RequestControl::new(now - Duration::from_millis(1)),
        );
        pending.insert(
            2,
            active_tx,
            RequestControl::new(now + Duration::from_secs(60)),
        );

        assert_eq!(pending.remove_expired(now), 1);

        assert!(matches!(
            expired_rx.try_recv(),
            Err(oneshot::error::TryRecvError::Closed)
        ));
        assert!(matches!(
            active_rx.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        ));
        assert!(pending.take(1).is_none());
        assert!(pending.take(2).is_some());
    }

    #[test]
    fn pending_map_removes_expired_entries() {
        let mut map = PendingMap::default();
        let (expired_tx, _expired_rx) = oneshot::channel();
        let (live_tx, _live_rx) = oneshot::channel();
        let now = Instant::now();

        map.insert(
            1,
            expired_tx,
            RequestControl::new(now - Duration::from_millis(1)),
        );
        map.insert(
            2,
            live_tx,
            RequestControl::new(now + Duration::from_secs(1)),
        );

        assert_eq!(map.remove_expired(now), 1);
        assert_eq!(map.len(), 1);
        assert!(map.take(1).is_none());
        assert!(map.take(2).is_some());
    }

    #[test]
    fn response_claim_wins_when_deadline_passes_while_enqueuing() {
        let deadline = Instant::now() + Duration::from_millis(200);
        let control = RequestControl::new(deadline);
        let entered_enqueue = Arc::new(Barrier::new(2));
        let release_enqueue = Arc::new(Barrier::new(2));
        let claim_control = Arc::clone(&control);
        let claim_entered = Arc::clone(&entered_enqueue);
        let claim_release = Arc::clone(&release_enqueue);
        let claim = thread::spawn(move || {
            claim_control.claim_response(|| {
                claim_entered.wait();
                claim_release.wait();
                Ok(())
            })
        });

        entered_enqueue.wait();
        thread::sleep(
            deadline.saturating_duration_since(Instant::now()) + Duration::from_millis(5),
        );
        let cancel_control = Arc::clone(&control);
        let cancel_started = Arc::new(Barrier::new(2));
        let cancel_started_thread = Arc::clone(&cancel_started);
        let cancel = thread::spawn(move || {
            cancel_started_thread.wait();
            cancel_control.cancel(CancelReason::Timeout);
        });
        cancel_started.wait();
        release_enqueue.wait();

        claim.join().expect("claim thread").expect("claim wins");
        cancel.join().expect("timeout thread");
        assert!(control.response_claimed());
        assert_eq!(control.reason(), None);
    }

    #[test]
    fn response_claim_rejects_request_already_past_deadline() {
        let control = RequestControl::new(Instant::now() - Duration::from_millis(1));
        let enqueued = AtomicBool::new(false);
        let result = control.claim_response(|| {
            enqueued.store(true, Ordering::Release);
            Ok(())
        });

        assert!(result.is_err());
        assert!(!enqueued.load(Ordering::Acquire));
        assert_eq!(control.reason(), Some(CancelReason::Timeout));
        assert!(!control.response_claimed());
    }
}
