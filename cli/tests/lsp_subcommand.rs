//! gdcli lsp 子命令集成测试。
//!
//! 验证 lsp 子命令的命令行解析是否正确。

use assert_cmd::Command;
use predicates::prelude::*;

#[test]
fn lsp_rename_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["--port", "1", "lsp", "rename", "player.gd:10:5", "new_name"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Failed to connect"));
}

#[test]
fn lsp_references_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["--port", "1", "lsp", "references", "player.gd:10:5"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Failed to connect"));
}

#[test]
fn lsp_definition_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["--port", "1", "lsp", "definition", "player.gd:10:5"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Failed to connect"));
}

#[test]
fn lsp_declaration_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["--port", "1", "lsp", "declaration", "player.gd:10:5"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Failed to connect"));
}

#[test]
fn lsp_hover_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["--port", "1", "lsp", "hover", "player.gd:10:5"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Failed to connect"));
}

#[test]
fn lsp_symbols_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["--port", "1", "lsp", "symbols", "player.gd"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Failed to connect"));
}

#[test]
fn lsp_native_symbol_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["--port", "1", "lsp", "native-symbol", "Node3D"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Failed to connect"));
}

#[test]
fn lsp_diagnostics_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["--port", "1", "lsp", "diagnostics"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Failed to connect"));
}

#[test]
fn lsp_capabilities_parses_correctly() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["--port", "1", "lsp", "capabilities"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Failed to connect"));
}

#[test]
fn old_top_level_rename_fails() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["rename", "player.gd:10:5", "new_name"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("error"));
}
