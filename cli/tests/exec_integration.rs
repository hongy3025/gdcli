//! gdcli exec 子命令集成测试。
//!
//! 用 httpmock 模拟 gdapi server，验证：
//! - .godot/gdapi.json 读取
//! - HTTP 调用
//! - stdout/stderr/退出码

use assert_cmd::Command;
use httpmock::prelude::*;
use std::fs;
use tempfile::TempDir;

fn setup_fake_project(meta_json: &str) -> TempDir {
    let dir = TempDir::new().unwrap();
    let project_path = dir.path();
    fs::write(project_path.join("project.godot"), "; fake\nconfig_version=5\n").unwrap();
    fs::create_dir(project_path.join(".godot")).unwrap();
    fs::write(project_path.join(".godot").join("gdapi.json"), meta_json).unwrap();
    dir
}

#[test]
fn exec_ping_success() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(POST).path("/ping");
        then.status(200)
            .header("content-type", "application/json")
            .body(r#"{"ok":true,"gdapi_version":"0.2.0"}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"lsp_port":6005,"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "ping", "--project", dir.path().to_str().unwrap()])
        .assert()
        .success()
        .stdout(predicates::str::contains(r#""ok":true"#));

    mock.assert();
}

#[test]
fn exec_with_data_literal_json() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(POST)
            .path("/echo")
            .json_body_obj(&serde_json::json!({"hello":"world"}));
        then.status(200).body(r#"{"ok":true}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    Command::cargo_bin("gdcli")
        .unwrap()
        .args([
            "exec",
            "echo",
            "--data",
            r#"{"hello":"world"}"#,
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .assert()
        .success();

    mock.assert();
}

#[test]
fn exec_404_exits_with_code_2() {
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(POST).path("/missing");
        then.status(404).body(r#"{"error":"route not found"}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "missing", "--project", dir.path().to_str().unwrap()])
        .assert()
        .failure()
        .code(2)
        .stderr(predicates::str::contains("HTTP 404"));
}

#[test]
fn exec_500_exits_with_code_1() {
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(POST).path("/boom");
        then.status(500).body(r#"{"error":"handler crashed"}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "boom", "--project", dir.path().to_str().unwrap()])
        .assert()
        .failure()
        .code(1)
        .stderr(predicates::str::contains("HTTP 500"));
}

#[test]
fn exec_invalid_json_data_fails_client_side() {
    let dir = setup_fake_project(
        r#"{"http_port":1,"pid":1,"gdapi_version":"0.2.0"}"#,
    );

    Command::cargo_bin("gdcli")
        .unwrap()
        .args([
            "exec",
            "x",
            "--data",
            "not-json",
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .assert()
        .failure()
        .code(2)
        .stderr(predicates::str::contains("invalid JSON"));
}

#[test]
fn exec_missing_meta_file_fails() {
    let dir = TempDir::new().unwrap();
    fs::write(dir.path().join("project.godot"), "; fake\n").unwrap();

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "ping", "--project", dir.path().to_str().unwrap()])
        .assert()
        .failure()
        .code(3)
        .stderr(predicates::str::contains("gdapi not running"));
}
