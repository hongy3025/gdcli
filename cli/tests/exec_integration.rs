//! gdcli exec 子命令集成测试。
//!
//! 用 httpmock 模拟 gdapi server，验证：
//! - .godot/gdapi.json 读取
//! - HTTP 调用
//! - stdout/stderr/退出码
//!
//! 测试覆盖：
//! - 成功的 exec 调用（200 响应）
//! - 带 JSON 数据的 exec 调用
//! - 404 响应（退出码 2）
//! - 500 响应（退出码 1）
//! - 无效 JSON 数据（客户端错误，退出码 2）
//! - 元数据文件缺失（退出码 3）

use assert_cmd::Command;
use httpmock::prelude::*;
use std::fs;
use tempfile::TempDir;

/// 创建带有 gdapi 元数据的临时 Godot 项目目录。
///
/// # Arguments
/// * `meta_json` - gdapi.json 文件内容
///
/// # Returns
/// 临时目录（包含 project.godot 和 .godot/gdapi.json）
fn setup_fake_project(meta_json: &str) -> TempDir {
    let dir = TempDir::new().unwrap();
    let project_path = dir.path();
    fs::write(
        project_path.join("project.godot"),
        "; fake\nconfig_version=5\n",
    )
    .unwrap();
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
        .stdout(predicates::str::contains("ok: true"));

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
        .stderr(predicates::str::contains("Error (404)"));
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
        .stderr(predicates::str::contains("Error (500)"));
}

#[test]
fn exec_invalid_json_data_fails_client_side() {
    let dir = setup_fake_project(r#"{"http_port":1,"pid":1,"gdapi_version":"0.2.0"}"#);

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
        .stderr(predicates::str::contains("Godot 编辑器未响应"));
}

#[test]
fn exec_commands_list_passes_through_server_json() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(POST)
            .path("/commands")
            .json_body_obj(&serde_json::json!({}));
        then.status(200)
            .header("content-type", "application/json")
            .body(r#"{"ok":true,"commands":[{"path":"ping","summary":"健康检查","params":[]}]}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "commands", "--project", dir.path().to_str().unwrap()])
        .assert()
        .success()
        .stdout(predicates::str::contains("commands"))
        .stdout(predicates::str::contains("ping"));

    mock.assert();
}

#[test]
fn exec_non_help_with_positional_arg_is_rejected() {
    let dir = setup_fake_project(r#"{"http_port":1,"pid":1,"gdapi_version":"0.2.0"}"#);

    Command::cargo_bin("gdcli")
        .unwrap()
        .args([
            "exec",
            "ping",
            "unexpected",
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .assert()
        .failure()
        .code(2)
        .stderr(predicates::str::contains("positional"));
}

#[test]
fn exec_default_outputs_toon() {
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

    let output = Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "ping", "--project", dir.path().to_str().unwrap()])
        .output()
        .unwrap();

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "exit code should be 0; stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        stdout.contains("ok: true"),
        "expected TOON KV form, got: {stdout}"
    );
    assert!(
        stdout.contains("gdapi_version:"),
        "expected TOON key, got: {stdout}"
    );
    assert!(
        stdout.contains("0.2.0"),
        "expected version value, got: {stdout}"
    );
    assert!(
        !stdout.contains(r#""ok":true"#),
        "should NOT contain raw JSON, got: {stdout}"
    );

    mock.assert();
}

#[test]
fn exec_json_flag_outputs_raw_json() {
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

    let output = Command::cargo_bin("gdcli")
        .unwrap()
        .args([
            "--json",
            "exec",
            "ping",
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .output()
        .unwrap();

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success());
    assert_eq!(stdout.trim(), r#"{"ok":true,"gdapi_version":"0.2.0"}"#);

    mock.assert();
}

#[test]
fn exec_toon_tabular_uniform_array() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(POST).path("/commands");
        then.status(200)
            .header("content-type", "application/json")
            .body(r#"{"ok":true,"commands":[{"path":"ping","summary":"健康检查"},{"path":"echo","summary":"回显"}]}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"lsp_port":6005,"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    let output = Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "commands", "--project", dir.path().to_str().unwrap()])
        .output()
        .unwrap();

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(stdout.contains("ok: true"), "got: {stdout}");
    assert!(
        stdout.contains("commands[2|]{path|summary}:"),
        "expected pipe tabular header, got: {stdout}"
    );
    assert!(stdout.contains("ping|健康检查"), "got: {stdout}");

    mock.assert();
}

#[test]
fn exec_toon_with_r1_empty_array() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(POST).path("/commands");
        then.status(200)
            .header("content-type", "application/json")
            .body(r#"{"ok":true,"commands":[{"path":"ping","params":[]},{"path":"echo","params":["x"]}]}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"lsp_port":6005,"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    let output = Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "commands", "--project", dir.path().to_str().unwrap()])
        .output()
        .unwrap();

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success());
    assert!(
        stdout.contains("commands[2|]{path|params}:"),
        "R1 should coerce to tabular, got: {stdout}"
    );
    assert!(
        stdout.contains("ping|"),
        "empty array should become empty cell, got: {stdout}"
    );
    assert!(stdout.contains("echo|x"), "got: {stdout}");

    mock.assert();
}

#[test]
fn exec_toon_4xx_error_renders_in_stderr() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(POST).path("/unknown");
        then.status(404)
            .header("content-type", "application/json")
            .body(r#"{"ok":false,"code":"not_found","msg":"route not found: unknown"}"#);
    });

    let meta = format!(
        r#"{{"http_port":{},"lsp_port":6005,"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    let output = Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "unknown", "--project", dir.path().to_str().unwrap()])
        .output()
        .unwrap();

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(2),
        "4xx should exit 2; stderr={stderr}"
    );
    assert!(stderr.starts_with("Error (404): "), "got: {stderr}");
    assert!(
        stderr.contains("code: not_found"),
        "stderr should contain TOON-rendered error, got: {stderr}"
    );

    mock.assert();
}

#[test]
fn exec_non_json_body_passes_through() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(POST).path("/raw");
        then.status(200)
            .header("content-type", "text/plain")
            .body("hello world");
    });

    let meta = format!(
        r#"{{"http_port":{},"pid":{},"gdapi_version":"0.2.0"}}"#,
        server.port(),
        std::process::id()
    );
    let dir = setup_fake_project(&meta);

    let output = Command::cargo_bin("gdcli")
        .unwrap()
        .args(["exec", "raw", "--project", dir.path().to_str().unwrap()])
        .output()
        .unwrap();

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success());
    assert!(
        stdout.contains("hello world"),
        "non-JSON body should pass through, got: {stdout}"
    );

    mock.assert();
}

#[test]
fn exec_command_help_with_path_sends_command_body() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(POST)
            .path("/command-help")
            .json_body_obj(&serde_json::json!({"command": "editor/scene/save"}));
        then.status(200)
            .body(r#"{"ok":true,"doc":{"path":"editor/scene/save","summary":"保存场景"}}"#);
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
            "command-help",
            "editor/scene/save",
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .assert()
        .success()
        .stdout(predicates::str::contains("doc"));

    mock.assert();
}

#[test]
fn exec_command_help_nonexistent_path_returns_exit_code_2() {
    let server = MockServer::start();
    server.mock(|when, then| {
        when.method(POST).path("/command-help");
        then.status(404)
            .body(r#"{"ok":false,"code":"not_found","msg":"command not found: foo"}"#);
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
            "command-help",
            "foo",
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .assert()
        .failure()
        .code(2)
        .stderr(predicates::str::contains("Error (404)"));
}

#[test]
fn exec_command_help_with_data_flag_is_rejected() {
    let dir = setup_fake_project(r#"{"http_port":1,"pid":1,"gdapi_version":"0.2.0"}"#);

    Command::cargo_bin("gdcli")
        .unwrap()
        .args([
            "exec",
            "command-help",
            "--data",
            "{}",
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .assert()
        .failure()
        .code(2)
        .stderr(predicates::str::contains("--data"));
}
