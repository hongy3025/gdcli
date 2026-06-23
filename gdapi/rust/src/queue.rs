use std::collections::HashMap;
use tokio::sync::oneshot;

#[derive(Debug)]
pub struct PendingRequest {
    pub id: u64,
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub resp_tx: oneshot::Sender<HttpResponse>,
}

#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

#[derive(Default)]
pub struct PendingMap {
    inner: HashMap<u64, oneshot::Sender<HttpResponse>>,
}

impl PendingMap {
    pub fn insert(&mut self, id: u64, tx: oneshot::Sender<HttpResponse>) {
        self.inner.insert(id, tx);
    }

    pub fn take(&mut self, id: u64) -> Option<oneshot::Sender<HttpResponse>> {
        self.inner.remove(&id)
    }

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
