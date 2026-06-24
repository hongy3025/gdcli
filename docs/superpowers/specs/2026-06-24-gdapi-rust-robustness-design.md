# gdapi Rust Robustness Design

Date: 2026-06-24

## Context

`gdapi/rust` is a Godot GDExtension plugin that hosts a lightweight local HTTP service. Because it runs inside the Godot editor or game process, Rust-side failures must not terminate the host process, break the HTTP accept loop, stall Godot's main thread, or let a single malformed request degrade the whole service.

The current Rust surface is intentionally small:

- `http.rs`: HTTP request parsing and response serialization.
- `server.rs`: Tokio runtime, TCP accept loop, connection tasks, request queue, response waiting.
- `queue.rs`: pending request and response channels.
- `lib.rs`: Godot-facing `GdApiServer` wrapper.

Existing tests pass, but review found robustness gaps around panics, unchecked casts, unbounded reads/concurrency, and stale pending responses.

## Goals

- No Rust panic in normal request/response paths, including malicious or invalid input.
- No single request can stop the accept loop or permanently occupy a connection task.
- No invalid Godot-side response input can corrupt protocol output or terminate a thread/process.
- Resource use is bounded for header bytes, body bytes, concurrent connections, queue pressure, and pending responses.
- Godot main-thread polling remains non-blocking.
- Existing successful request flow keeps working.

## Non-Goals

- Implementing a complete HTTP/1.1 server.
- Supporting chunked transfer encoding or keep-alive.
- Rewriting routing or GDScript handler behavior.
- Adding metrics or external observability beyond concise Godot error logging.

## Recommended Approach

Use a safety-tightening refactor inside the existing architecture. Keep `ServerCore`, `http`, and `queue` boundaries, but make every external boundary validate input and make async service loops resilient to per-request failures.

This is preferred over a minimal panic-only patch because the plugin's process-safety requirement includes slow clients, connection floods, queue pressure, and invalid Godot responses. It is also preferred over a larger framework rewrite because the current codebase is compact and can be made robust with targeted changes.

## HTTP Encoding and Parsing

Response serialization must become fallible or internally safe. `write_response` should no longer panic when a response header contains CR/LF. The implementation should either:

- Return `io::Result<Vec<u8>>` from a `try_write_response` function and let callers fall back to a safe `500` response.
- Or sanitize/drop invalid headers while preserving protocol safety.

The preferred behavior is to reject invalid response headers and write a safe internal error response. Header names must be non-empty and must not contain CR/LF. Header values must not contain CR/LF. User-provided `content-length` and `connection` headers should be ignored or rejected because the serializer owns those fields.

Request parsing keeps the existing `MAX_BODY = 16 MiB` limit. Add a header/read-prefix limit such as `MAX_HEADER_BYTES = 32 KiB`. If the parser has not reached complete headers before this limit, return an error and close the request with `400` or `413`. This prevents slow or malformed clients from growing memory until the read timeout.

Malformed requests continue to return `400`. Oversized bodies continue to return `413`. These failures must not affect other connections.

## Server Loop and Resource Bounds

The accept loop must not exit because of one transient `accept()` error. It should continue after logging recoverable errors and exit only on shutdown or unrecoverable listener failure. This keeps the HTTP service main loop alive under per-connection errors.

Add a concurrent connection bound, for example `MAX_CONNECTIONS = 128`, using `tokio::sync::Semaphore`. If the bound is reached, the server should return a short `503` response or close the connection. This prevents unbounded task spawning.

The request queue to Godot is already bounded by `mpsc::channel(256)`, but `send().await` can wait indefinitely when the queue is full. Change this path to `try_send` or a short timeout. On failure, respond with `503` and close the connection. This prevents connection tasks from piling up behind an unpolled Godot main thread.

Clamp `GDAPI_HANDLER_TIMEOUT_MS` to a safe range, for example `100..=300_000`. Invalid, zero, or excessive values should fall back to `DEFAULT_TIMEOUT_MS`.

Port probing should use `checked_add` instead of `port_hint + offset`. If the range reaches `u16::MAX`, probing stops cleanly with an error instead of panicking in debug builds or wrapping in release builds.

## Godot Boundary

`GdApiServer::send_response` should validate arguments before converting types:

- Negative `id` is invalid and should be rejected with `godot_error!`.
- `status` must be within `100..=599`. Invalid status should be rejected and logged.
- Headers should be validated before being passed into core response handling.
- Body conversion may remain `PackedByteArray::to_vec()` because request body size is already bounded and response size is controlled by the caller, but large response behavior should be considered in future limits if needed.

Rejected Godot responses must not panic. The pending HTTP request will be resolved by timeout cleanup or by an explicit internal error response depending on the implementation choice. Prefer quick internal failure when possible, but avoid introducing blocking behavior on the Godot thread.

`poll_request()` remains non-blocking and only converts one pending request per call.

## Pending Lifecycle

`PendingMap` currently stores response senders without tracking deadlines. Add enough metadata to remove stale entries after handler timeout. Cleanup can run from `poll_for_godot()`, `send_response_raw()`, and `stop()`.

When a request times out, the connection task returns `504`. The corresponding pending entry should not remain indefinitely. If the Godot side later tries to respond to an expired request, the server should ignore it and optionally log a concise warning.

`stop()` continues to drain all pending responses with `503` before shutting down the runtime in the background.

## Error Handling Policy

- External input errors: return `400`, `401`, `413`, `503`, or `504` as appropriate.
- Internal response serialization errors: return safe `500` when a connection is still available.
- Shutdown: return `503` to waiting or newly queued requests.
- Logging: use `godot_error!` only at Godot-facing boundaries and avoid noisy per-byte/per-loop logs.
- Panics: no `panic!`, `unwrap()`, or `expect()` in production paths touched by HTTP requests or Godot input.

## Testing Plan

Add or update Rust tests for:

- Invalid response header name/value does not panic and produces an error or safe fallback.
- `write_response` no longer has panic-based tests.
- Incomplete header data beyond `MAX_HEADER_BYTES` is rejected without unbounded growth.
- `port_hint` near `u16::MAX` does not panic or wrap.
- Handler timeout cleans pending entries or makes late responses harmless.
- Full request queue returns `503` instead of waiting indefinitely.
- Invalid status and negative id are rejected without panic.
- Existing e2e tests keep passing.

Verification command:

```powershell
cargo test -p gdapi
```

## Implementation Decision

The implementation will add explicit fallible response serialization and safe fallback responses at call sites. If preserving a simple trusted helper keeps call sites clearer, it may wrap the fallible serializer, but no production request path may panic on invalid headers or status data.
