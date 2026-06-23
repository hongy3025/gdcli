//! LSP 端口发现集成测试。

use assert_cmd::Command;
use std::fs;
use std::time::Duration;
use tempfile::TempDir;

fn setup_project_with_gdapi_meta(meta_json: &str) -> TempDir {
    let dir = TempDir::new().unwrap();
    fs::write(dir.path().join("project.godot"), "config_version=5\n").unwrap();
    fs::create_dir(dir.path().join(".godot")).unwrap();
    fs::write(dir.path().join(".godot").join("gdapi.json"), meta_json).unwrap();
    dir
}

#[test]
fn lsp_uses_port_from_gdapi_meta() {
    let dir = setup_project_with_gdapi_meta(
        r#"{"http_port":7891,"lsp_port":39123,"pid":12345,"gdapi_version":"0.2.0"}"#,
    );

    Command::cargo_bin("gdcli")
        .unwrap()
        .timeout(Duration::from_secs(10))
        .args(["lsp", "capabilities", "--project", dir.path().to_str().unwrap()])
        .assert()
        .failure()
        .stderr(predicates::str::contains("39123"));
}

#[test]
fn lsp_explicit_port_overrides_meta() {
    let dir = setup_project_with_gdapi_meta(
        r#"{"http_port":7891,"lsp_port":39123,"pid":12345,"gdapi_version":"0.2.0"}"#,
    );

    Command::cargo_bin("gdcli")
        .unwrap()
        .timeout(Duration::from_secs(10))
        .args([
            "lsp",
            "capabilities",
            "--project",
            dir.path().to_str().unwrap(),
            "--port",
            "39124",
        ])
        .assert()
        .failure()
        .stderr(predicates::str::contains("39124"));
}

#[test]
fn lsp_falls_back_to_default_6005() {
    let dir = TempDir::new().unwrap();
    fs::write(dir.path().join("project.godot"), "config_version=5\n").unwrap();

    let output = Command::cargo_bin("gdcli")
        .unwrap()
        .timeout(Duration::from_secs(10))
        .args(["lsp", "capabilities", "--project", dir.path().to_str().unwrap()])
        .output()
        .unwrap();

    // Either connects to 6005 (success) or fails with 6005 in error message
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("6005"),
            "Expected port 6005 in stderr, got: {}",
            stderr
        );
    }
    // If success, a server happened to be running on 6005 — that's fine too
}

#[test]
fn status_uses_port_from_gdapi_meta() {
    let dir = setup_project_with_gdapi_meta(
        r#"{"http_port":7891,"lsp_port":39123,"pid":12345,"gdapi_version":"0.2.0"}"#,
    );

    Command::cargo_bin("gdcli")
        .unwrap()
        .timeout(Duration::from_secs(10))
        .args(["status", "--project", dir.path().to_str().unwrap()])
        .assert()
        .failure()
        .stderr(predicates::str::contains("39123"));
}
