//! gdapi server 集成测试——不依赖 Godot。
//!
//! 测试 ServerCore 的端到端功能：
//! - 请求接收和响应发送
//! - 端口探测机制
//! - 超大请求体处理（413 错误）
//! - 处理超时（504 错误）
//!
//! 这些测试直接使用 ServerCore，不依赖 Godot 引擎。

use gdapi::queue::HttpResponse;
use gdapi::server::ServerCore;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::thread;
use std::time::Duration;

#[test]
fn server_accepts_request_and_routes_to_poll_send() {
    let mut server = ServerCore::new();
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
    let port_a = a.start(17900, None).expect("first start");

    let mut b = ServerCore::new();
    let port_b = b.start(17900, None).expect("second start should find next port");

    assert_eq!(port_a, 17900);
    assert!(port_b > port_a, "expected port probing, got {} vs {}", port_b, port_a);
    a.stop();
    b.stop();
}

#[test]
fn server_returns_413_for_oversized_body() {
    let mut server = ServerCore::new();
    let port = server.start(17910, None).expect("start");

    let handle = thread::spawn(move || {
        let mut stream = TcpStream::connect(format!("127.0.0.1:{}", port)).unwrap();
        let req = "POST /big HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 17825792\r\nContent-Type: application/octet-stream\r\n\r\n";
        stream.write_all(req.as_bytes()).unwrap();
        stream.shutdown(std::net::Shutdown::Write).unwrap();

        let mut buf = vec![0u8; 4096];
        let n = stream.read(&mut buf).unwrap();
        let resp = String::from_utf8_lossy(&buf[..n]);
        assert!(resp.starts_with("HTTP/1.1 413"), "expected 413, got: {}", resp);
    });

    thread::sleep(Duration::from_millis(500));
    handle.join().expect("client thread panicked");
    server.stop();
}

#[test]
fn server_504_on_handler_timeout() {
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
