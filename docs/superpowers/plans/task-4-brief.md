# Task 4: 集成到 exec 模块

**Files:**
- Modify: `cli/src/exec.rs:90-102`

**Interfaces:**
- Consumes: `format::clap_style::render_commands` 和 `format::clap_style::render_command_help`
- Produces: 修改后的 exec 命令渲染逻辑

- [ ] **Step 1: 编写集成测试**

在 `cli/tests/exec_integration.rs` 文件中添加测试：

```rust
#[test]
fn exec_commands_clap_style_output() {
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
    assert!(stdout.contains("Commands:"), "should contain header, got: {stdout}");
    assert!(stdout.contains("ping"), "should contain ping command, got: {stdout}");
    assert!(stdout.contains("健康检查"), "should contain summary, got: {stdout}");

    mock.assert();
}

#[test]
fn exec_command_help_clap_style_output() {
    let server = MockServer::start();
    let mock = server.mock(|when, then| {
        when.method(POST)
            .path("/command-help")
            .json_body_obj(&serde_json::json!({"command": "editor/scene/save"}));
        then.status(200)
            .body(r#"{"ok":true,"doc":{"path":"editor/scene/save","summary":"保存场景","params":[{"name":"scene_path","type":"string","required":true,"desc":"场景文件路径"}]}}"#);
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
            "exec",
            "command-help",
            "editor/scene/save",
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .output()
        .unwrap();

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(stdout.contains("保存场景"), "should contain summary, got: {stdout}");
    assert!(stdout.contains("Usage:"), "should contain usage, got: {stdout}");
    assert!(stdout.contains("<scene_path>"), "should contain param, got: {stdout}");

    mock.assert();
}

#[test]
fn exec_commands_json_flag_preserves_raw() {
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
            "commands",
            "--project",
            dir.path().to_str().unwrap(),
        ])
        .output()
        .unwrap();

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success());
    // JSON 模式应该输出原始 JSON，而不是 clap 风格
    assert!(stdout.contains(r#""ok":true"#), "should contain raw JSON, got: {stdout}");
    assert!(!stdout.contains("Commands:"), "should not contain clap header, got: {stdout}");

    mock.assert();
}
```

- [ ] **Step 2: 运行集成测试验证失败**

Run: `cargo test -p gdcli --test exec_integration`
Expected: 新测试失败，因为 exec.rs 还是使用 TOON 格式

- [ ] **Step 3: 修改 exec.rs 中的渲染逻辑**

在 `cli/src/exec.rs` 文件中，找到第 90-102 行的渲染逻辑：

```rust
        Ok(r) => {
            let status = r.status();
            let body = read_body(r)?;
            if json_mode {
                let reordered = format::reorder_ok_json(&body);
                print!("{}", reordered);
            } else {
                let rendered = format::render_exec_body(&body);
                print!("{}", rendered);
                if !rendered.ends_with('\n') {
                    println!();
                }
            }
            Ok(map_status_to_exit(status, false))
        }
```

替换为：

```rust
        Ok(r) => {
            let status = r.status();
            let body = read_body(r)?;
            if json_mode {
                let reordered = format::reorder_ok_json(&body);
                print!("{}", reordered);
            } else {
                let rendered = match command {
                    "commands" => format::clap_style::render_commands(&body),
                    "command-help" => format::clap_style::render_command_help(&body),
                    _ => format::render_exec_body(&body),
                };
                print!("{}", rendered);
                if !rendered.ends_with('\n') {
                    println!();
                }
            }
            Ok(map_status_to_exit(status, false))
        }
```

- [ ] **Step 4: 运行集成测试验证通过**

Run: `cargo test -p gdcli --test exec_integration`
Expected: 所有测试通过

- [ ] **Step 5: Commit**

```bash
git add cli/src/exec.rs cli/tests/exec_integration.rs
git commit -m "feat(exec): integrate clap style rendering for commands and command-help"
```
