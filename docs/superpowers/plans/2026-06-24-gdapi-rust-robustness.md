# gdapi Rust Robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the `gdapi/rust` Godot extension HTTP server so malformed requests, invalid Godot responses, queue pressure, and per-connection failures cannot panic, stop the service loop, or permanently consume resources.

**Architecture:** Keep the existing `http.rs`, `server.rs`, `queue.rs`, and `lib.rs` boundaries. Add fallible HTTP response serialization, bounded request reading, bounded connection/queue behavior, validated Godot input, and pending request lifecycle cleanup without replacing the current Tokio + mpsc + oneshot design.

**Tech Stack:** Rust 2021, Godot GDExtension via `godot = 0.5`, Tokio 1, `httparse`, existing `cargo test -p gdapi` test suite.

## Global Constraints

- No Rust panic in normal request/response paths, including malicious or invalid input.
- No single request can stop the accept loop or permanently occupy a connection task.
- No invalid Godot-side response input can corrupt protocol output or terminate a thread/process.
- Resource use is bounded for header bytes, body bytes, concurrent connections, queue pressure, and pending responses.
- Godot main-thread polling remains non-blocking.
- Existing successful request flow keeps working.
- Do not implement full HTTP/1.1, chunked transfer encoding, keep-alive, routing changes, metrics, or broad observability.
- Verification command for every task: `cargo test -p gdapi`.

---

## File Structure

- Modify `gdapi/rust/src/http.rs`: Add header/request constants, header validation, fallible response serialization, safe fallback serialization, and unit tests.
- Modify `gdapi/rust/src/server.rs`: Use safe response helpers, checked port probing, timeout clamping, bounded connection semaphore, bounded queue send, and resilient accept loop.
- Modify `gdapi/rust/src/queue.rs`: Track pending response deadlines, cleanup stale pending entries, and expose pending length for tests.
- Modify `gdapi/rust/src/lib.rs`: Validate Godot-provided `id`, `status`, and response headers before passing them into `ServerCore`.
- Modify `gdapi/rust/tests/server_e2e.rs`: Add integration coverage for near-`u16::MAX` port probing, oversized incomplete headers, handler timeout cleanup, and queue pressure behavior where feasible.

---

### Task 1: Fallible HTTP Response Serialization

**Files:**
- Modify: `gdapi/rust/src/http.rs:11-122`
- Test: `gdapi/rust/src/http.rs:212-278`

**Interfaces:**
- Produces: `pub const MAX_HEADER_BYTES: usize`
- Produces: `pub fn validate_response_header(name: &str, value: &str) -> io::Result<()>`
- Produces: `pub fn try_write_response(status: u16, headers: &[(String, String)], body: &[u8]) -> io::Result<Vec<u8>>`
- Produces: `pub fn write_response(status: u16, headers: &[(String, String)], body: &[u8]) -> Vec<u8>` as a no-panic safe wrapper
- Consumes: existing `reason_phrase(status: u16) -> &'static str`

- [ ] **Step 1: Replace panic-based tests with fallible response tests**

In `gdapi/rust/src/http.rs`, replace the two `#[should_panic]` tests at the existing `write_response_rejects_header_injection_in_value` and `write_response_rejects_header_injection_in_name` locations with:

```rust
    #[test]
    fn try_write_response_rejects_header_injection_in_value() {
        let headers = vec![("content-type".into(), "text/html\r\nInjected: evil".into())];
        let err = try_write_response(200, &headers, b"ok").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert!(err.to_string().contains("header value contains CR/LF"));
    }

    #[test]
    fn try_write_response_rejects_header_injection_in_name() {
        let headers = vec![("content-type\r\nInjected".into(), "text/html".into())];
        let err = try_write_response(200, &headers, b"ok").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert!(err.to_string().contains("header name contains CR/LF"));
    }

    #[test]
    fn try_write_response_rejects_empty_header_name() {
        let headers = vec![("".into(), "text/html".into())];
        let err = try_write_response(200, &headers, b"ok").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert!(err.to_string().contains("header name is empty"));
    }

    #[test]
    fn try_write_response_rejects_managed_headers() {
        let headers = vec![("content-length".into(), "999".into())];
        let err = try_write_response(200, &headers, b"ok").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert!(err.to_string().contains("managed response header"));
    }

    #[test]
    fn write_response_falls_back_without_panicking() {
        let headers = vec![("content-type".into(), "text/html\r\nInjected: evil".into())];
        let bytes = write_response(200, &headers, b"ok");
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.starts_with("HTTP/1.1 500 Internal Server Error\r\n"));
        assert!(s.contains("content-length:"));
        assert!(s.ends_with("{\"error\":\"internal response error\"}"));
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p gdapi http::tests::try_write_response`

Expected: FAIL because `try_write_response` and the new safe wrapper behavior are not implemented yet.

- [ ] **Step 3: Implement fallible serializer and safe wrapper**

In `gdapi/rust/src/http.rs`, add the public header byte constant near `MAX_BODY`:

```rust
pub const MAX_BODY: usize = 16 * 1024 * 1024;
pub const MAX_HEADER_BYTES: usize = 32 * 1024;
const MAX_HEADERS: usize = 64;
```

Replace `write_response` with:

```rust
pub fn validate_response_header(name: &str, value: &str) -> io::Result<()> {
    if name.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "header name is empty"));
    }
    if name.contains('\r') || name.contains('\n') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("header name contains CR/LF: {:?}", name),
        ));
    }
    if value.contains('\r') || value.contains('\n') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("header value contains CR/LF: {:?}", value),
        ));
    }
    if name.eq_ignore_ascii_case("content-length") || name.eq_ignore_ascii_case("connection") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("managed response header cannot be supplied: {}", name),
        ));
    }
    Ok(())
}

pub fn try_write_response(status: u16, headers: &[(String, String)], body: &[u8]) -> io::Result<Vec<u8>> {
    for (k, v) in headers {
        validate_response_header(k, v)?;
    }

    let reason = reason_phrase(status);
    let mut out = Vec::with_capacity(128 + body.len());
    out.extend_from_slice(format!("HTTP/1.1 {} {}\r\n", status, reason).as_bytes());
    for (k, v) in headers {
        out.extend_from_slice(format!("{}: {}\r\n", k, v).as_bytes());
    }
    out.extend_from_slice(format!("content-length: {}\r\n", body.len()).as_bytes());
    out.extend_from_slice(b"connection: close\r\n");
    out.extend_from_slice(b"\r\n");
    out.extend_from_slice(body);
    Ok(out)
}

pub fn write_response(status: u16, headers: &[(String, String)], body: &[u8]) -> Vec<u8> {
    match try_write_response(status, headers, body) {
        Ok(bytes) => bytes,
        Err(_) => fallback_response(500, br#"{\"error\":\"internal response error\"}"#),
    }
}

fn fallback_response(status: u16, body: &[u8]) -> Vec<u8> {
    let reason = reason_phrase(status);
    let mut out = Vec::with_capacity(128 + body.len());
    out.extend_from_slice(format!("HTTP/1.1 {} {}\r\n", status, reason).as_bytes());
    out.extend_from_slice(b"content-type: application/json\r\n");
    out.extend_from_slice(format!("content-length: {}\r\n", body.len()).as_bytes());
    out.extend_from_slice(b"connection: close\r\n");
    out.extend_from_slice(b"\r\n");
    out.extend_from_slice(body);
    out
}
```

- [ ] **Step 4: Run focused tests**

Run: `cargo test -p gdapi http::tests::try_write_response http::tests::write_response`

Expected: PASS for all response serialization tests.

- [ ] **Step 5: Run full gdapi tests**

Run: `cargo test -p gdapi`

Expected: PASS.

---

### Task 2: Bound HTTP Request Header Reads

**Files:**
- Modify: `gdapi/rust/src/server.rs:11-309`
- Modify: `gdapi/rust/src/http.rs:153-319`
- Test: `gdapi/rust/tests/server_e2e.rs`

**Interfaces:**
- Consumes: `gdapi::http::MAX_HEADER_BYTES`
- Produces: connection read path that rejects incomplete headers larger than `MAX_HEADER_BYTES`

- [ ] **Step 1: Add parser unit test for exported header limit constant**

In `gdapi/rust/src/http.rs` tests, add:

```rust
    #[test]
    fn max_header_bytes_is_smaller_than_max_body() {
        assert_eq!(MAX_HEADER_BYTES, 32 * 1024);
        assert!(MAX_HEADER_BYTES < MAX_BODY);
    }
```

- [ ] **Step 2: Add e2e test for oversized incomplete headers**

In `gdapi/rust/tests/server_e2e.rs`, add imports and test:

```rust
use gdapi::http::MAX_HEADER_BYTES;
```

```rust
#[test]
fn server_rejects_oversized_incomplete_headers() {
    let mut server = ServerCore::new();
    let port = server.start(17930, None).expect("start");

    let handle = thread::spawn(move || {
        let mut stream = TcpStream::connect(format!("127.0.0.1:{}", port)).unwrap();
        let oversized = format!("GET /x HTTP/1.1\r\nX-Fill: {}", "a".repeat(MAX_HEADER_BYTES));
        stream.write_all(oversized.as_bytes()).unwrap();

        let mut buf = vec![0u8; 4096];
        let n = stream.read(&mut buf).unwrap();
        let resp = String::from_utf8_lossy(&buf[..n]);
        assert!(resp.starts_with("HTTP/1.1 400"), "expected 400, got: {}", resp);
    });

    thread::sleep(Duration::from_millis(500));
    handle.join().expect("client thread panicked");
    server.stop();
}
```

- [ ] **Step 3: Run new e2e test to verify it fails**

Run: `cargo test -p gdapi server_rejects_oversized_incomplete_headers`

Expected: FAIL because the connection currently waits for read timeout instead of checking `MAX_HEADER_BYTES` immediately.

- [ ] **Step 4: Implement read-prefix bound**

In `gdapi/rust/src/server.rs`, change the import:

```rust
use crate::http::{parse_request, write_response, ParsedRequest, MAX_HEADER_BYTES};
```

Inside `handle_connection`, immediately after `buf.extend_from_slice(&chunk[..n]);`, add:

```rust
                if buf.len() > MAX_HEADER_BYTES && !buf.windows(4).any(|w| w == b"\r\n\r\n") {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "HTTP headers exceed 32 KiB",
                    ));
                }
```

- [ ] **Step 5: Run focused tests**

Run: `cargo test -p gdapi server_rejects_oversized_incomplete_headers` and `cargo test -p gdapi http::tests::max_header_bytes_is_smaller_than_max_body`

Expected: PASS.

- [ ] **Step 6: Run full gdapi tests**

Run: `cargo test -p gdapi`

Expected: PASS.

---

### Task 3: Safe Server Startup, Timeout Config, and Accept Loop Resilience

**Files:**
- Modify: `gdapi/rust/src/server.rs:21-243`
- Test: `gdapi/rust/tests/server_e2e.rs`

**Interfaces:**
- Produces: `const MIN_HANDLER_TIMEOUT_MS: u64 = 100`
- Produces: `const MAX_HANDLER_TIMEOUT_MS: u64 = 300_000`
- Produces: `fn handler_timeout_from_env() -> u64`
- Produces: checked port probing in `ServerCore::start`

- [ ] **Step 1: Add unit tests for timeout clamping and port overflow**

At the bottom of `gdapi/rust/src/server.rs`, add:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handler_timeout_env_invalid_values_fall_back() {
        std::env::set_var("GDAPI_HANDLER_TIMEOUT_MS", "0");
        assert_eq!(handler_timeout_from_env(), DEFAULT_TIMEOUT_MS);
        std::env::set_var("GDAPI_HANDLER_TIMEOUT_MS", "999999999");
        assert_eq!(handler_timeout_from_env(), DEFAULT_TIMEOUT_MS);
        std::env::set_var("GDAPI_HANDLER_TIMEOUT_MS", "abc");
        assert_eq!(handler_timeout_from_env(), DEFAULT_TIMEOUT_MS);
        std::env::remove_var("GDAPI_HANDLER_TIMEOUT_MS");
    }

    #[test]
    fn handler_timeout_env_accepts_safe_value() {
        std::env::set_var("GDAPI_HANDLER_TIMEOUT_MS", "250");
        assert_eq!(handler_timeout_from_env(), 250);
        std::env::remove_var("GDAPI_HANDLER_TIMEOUT_MS");
    }

    #[test]
    fn start_near_u16_max_does_not_wrap_or_panic() {
        let mut server = ServerCore::new();
        let result = server.start(u16::MAX, None);
        if let Ok(port) = result {
            assert_eq!(port, u16::MAX);
            server.stop();
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p gdapi server::tests::handler_timeout_env` and `cargo test -p gdapi server::tests::start_near_u16_max_does_not_wrap_or_panic`

Expected: FAIL because `handler_timeout_from_env` does not exist and port probing still uses unchecked addition.

- [ ] **Step 3: Implement timeout clamp and checked port probing**

In `gdapi/rust/src/server.rs`, add constants near existing constants:

```rust
const MIN_HANDLER_TIMEOUT_MS: u64 = 100;
const MAX_HANDLER_TIMEOUT_MS: u64 = 300_000;
const MAX_CONNECTIONS: usize = 128;
```

Add helper near `impl ServerCore` or before `accept_loop`:

```rust
fn handler_timeout_from_env() -> u64 {
    std::env::var("GDAPI_HANDLER_TIMEOUT_MS")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .filter(|v| (MIN_HANDLER_TIMEOUT_MS..=MAX_HANDLER_TIMEOUT_MS).contains(v))
        .unwrap_or(DEFAULT_TIMEOUT_MS)
}
```

In `ServerCore::start`, replace the port loop body with checked addition:

```rust
            for offset in 0..PORT_PROBE_LIMIT {
                let Some(port) = port_hint.checked_add(offset) else {
                    break;
                };
                match TcpListener::bind(("127.0.0.1", port)).await {
                    Ok(l) => return Ok((l, port)),
                    Err(_) => continue,
                }
            }
```

Replace the environment parsing block with:

```rust
        let timeout_ms = handler_timeout_from_env();
```

- [ ] **Step 4: Make accept loop resilient and prepare semaphore**

Update imports in `server.rs`:

```rust
use tokio::sync::{mpsc, oneshot, Semaphore};
```

In `start`, create a semaphore before spawning `accept_loop`:

```rust
        let connection_limit = Arc::new(Semaphore::new(MAX_CONNECTIONS));
        rt.spawn(accept_loop(
            listener,
            in_tx,
            id_counter,
            timeout_ms,
            shutdown_rx,
            expected_token,
            connection_limit,
        ));
```

Update `accept_loop` signature:

```rust
async fn accept_loop(
    listener: TcpListener,
    in_tx: mpsc::Sender<PendingRequest>,
    id_counter: Arc<AtomicU64>,
    timeout_ms: u64,
    mut shutdown_rx: oneshot::Receiver<()>,
    expected_token: Option<String>,
    connection_limit: Arc<Semaphore>,
) {
```

Replace the `Ok((stream, _))` arm with:

```rust
                    Ok((mut stream, _)) => {
                        let Ok(permit) = connection_limit.clone().try_acquire_owned() else {
                            let _ = stream
                                .write_all(&write_response(503, &[], b"{\"error\":\"too many connections\"}"))
                                .await;
                            let _ = stream.shutdown().await;
                            continue;
                        };
                        let tx = in_tx.clone();
                        let id_c = id_counter.clone();
                        let token = expected_token.clone();
                        tokio::spawn(async move {
                            let _permit = permit;
                            handle_connection(stream, tx, id_c, timeout_ms, token).await;
                        });
                    }
```

Replace `Err(_) => break,` with:

```rust
                    Err(_) => continue,
```

- [ ] **Step 5: Run focused tests**

Run: `cargo test -p gdapi server::tests::handler_timeout_env` and `cargo test -p gdapi server::tests::start_near_u16_max_does_not_wrap_or_panic`

Expected: PASS.

- [ ] **Step 6: Run full gdapi tests**

Run: `cargo test -p gdapi`

Expected: PASS.

---

### Task 4: Bounded Queue Send and Pending Lifecycle Cleanup

**Files:**
- Modify: `gdapi/rust/src/queue.rs:8-91`
- Modify: `gdapi/rust/src/server.rs:12-199,326-358`
- Test: `gdapi/rust/tests/server_e2e.rs`

**Interfaces:**
- Produces: `PendingMap::insert(id: u64, tx: oneshot::Sender<HttpResponse>, deadline: Instant)`
- Produces: `PendingMap::remove_expired(now: Instant) -> usize`
- Produces: `PendingMap::len(&self) -> usize`
- Produces: `ServerCore::pending_len(&self) -> usize`
- Consumes: `timeout_ms` in `ServerCore::poll_for_godot` to calculate deadlines

- [ ] **Step 1: Add queue unit tests**

At the bottom of `gdapi/rust/src/queue.rs`, add:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn pending_map_removes_expired_entries() {
        let mut map = PendingMap::default();
        let (expired_tx, _expired_rx) = oneshot::channel();
        let (live_tx, _live_rx) = oneshot::channel();
        let now = Instant::now();

        map.insert(1, expired_tx, now - Duration::from_millis(1));
        map.insert(2, live_tx, now + Duration::from_secs(1));

        assert_eq!(map.remove_expired(now), 1);
        assert_eq!(map.len(), 1);
        assert!(map.take(1).is_none());
        assert!(map.take(2).is_some());
    }
}
```

- [ ] **Step 2: Add e2e test for timeout cleanup**

In `gdapi/rust/tests/server_e2e.rs`, add:

```rust
#[test]
fn server_cleans_pending_after_handler_timeout() {
    std::env::set_var("GDAPI_HANDLER_TIMEOUT_MS", "300");
    let mut server = ServerCore::new();
    let port = server.start(17940, None).expect("start");

    let handle = thread::spawn(move || {
        let url = format!("http://127.0.0.1:{}/slow-cleanup", port);
        let resp = ureq::post(&url).send_string("{}");
        match resp {
            Err(ureq::Error::Status(code, _)) => assert_eq!(code, 504),
            other => panic!("expected 504, got {:?}", other),
        }
    });

    let mut saw_request = false;
    for _ in 0..20 {
        if server.poll_for_godot().is_some() {
            saw_request = true;
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    assert!(saw_request, "did not receive request");

    thread::sleep(Duration::from_millis(700));
    assert_eq!(server.pending_len(), 0);
    handle.join().expect("client thread panicked");
    server.stop();
    std::env::remove_var("GDAPI_HANDLER_TIMEOUT_MS");
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cargo test -p gdapi queue::tests::pending_map_removes_expired_entries` and `cargo test -p gdapi server_cleans_pending_after_handler_timeout`

Expected: FAIL because pending deadlines and `pending_len` do not exist yet.

- [ ] **Step 4: Implement pending deadlines**

In `gdapi/rust/src/queue.rs`, update imports:

```rust
use std::time::Instant;
```

Add internal entry type and update `PendingMap`:

```rust
struct PendingEntry {
    tx: oneshot::Sender<HttpResponse>,
    deadline: Instant,
}

#[derive(Default)]
pub struct PendingMap {
    inner: HashMap<u64, PendingEntry>,
}
```

Replace `insert`, `take`, and `drain_503`, then add cleanup helpers:

```rust
    pub fn insert(&mut self, id: u64, tx: oneshot::Sender<HttpResponse>, deadline: Instant) {
        self.inner.insert(id, PendingEntry { tx, deadline });
    }

    pub fn take(&mut self, id: u64) -> Option<oneshot::Sender<HttpResponse>> {
        self.inner.remove(&id).map(|entry| entry.tx)
    }

    pub fn remove_expired(&mut self, now: Instant) -> usize {
        let before = self.inner.len();
        self.inner.retain(|_, entry| entry.deadline > now);
        before - self.inner.len()
    }

    pub fn len(&self) -> usize {
        self.inner.len()
    }

    pub fn drain_503(&mut self) {
        for (_, entry) in self.inner.drain() {
            let _ = entry.tx.send(HttpResponse {
                status: 503,
                headers: vec![("content-type".into(), "application/json".into())],
                body: br#"{\"error\":\"server shutting down\"}"#.to_vec(),
            });
        }
    }
```

- [ ] **Step 5: Wire deadlines into ServerCore**

In `gdapi/rust/src/server.rs`, import `Instant`:

```rust
use std::time::{Duration, Instant};
```

Add `handler_timeout_ms: u64` field to `ServerCore` and initialize it in `new()`:

```rust
    handler_timeout_ms: u64,
```

```rust
            handler_timeout_ms: DEFAULT_TIMEOUT_MS,
```

In `start`, after `let timeout_ms = handler_timeout_from_env();`, set:

```rust
        self.handler_timeout_ms = timeout_ms;
```

Add methods to `impl ServerCore`:

```rust
    fn cleanup_expired_pending(&mut self) {
        let _ = self.pending.remove_expired(Instant::now());
    }

    pub fn pending_len(&mut self) -> usize {
        self.cleanup_expired_pending();
        self.pending.len()
    }
```

At the start of `send_response_raw` and `poll_for_godot`, call:

```rust
        self.cleanup_expired_pending();
```

In `poll_for_godot`, replace `self.pending.insert(id, req.resp_tx);` with:

```rust
        let deadline = Instant::now() + Duration::from_millis(self.handler_timeout_ms);
        self.pending.insert(id, req.resp_tx, deadline);
```

- [ ] **Step 6: Bound queue send**

In `handle_connection`, replace:

```rust
    if in_tx.send(pending).await.is_err() {
```

with:

```rust
    if in_tx.try_send(pending).is_err() {
```

Keep the existing `503` response body.

- [ ] **Step 7: Run focused tests**

Run: `cargo test -p gdapi queue::tests::pending_map_removes_expired_entries` and `cargo test -p gdapi server_cleans_pending_after_handler_timeout`

Expected: PASS.

- [ ] **Step 8: Run full gdapi tests**

Run: `cargo test -p gdapi`

Expected: PASS.

---

### Task 5: Validate Godot Response Boundary

**Files:**
- Modify: `gdapi/rust/src/lib.rs:19-165`
- Modify: `gdapi/rust/src/server.rs:164-181`
- Test: `gdapi/rust/src/server.rs` tests or existing Rust compile tests

**Interfaces:**
- Consumes: `crate::http::validate_response_header(name: &str, value: &str) -> io::Result<()>`
- Produces: `ServerCore::send_response_raw(...) -> Result<(), String>`
- Produces: Godot boundary rejects negative ids, invalid status, and invalid headers without panicking

- [ ] **Step 1: Add ServerCore tests for invalid response input**

In `gdapi/rust/src/server.rs` test module, add:

```rust
    #[test]
    fn send_response_raw_rejects_invalid_status() {
        let mut server = ServerCore::new();
        let result = server.send_response_raw(1, 99, vec![], b"bad".to_vec());
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("invalid HTTP status"));
    }

    #[test]
    fn send_response_raw_rejects_invalid_header() {
        let mut server = ServerCore::new();
        let result = server.send_response_raw(
            1,
            200,
            vec![("x-bad".into(), "ok\r\nInjected: yes".into())],
            b"bad".to_vec(),
        );
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("header value contains CR/LF"));
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p gdapi server::tests::send_response_raw_rejects_invalid`

Expected: FAIL because `send_response_raw` currently returns `()` and does not validate.

- [ ] **Step 3: Implement `send_response_raw` validation**

In `gdapi/rust/src/server.rs`, update import:

```rust
use crate::http::{parse_request, validate_response_header, write_response, ParsedRequest, MAX_HEADER_BYTES};
```

Change `send_response_raw` signature and body:

```rust
    pub fn send_response_raw(
        &mut self,
        id: u64,
        status: u16,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
    ) -> Result<(), String> {
        self.cleanup_expired_pending();
        if !(100..=599).contains(&status) {
            return Err(format!("invalid HTTP status: {}", status));
        }
        for (k, v) in &headers {
            validate_response_header(k, v).map_err(|e| e.to_string())?;
        }
        if let Some(tx) = self.pending.take(id) {
            let _ = tx.send(HttpResponse { status, headers, body });
        }
        Ok(())
    }
```

- [ ] **Step 4: Update tests using `send_response_raw`**

In `gdapi/rust/tests/server_e2e.rs`, if any call to `server.send_response_raw(...)` exists, append `.expect("send response")`.

If none exist, no change is required.

- [ ] **Step 5: Validate Godot boundary in `lib.rs`**

In `gdapi/rust/src/lib.rs`, update imports:

```rust
use godot::prelude::*;
use http::validate_response_header;
use server::ServerCore;
```

In `send_response`, before building headers, add:

```rust
        if id < 0 {
            godot_error!("[gdapi] send_response rejected negative request id: {}", id);
            return;
        }
        if !(100..=599).contains(&status) {
            godot_error!("[gdapi] send_response rejected invalid HTTP status: {}", status);
            return;
        }
```

Inside the header loop, replace direct push with validation:

```rust
            if let Err(e) = validate_response_header(&kk, &vv) {
                godot_error!("[gdapi] send_response rejected invalid header: {}", e);
                return;
            }
            hdrs.push((kk, vv));
```

Replace the final call with:

```rust
        if let Err(e) = self.core.send_response_raw(id as u64, status as u16, hdrs, body_vec) {
            godot_error!("[gdapi] send_response failed: {}", e);
        }
```

- [ ] **Step 6: Run focused tests**

Run: `cargo test -p gdapi server::tests::send_response_raw_rejects_invalid`

Expected: PASS.

- [ ] **Step 7: Run full gdapi tests**

Run: `cargo test -p gdapi`

Expected: PASS.

---

### Task 6: Final Robustness Sweep and Documentation Check

**Files:**
- Modify: `gdapi/rust/src/http.rs`
- Modify: `gdapi/rust/src/server.rs`
- Modify: `gdapi/rust/src/queue.rs`
- Modify: `gdapi/rust/src/lib.rs`
- Test: `gdapi/rust/tests/server_e2e.rs`

**Interfaces:**
- Consumes: all interfaces from Tasks 1-5
- Produces: verified implementation matching `docs/superpowers/specs/2026-06-24-gdapi-rust-robustness-design.md`

- [ ] **Step 1: Search for production panics and unchecked casts**

Run: `rg "panic!|unwrap\(|expect\(|todo!|unimplemented!|as u16|as u64" gdapi/rust/src gdapi/rust/tests/server_e2e.rs`

Expected: matches in tests are acceptable. In `gdapi/rust/src`, there should be no `panic!`, `unwrap()`, `expect()`, `todo!`, or `unimplemented!` in production request/Godot paths. Remaining `as u16` and `as u64` casts in `lib.rs` must be guarded by range checks immediately before the cast.

- [ ] **Step 2: Run formatter**

Run: `cargo fmt -p gdapi`

Expected: command exits successfully.

- [ ] **Step 3: Run full tests**

Run: `cargo test -p gdapi`

Expected: PASS.

- [ ] **Step 4: Inspect diff for accidental unrelated changes**

Run: `git diff -- gdapi/rust/src/http.rs gdapi/rust/src/server.rs gdapi/rust/src/queue.rs gdapi/rust/src/lib.rs gdapi/rust/tests/server_e2e.rs docs/superpowers/specs/2026-06-24-gdapi-rust-robustness-design.md docs/superpowers/plans/2026-06-24-gdapi-rust-robustness.md`

Expected: diff only contains robustness changes and the approved docs/plan.

- [ ] **Step 5: Final verification command**

Run: `cargo test -p gdapi`

Expected: PASS, with all unit tests and e2e tests passing.

---

## Self-Review

- Spec coverage: Tasks cover fallible response serialization, header read bounds, accept loop resilience, connection limits, queue send bounds, timeout clamping, checked port probing, Godot boundary validation, pending cleanup, and test verification.
- Red-flag scan: No deferred implementation notes or vague steps remain; code snippets and commands are included for each task.
- Type consistency: `validate_response_header`, `try_write_response`, `PendingMap::insert`, `PendingMap::remove_expired`, `ServerCore::pending_len`, and `ServerCore::send_response_raw` signatures are consistent across tasks.
