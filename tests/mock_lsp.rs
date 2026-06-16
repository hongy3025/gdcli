//! 集成测试：mock 一个 LSP TCP 服务器，跑 gd-lsp-cli 子进程对拍输出。

use assert_cmd::Command;
use predicates::prelude::*;
use std::io::Write;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::Mutex;

/// 简单 MessageBuffer，用于测试中读取一帧。
struct Buf {
    data: Vec<u8>,
}

impl Buf {
    fn new() -> Self { Self { data: vec![] } }
    fn append(&mut self, b: &[u8]) { self.data.extend_from_slice(b); }
    fn try_read(&mut self) -> Option<String> {
        let pos = self.data.windows(4).position(|w| w == b"\r\n\r\n")?;
        let header = std::str::from_utf8(&self.data[..pos]).ok()?;
        let len: usize = header
            .lines()
            .find_map(|l| {
                let (k, v) = l.split_once(':')?;
                if k.eq_ignore_ascii_case("Content-Length") {
                    v.trim().parse().ok()
                } else {
                    None
                }
            })?;
        let body_start = pos + 4;
        if self.data.len() < body_start + len { return None; }
        let body = String::from_utf8_lossy(&self.data[body_start..body_start + len]).to_string();
        self.data.drain(..body_start + len);
        Some(body)
    }
}

fn frame(body: &str) -> Vec<u8> {
    format!("Content-Length: {}\r\n\r\n{}", body.len(), body).into_bytes()
}

/// 启动一个 mock LSP，按 `responder` 应答请求；同时在 initialize 后立即推送一条诊断。
async fn start_mock<F>(responder: F) -> u16
where
    F: Fn(&str, i64, &serde_json::Value) -> Option<String> + Send + Sync + 'static,
{
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let responder = Arc::new(responder);
    tokio::spawn(async move {
        let (sock, _) = listener.accept().await.unwrap();
        let (mut r, w) = sock.into_split();
        let writer = Arc::new(Mutex::new(w));
        let mut buf = Buf::new();
        let mut chunk = [0u8; 8192];
        loop {
            let n = match r.read(&mut chunk).await {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            buf.append(&chunk[..n]);
            while let Some(body) = buf.try_read() {
                let v: serde_json::Value = match serde_json::from_str(&body) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                let method = v.get("method").and_then(|x| x.as_str()).unwrap_or("").to_string();
                let id = v.get("id").and_then(|x| x.as_i64());
                let params = v.get("params").cloned().unwrap_or(serde_json::Value::Null);

                if let Some(id) = id {
                    if let Some(resp) = responder(&method, id, &params) {
                        let mut w = writer.lock().await;
                        w.write_all(&frame(&resp)).await.unwrap();
                        w.flush().await.unwrap();
                    }
                    // initialize 应答后推送一条诊断
                    if method == "initialize" {
                        let notif = r#"{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/x.gd","diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"severity":1,"message":"bad"}]}}"#;
                        let mut w = writer.lock().await;
                        w.write_all(&frame(notif)).await.unwrap();
                        w.flush().await.unwrap();
                    }
                }
            }
        }
    });
    port
}

fn write_temp_gd() -> tempfile::NamedTempFile {
    let mut f = tempfile::Builder::new().suffix(".gd").tempfile().unwrap();
    writeln!(f, "extends Node\nvar x = 1\n").unwrap();
    f
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rename_human_output() {
    let port = start_mock(|method, id, _| match method {
        "initialize" => Some(format!(
            r#"{{"jsonrpc":"2.0","id":{},"result":{{"capabilities":{{}}}}}}"#,
            id
        )),
        "textDocument/rename" => Some(format!(
            r#"{{"jsonrpc":"2.0","id":{},"result":{{"changes":{{"file:///tmp/x.gd":[{{"range":{{"start":{{"line":1,"character":4}},"end":{{"line":1,"character":5}}}},"newText":"y"}}]}}}}}}"#,
            id
        )),
        _ => None,
    })
    .await;

    let f = write_temp_gd();
    let path = f.path().to_path_buf();
    tokio::task::spawn_blocking(move || {
        Command::cargo_bin("gd-lsp-cli")
            .unwrap()
            .args(["--port", &port.to_string(), "rename"])
            .arg(&path)
            .args(["1", "4", "y"])
            .timeout(Duration::from_secs(10))
            .assert()
            .success()
            .stdout(predicate::str::contains("tmp/x.gd:"))
            .stdout(predicate::str::contains("1:4-1:5 → \"y\""));
    })
    .await
    .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rename_json_decodes_uris() {
    let port = start_mock(|method, id, _| match method {
        "initialize" => Some(format!(
            r#"{{"jsonrpc":"2.0","id":{},"result":{{"capabilities":{{}}}}}}"#,
            id
        )),
        "textDocument/rename" => Some(format!(
            r#"{{"jsonrpc":"2.0","id":{},"result":{{"changes":{{"file:///tmp/x.gd":[{{"range":{{"start":{{"line":0,"character":0}},"end":{{"line":0,"character":1}}}},"newText":"z"}}]}}}}}}"#,
            id
        )),
        _ => None,
    })
    .await;

    let f = write_temp_gd();
    let path = f.path().to_path_buf();
    tokio::task::spawn_blocking(move || {
        let out = Command::cargo_bin("gd-lsp-cli")
            .unwrap()
            .args(["--port", &port.to_string(), "--json", "rename"])
            .arg(&path)
            .args(["0", "0", "z"])
            .timeout(Duration::from_secs(10))
            .assert()
            .success();
        let stdout = String::from_utf8(out.get_output().stdout.clone()).unwrap();
        assert!(!stdout.contains("file:///"), "URI should be decoded: {}", stdout);
        assert!(stdout.contains("tmp/x.gd"));
    })
    .await
    .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn diagnostics_receives_pushed() {
    let port = start_mock(|method, id, _| match method {
        "initialize" => Some(format!(
            r#"{{"jsonrpc":"2.0","id":{},"result":{{"capabilities":{{}}}}}}"#,
            id
        )),
        _ => None,
    })
    .await;

    tokio::task::spawn_blocking(move || {
        Command::cargo_bin("gd-lsp-cli")
            .unwrap()
            .args(["--port", &port.to_string(), "diagnostics"])
            .timeout(Duration::from_secs(15))
            .assert()
            .success()
            .stdout(predicate::str::contains("tmp/x.gd"))
            .stdout(predicate::str::contains("[error]"))
            .stdout(predicate::str::contains("bad"));
    })
    .await
    .unwrap();
}

#[test]
fn connection_failure_prints_hint() {
    Command::cargo_bin("gd-lsp-cli")
        .unwrap()
        // 1 端口几乎肯定不会有 LSP 监听
        .args(["--port", "1", "capabilities"])
        .timeout(Duration::from_secs(15))
        .assert()
        .failure()
        .stderr(predicate::str::contains("Failed to connect to Godot LSP at 127.0.0.1:1"))
        .stderr(predicate::str::contains(
            "Make sure Godot is running with: godot --editor --headless --lsp-port 1",
        ));
}
