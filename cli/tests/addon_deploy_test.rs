//! gdcli install 子命令集成测试。
//!
//! 测试 addon 安装功能：
//! - addon 目录和文件创建
//! - project.godot 插件启用
//! - --no-enable 标志
//! - 重复安装检测
//! - --force 强制覆盖
//! - 项目目录验证
//! - 自动项目根目录检测

use assert_cmd::Command;
use std::fs;
use tempfile::TempDir;

/// 创建临时的 Godot 项目目录（包含 project.godot）。
///
/// # Arguments
/// * `dir` - 目标目录路径
fn make_godot_project(dir: &std::path::Path) {
    fs::write(
        dir.join("project.godot"),
        "config_version=5\n\n[application]\nconfig/name=\"test\"\n",
    )
    .unwrap();
}

#[test]
fn install_creates_addon_directory() {
    let dir = TempDir::new().unwrap();
    make_godot_project(dir.path());

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["install", "--project", dir.path().to_str().unwrap()])
        .assert()
        .success()
        .stdout(predicates::str::contains("Installed gdapi"));

    // Verify addon files exist
    assert!(dir.path().join("addons/gdapi/plugin.cfg").exists());
    assert!(dir.path().join("addons/gdapi/plugin.gd").exists());
    assert!(dir.path().join("addons/gdapi/gdapi.gdextension").exists());
    assert!(dir.path().join("addons/gdapi/runtime/router.gd").exists());
    assert!(dir
        .path()
        .join("addons/gdapi/runtime/route_handler.gd")
        .exists());
}

#[test]
fn install_enables_plugin_in_project_godot() {
    let dir = TempDir::new().unwrap();
    make_godot_project(dir.path());

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["install", "--project", dir.path().to_str().unwrap()])
        .assert()
        .success();

    let content = fs::read_to_string(dir.path().join("project.godot")).unwrap();
    assert!(content.contains("[editor_plugins]"));
    assert!(content.contains("res://addons/gdapi/plugin.cfg"));
}

#[test]
fn install_no_enable_flag() {
    let dir = TempDir::new().unwrap();
    make_godot_project(dir.path());

    Command::cargo_bin("gdcli")
        .unwrap()
        .args([
            "install",
            "--project",
            dir.path().to_str().unwrap(),
            "--no-enable",
        ])
        .assert()
        .success();

    let content = fs::read_to_string(dir.path().join("project.godot")).unwrap();
    assert!(!content.contains("gdapi"));
}

#[test]
fn install_fails_if_already_installed() {
    let dir = TempDir::new().unwrap();
    make_godot_project(dir.path());

    // First install
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["install", "--project", dir.path().to_str().unwrap()])
        .assert()
        .success();

    // Second install without --force
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["install", "--project", dir.path().to_str().unwrap()])
        .assert()
        .failure()
        .stderr(predicates::str::contains("already installed"));
}

#[test]
fn install_force_overwrites() {
    let dir = TempDir::new().unwrap();
    make_godot_project(dir.path());

    // First install
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["install", "--project", dir.path().to_str().unwrap()])
        .assert()
        .success();

    // Second install with --force
    Command::cargo_bin("gdcli")
        .unwrap()
        .args([
            "install",
            "--project",
            dir.path().to_str().unwrap(),
            "--force",
        ])
        .assert()
        .success()
        .stdout(predicates::str::contains("Installed gdapi"));
}

#[test]
fn install_fails_without_project_godot() {
    let dir = TempDir::new().unwrap();

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["install", "--project", dir.path().to_str().unwrap()])
        .assert()
        .failure()
        .stderr(predicates::str::contains("not a Godot project"));
}

#[test]
fn install_auto_detects_project_root() {
    let dir = TempDir::new().unwrap();
    make_godot_project(dir.path());
    let sub = dir.path().join("src");
    fs::create_dir(&sub).unwrap();

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["install"])
        .current_dir(&sub)
        .assert()
        .success();

    assert!(dir.path().join("addons/gdapi/plugin.cfg").exists());
}

#[test]
fn install_includes_m1_runtime_helpers() {
    let dir = TempDir::new().unwrap();
    make_godot_project(dir.path());

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["install", "--project", dir.path().to_str().unwrap()])
        .assert()
        .success();

    for file in [
        "addons/gdapi/runtime/error_codes.gd",
        "addons/gdapi/runtime/path_guard.gd",
        "addons/gdapi/runtime/variant_codec.gd",
        "addons/gdapi/runtime/edit_action.gd",
        "addons/gdapi/routes/gdapi/health/pathcheck.gd",
        "addons/gdapi/runtime/audit_log.gd",
        "addons/gdapi/routes/gdapi/audit/list.gd",
        "addons/gdapi/routes/gdapi/audit/clear.gd",
    ] {
        assert!(
            dir.path().join(file).exists(),
            "missing installed file: {file}"
        );
    }
}
