//! gdapi server 集成测试——不依赖 Godot。
//!
//! 测试 ServerCore 的端到端功能：
//! - 请求接收和响应发送
//! - 端口探测机制
//! - 超大请求体处理（413 错误）
//! - 处理超时（504 错误）
//!
//! 这些测试直接使用 ServerCore，不依赖 Godot 引擎。

use gdapi::http::MAX_HEADER_BYTES;
use gdapi::process_runner::{PollOutcome, ProcessRunnerCore};
use gdapi::queue::{CancelReason, HttpResponse};
use gdapi::server::ServerCore;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

static ENV_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn server_accepts_request_and_routes_to_poll_send() {
    let mut server = ServerCore::new();
    let _guard = ENV_LOCK.lock().expect("env lock poisoned");
    let port = server.start(17890, None).expect("start should succeed");
    assert!((17890..17890 + 64).contains(&port));

    let handle = thread::spawn(move || {
        let url = format!("http://127.0.0.1:{}/ping", port);
        let resp = ureq::post(&url)
            .set("Content-Type", "application/json")
            .send_string(r#"{"hello":"world"}"#)
            .expect("http call failed");
        assert_eq!(resp.status(), 200);
        let body = resp.into_string().unwrap();
        assert!(body.contains("\"ok\":true"), "body was: {}", body);
        port
    });

    let mut got_request = false;
    for _ in 0..200 {
        if let Some(req) = server.poll_request_raw() {
            assert_eq!(req.method, "POST");
            assert_eq!(req.path, "/ping");
            assert!(!req.body.is_empty());
            let _ = req.resp_tx.send(HttpResponse {
                status: 200,
                headers: vec![("content-type".into(), "application/json".into())],
                body: br#"{"ok":true}"#.to_vec(),
            });
            got_request = true;
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }

    assert!(got_request, "did not receive request within timeout");
    handle.join().expect("client thread panicked");
    server.stop();
}

#[test]
fn server_port_probing_skips_occupied() {
    let mut a = ServerCore::new();
    let _guard = ENV_LOCK.lock().expect("env lock poisoned");
    let port_a = a.start(17900, None).expect("first start");

    let mut b = ServerCore::new();
    let port_b = b
        .start(17900, None)
        .expect("second start should find next port");

    assert_eq!(port_a, 17900);
    assert!(
        port_b > port_a,
        "expected port probing, got {} vs {}",
        port_b,
        port_a
    );
    a.stop();
    b.stop();
}

#[test]
fn server_returns_413_for_oversized_body() {
    let mut server = ServerCore::new();
    let _guard = ENV_LOCK.lock().expect("env lock poisoned");
    let port = server.start(17910, None).expect("start");

    let handle = thread::spawn(move || {
        let mut stream = TcpStream::connect(format!("127.0.0.1:{}", port)).unwrap();
        let req = "POST /big HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 17825792\r\nContent-Type: application/octet-stream\r\n\r\n";
        stream.write_all(req.as_bytes()).unwrap();
        stream.shutdown(std::net::Shutdown::Write).unwrap();

        let mut buf = vec![0u8; 4096];
        let n = stream.read(&mut buf).unwrap();
        let resp = String::from_utf8_lossy(&buf[..n]);
        assert!(
            resp.starts_with("HTTP/1.1 413"),
            "expected 413, got: {}",
            resp
        );
    });

    thread::sleep(Duration::from_millis(500));
    handle.join().expect("client thread panicked");
    server.stop();
}

#[test]
fn server_rejects_oversized_incomplete_headers() {
    let mut server = ServerCore::new();
    let _guard = ENV_LOCK.lock().expect("env lock poisoned");
    let port = server.start(17930, None).expect("start");

    let handle = thread::spawn(move || {
        let mut stream = TcpStream::connect(format!("127.0.0.1:{}", port)).unwrap();
        let oversized = format!(
            "GET /x HTTP/1.1\r\nX-Fill: {}",
            "a".repeat(MAX_HEADER_BYTES)
        );
        let started = Instant::now();
        stream.write_all(oversized.as_bytes()).unwrap();

        let mut buf = vec![0u8; 4096];
        let n = stream.read(&mut buf).unwrap();
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "oversized incomplete header was not rejected promptly"
        );
        let resp = String::from_utf8_lossy(&buf[..n]);
        assert!(
            resp.starts_with("HTTP/1.1 400"),
            "expected 400, got: {}",
            resp
        );
    });

    thread::sleep(Duration::from_millis(500));
    handle.join().expect("client thread panicked");
    server.stop();
}

#[test]
fn server_504_on_handler_timeout() {
    let _guard = ENV_LOCK.lock().expect("env lock poisoned");
    std::env::set_var("GDAPI_HANDLER_TIMEOUT_MS", "300");
    let mut server = ServerCore::new();
    let port = server.start(17920, None).expect("start");

    let handle = thread::spawn(move || {
        let url = format!("http://127.0.0.1:{}/slow", port);
        let resp = ureq::post(&url).send_string("{}");
        match resp {
            Err(ureq::Error::Status(code, _)) => assert_eq!(code, 504),
            other => panic!("expected 504, got {:?}", other),
        }
    });

    // 主线程故意不调 send_response，让超时触发
    thread::sleep(Duration::from_millis(800));
    handle.join().expect("client thread panicked");
    server.stop();
    std::env::remove_var("GDAPI_HANDLER_TIMEOUT_MS");
}

#[test]
fn server_cleans_pending_after_handler_timeout() {
    let _guard = ENV_LOCK.lock().expect("env lock poisoned");
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

fn poll_view(server: &mut ServerCore) -> gdapi::server::RequestView {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(request) = server.poll_for_godot() {
            return request;
        }
        assert!(Instant::now() < deadline, "HTTP request was not queued");
        thread::sleep(Duration::from_millis(5));
    }
}

struct HttpProcessFixture {
    root: std::path::PathBuf,
    ready: std::path::PathBuf,
    marker: std::path::PathBuf,
}

impl HttpProcessFixture {
    fn new() -> Self {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "gdapi-http-process-{}-{unique}",
            std::process::id()
        ));
        std::fs::create_dir(&root).unwrap();
        Self {
            ready: root.join("ready"),
            marker: root.join("late"),
            root,
        }
    }

    fn start(&self, runner: &ProcessRunnerCore, request: &gdapi::server::RequestView) -> i64 {
        let script = "import pathlib,sys,time; print('started',flush=True); pathlib.Path(sys.argv[1]).write_text('ready'); time.sleep(3); pathlib.Path(sys.argv[2]).write_text('late')";
        runner
            .start_for_request(
                &std::env::var("PYTHON").unwrap_or_else(|_| "python".into()),
                &[
                    "-c".into(),
                    script.into(),
                    self.ready.display().to_string(),
                    self.marker.display().to_string(),
                ],
                &self.root,
                60_000,
                8192,
                std::sync::Arc::clone(&request.control),
            )
            .expect("real request process should start")
    }

    fn wait_ready(&self) -> Instant {
        let deadline = Instant::now() + Duration::from_secs(2);
        while !self.ready.exists() {
            assert!(
                Instant::now() < deadline,
                "real request process did not start"
            );
            thread::sleep(Duration::from_millis(5));
        }
        Instant::now()
    }

    fn assert_no_late_marker(&self, ready_at: Instant) {
        thread::sleep(
            (ready_at + Duration::from_millis(3300)).saturating_duration_since(Instant::now()),
        );
        assert!(
            !self.marker.exists(),
            "HTTP cancellation allowed a delayed side effect"
        );
    }
}

impl Drop for HttpProcessFixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn send_process_request(port: u16) -> TcpStream {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stream
        .write_all(b"POST /process/run HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}")
        .unwrap();
    stream
}

#[test]
fn http_deadline_reaps_real_process_before_504() {
    let _guard = ENV_LOCK.lock().expect("env lock poisoned");
    std::env::set_var("GDAPI_HANDLER_TIMEOUT_MS", "2000");
    let mut server = ServerCore::new();
    let port = server.start(17950, None).unwrap();
    std::env::remove_var("GDAPI_HANDLER_TIMEOUT_MS");
    let mut client = send_process_request(port);
    let request = poll_view(&mut server);
    let fixture = HttpProcessFixture::new();
    let runner = ProcessRunnerCore::new();
    let id = fixture.start(&runner, &request);
    let ready_at = fixture.wait_ready();
    let mut response = String::new();
    client.read_to_string(&mut response).unwrap();
    assert!(response.starts_with("HTTP/1.1 504"), "{response}");
    assert!(ready_at.elapsed() < Duration::from_millis(2600));
    assert_eq!(request.control.reason(), Some(CancelReason::Timeout));
    let PollOutcome::Done(result) = runner.poll(id) else {
        panic!("504 preceded process terminal cleanup");
    };
    assert!(result.timed_out && !result.cancelled);
    assert!(result.stdout.contains("started"));
    fixture.assert_no_late_marker(ready_at);
}

#[test]
fn client_disconnect_cancels_real_request_process() {
    let _guard = ENV_LOCK.lock().expect("env lock poisoned");
    let mut server = ServerCore::new();
    let port = server.start(17960, None).unwrap();
    let client = send_process_request(port);
    let request = poll_view(&mut server);
    let fixture = HttpProcessFixture::new();
    let runner = ProcessRunnerCore::new();
    let id = fixture.start(&runner, &request);
    let ready_at = fixture.wait_ready();
    drop(client);
    let deadline = Instant::now() + Duration::from_secs(1);
    let result = loop {
        if let PollOutcome::Done(result) = runner.poll(id) {
            break result;
        }
        assert!(
            Instant::now() < deadline,
            "disconnect did not cancel the real process"
        );
        thread::sleep(Duration::from_millis(5));
    };
    assert!(result.cancelled && !result.timed_out);
    assert_eq!(request.control.reason(), Some(CancelReason::Disconnected));
    fixture.assert_no_late_marker(ready_at);
}

#[test]
fn server_shutdown_reaps_real_request_process() {
    let _guard = ENV_LOCK.lock().expect("env lock poisoned");
    let mut server = ServerCore::new();
    let port = server.start(17970, None).unwrap();
    let _client = send_process_request(port);
    let request = poll_view(&mut server);
    let fixture = HttpProcessFixture::new();
    let runner = ProcessRunnerCore::new();
    let id = fixture.start(&runner, &request);
    let ready_at = fixture.wait_ready();
    server.stop();
    let PollOutcome::Done(result) = runner.poll(id) else {
        panic!("shutdown left a process running");
    };
    assert!(result.cancelled && !result.timed_out);
    assert_eq!(request.control.reason(), Some(CancelReason::Shutdown));
    fixture.assert_no_late_marker(ready_at);
}
