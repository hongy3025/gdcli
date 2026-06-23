# 改进项批量修复 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 修复阶段 1-5 代码审查中发现的 7 个改进项（2 个 P1 + 3 个建议修改 + 2 个重要）。

**架构：** 每个改进项是一个独立的小任务，修改范围明确，互不依赖。按优先级排序：P1 先行，然后是建议修改，最后是重要项。

**技术栈：** Rust 2021 / GDScript

---

## 改进项清单

| # | 来源 | 优先级 | 内容 | 文件 |
|---|---|---|---|---|
| 1 | 阶段 1 | P1 | 多 Content-Length 不一致时返回 400 | `gdapi/rust/src/http.rs` |
| 2 | 阶段 1 | P1 | read_body limit 改为 16 MiB | `cli/src/exec.rs` |
| 3 | 阶段 2 | 建议修改 | 版本号从 plugin.cfg 读取 | `cli/src/install.rs` |
| 4 | 阶段 2 | 建议修改 | 处理空 PackedStringArray 边界 | `cli/src/install.rs` |
| 5 | 阶段 2 | 建议修改 | 保留原始行尾符 | `cli/src/install.rs` |
| 6 | 阶段 3 | 重要 | unreachable!() → match 穷尽检查 | `cli/src/main.rs` |
| 7 | 阶段 3 | 重要 | 负向测试覆盖更多旧命令 | `cli/tests/lsp_subcommand.rs` |

---

## 任务 1：多 Content-Length 不一致时返回 400

**文件：**
- 修改：`gdapi/rust/src/http.rs:42-54`
- 修改：`gdapi/rust/src/http.rs`（测试）

- [ ] **步骤 1：添加测试**

在 `gdapi/rust/src/http.rs` 的 `tests` 模块末尾添加：

```rust
    #[test]
    fn parse_conflicting_content_length_errors() {
        let buf = b"POST /x HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 3\r\n\r\nabcde";
        let result = parse_request(buf);
        assert!(result.is_err(), "expected error for conflicting Content-Length");
    }

    #[test]
    fn parse_duplicate_content_length_same_value_ok() {
        let mut buf: Vec<u8> = b"POST /x HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\n".to_vec();
        buf.extend_from_slice(b"abc");
        let parsed = parse_request(&buf).unwrap().unwrap();
        assert_eq!(parsed.body, b"abc".to_vec());
    }
```

- [ ] **步骤 2：运行测试验证新测试失败**

运行：`cargo test -p gdapi --lib http::tests::parse_conflicting_content_length_errors`
预期：FAIL（当前行为是取最后一个值，不报错）。

- [ ] **步骤 3：修改解析逻辑**

修改 `gdapi/rust/src/http.rs` 中的 Content-Length 处理（约 48-53 行）：

当前代码：
```rust
        if name_lc == "content-length" {
            content_length = value
                .trim()
                .parse::<usize>()
                .map_err(|_| invalid("invalid Content-Length"))?;
        }
```

改为：
```rust
        if name_lc == "content-length" {
            let new_cl = value
                .trim()
                .parse::<usize>()
                .map_err(|_| invalid("invalid Content-Length"))?;
            if content_length != 0 && new_cl != content_length {
                return Err(invalid("conflicting Content-Length values"));
            }
            content_length = new_cl;
        }
```

- [ ] **步骤 4：运行测试验证全部通过**

运行：`cargo test -p gdapi --lib http::tests`
预期：所有测试通过（包括新增的 2 个）。

- [ ] **步骤 5：Commit**

```bash
git add -A
git commit -m "fix(gdapi): reject requests with conflicting Content-Length headers"
```

---

## 任务 2：read_body limit 改为 16 MiB

**文件：**
- 修改：`cli/src/exec.rs:91-95`

- [ ] **步骤 1：修改 read_body**

当前代码：
```rust
fn read_body(resp: ureq::Response) -> Result<String> {
    let mut s = String::new();
    resp.into_reader().take(64 * 1024 * 1024).read_to_string(&mut s)?;
    Ok(s)
}
```

改为：
```rust
const MAX_RESPONSE_BYTES: u64 = 16 * 1024 * 1024;

fn read_body(resp: ureq::Response) -> Result<String> {
    let mut s = String::new();
    resp.into_reader().take(MAX_RESPONSE_BYTES).read_to_string(&mut s)?;
    Ok(s)
}
```

- [ ] **步骤 2：运行测试验证通过**

运行：`cargo test -p gdcli`
预期：全部通过。

- [ ] **步骤 3：Commit**

```bash
git add -A
git commit -m "fix(cli): align read_body limit to 16 MiB with server body limit"
```

---

## 任务 3：版本号从 plugin.cfg 读取

**文件：**
- 修改：`cli/src/install.rs:65`

- [ ] **步骤 1：修改版本号输出**

当前代码：
```rust
    println!("Installed gdapi 0.2.0 → {}", target.display());
```

改为：
```rust
    let version = read_installed_version(&target).unwrap_or_else(|| "unknown".to_string());
    println!("Installed gdapi {} → {}", version, target.display());
```

- [ ] **步骤 2：运行测试验证通过**

运行：`cargo test -p gdcli`
预期：全部通过。

- [ ] **步骤 3：Commit**

```bash
git add -A
git commit -m "fix(cli): read version from plugin.cfg instead of hardcoding"
```

---

## 任务 4：处理空 PackedStringArray 边界

**文件：**
- 修改：`cli/src/install.rs:109-116`

- [ ] **步骤 1：添加测试**

在 `cli/src/install.rs` 的 `tests` 模块末尾添加：

```rust
    #[test]
    fn enable_plugin_empty_array() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("project.godot"),
            "[editor_plugins]\nenabled=PackedStringArray()\n",
        )
        .unwrap();
        enable_plugin_in_project_godot(dir.path()).unwrap();
        let content = fs::read_to_string(dir.path().join("project.godot")).unwrap();
        assert!(content.contains("res://addons/gdapi/plugin.cfg"));
        // Should not have leading comma
        assert!(!content.contains("(,\""));
    }
```

- [ ] **步骤 2：运行测试验证新测试失败**

运行：`cargo test -p gdcli --lib install::tests::enable_plugin_empty_array`
预期：FAIL（当前会在空数组的 `)` 前插入逗号）。

- [ ] **步骤 3：修改解析逻辑**

修改 `cli/src/install.rs` 中的 enabled 行处理（约 109-116 行）：

当前代码：
```rust
                if line.ends_with(")") {
                    // 在 ) 前插入
                    let insert_pos = line.len() - 1;
                    line.insert_str(insert_pos, &format!(",\"{}\"", plugin_entry));
                } else {
                    // 空 enabled 行
                    *line = format!("enabled=PackedStringArray(\"{}\")", plugin_entry);
                }
```

改为：
```rust
                if line.trim() == "enabled=PackedStringArray()" {
                    // 空数组，直接替换
                    *line = format!("enabled=PackedStringArray(\"{}\")", plugin_entry);
                } else if line.ends_with(")") {
                    // 在 ) 前插入
                    let insert_pos = line.len() - 1;
                    line.insert_str(insert_pos, &format!(",\"{}\"", plugin_entry));
                } else {
                    // 空 enabled 行
                    *line = format!("enabled=PackedStringArray(\"{}\")", plugin_entry);
                }
```

- [ ] **步骤 4：运行测试验证全部通过**

运行：`cargo test -p gdcli --lib install::tests`
预期：所有测试通过。

- [ ] **步骤 5：Commit**

```bash
git add -A
git commit -m "fix(cli): handle empty PackedStringArray in enable_plugin"
```

---

## 任务 5：保留原始行尾符

**文件：**
- 修改：`cli/src/install.rs:89-140`

- [ ] **步骤 1：修改 enable_plugin_in_project_godot**

需要检测原始行尾符并在 join 时保留。修改函数：

```rust
fn enable_plugin_in_project_godot(root: &Path) -> Result<()> {
    let godot_path = root.join("project.godot");
    let content = fs::read_to_string(&godot_path)
        .map_err(|e| anyhow!("cannot read {}: {}", godot_path.display(), e))?;

    let plugin_entry = "res://addons/gdapi/plugin.cfg";

    // 检查是否已启用
    if content.contains(plugin_entry) {
        return Ok(());
    }

    // 检测原始行尾符
    let line_ending = if content.contains("\r\n") { "\r\n" } else { "\n" };

    let new_content = if content.contains("[editor_plugins]") {
        let mut lines: Vec<String> = content.lines().map(String::from).collect();
        let mut found_enabled = false;
        for line in &mut lines {
            if line.starts_with("enabled=") {
                if line.trim() == "enabled=PackedStringArray()" {
                    *line = format!("enabled=PackedStringArray(\"{}\")", plugin_entry);
                } else if line.ends_with(")") {
                    let insert_pos = line.len() - 1;
                    line.insert_str(insert_pos, &format!(",\"{}\"", plugin_entry));
                } else {
                    *line = format!("enabled=PackedStringArray(\"{}\")", plugin_entry);
                }
                found_enabled = true;
                break;
            }
        }
        if !found_enabled {
            let mut new_lines = Vec::new();
            for line in lines {
                new_lines.push(line.clone());
                if line.trim() == "[editor_plugins]" {
                    new_lines.push(format!("enabled=PackedStringArray(\"{}\")", plugin_entry));
                }
            }
            new_lines.join(line_ending)
        } else {
            lines.join(line_ending)
        }
    } else {
        let mut new_content = content.trim_end().to_string();
        new_content.push_str(&format!("{}{}[editor_plugins]{}{}", line_ending, line_ending, line_ending, line_ending));
        new_content.push_str(&format!("enabled=PackedStringArray(\"{}\"){}", plugin_entry, line_ending));
        new_content
    };

    fs::write(&godot_path, new_content)
        .map_err(|e| anyhow!("cannot write {}: {}", godot_path.display(), e))?;
    Ok(())
}
```

- [ ] **步骤 2：添加测试**

在 `cli/src/install.rs` 的 `tests` 模块末尾添加：

```rust
    #[test]
    fn enable_plugin_preserves_crlf() {
        let dir = TempDir::new().unwrap();
        fs::write(
            dir.path().join("project.godot"),
            "config_version=5\r\n\r\n[application]\r\nconfig/name=\"test\"\r\n",
        )
        .unwrap();
        enable_plugin_in_project_godot(dir.path()).unwrap();
        let content = fs::read_to_string(dir.path().join("project.godot")).unwrap();
        assert!(content.contains("\r\n"));
        assert!(content.contains("res://addons/gdapi/plugin.cfg"));
    }
```

- [ ] **步骤 3：运行测试验证全部通过**

运行：`cargo test -p gdcli --lib install::tests`
预期：所有测试通过。

- [ ] **步骤 4：Commit**

```bash
git add -A
git commit -m "fix(cli): preserve original line endings in project.godot"
```

---

## 任务 6：unreachable!() → match 穷尽检查

**文件：**
- 修改：`cli/src/main.rs:470-478`

- [ ] **步骤 1：修改 run() 函数末尾**

当前代码（约 470-478 行）：
```rust
    // 不应该到达这里
    unreachable!()
```

改为直接在 `if let Cmd::Lsp` 块后使用 `match`：

实际上，当前的 `run()` 函数结构是：
1. `if let Cmd::Install { ... }` → return
2. `if let Cmd::Exec { ... }` → exit
3. `if matches!(cli.cmd, Cmd::Status)` → return
4. `if let Cmd::Lsp { ... }` → return
5. `unreachable!()`

更好的方式是将整个分发改为一个 `match`：

```rust
    match cli.cmd {
        Cmd::Install { force, no_enable } => {
            let project_root = project::resolve_project_root(project)
                .map_err(|e| anyhow::anyhow!(e))?;
            install::run(install::InstallArgs {
                project_root,
                force,
                no_enable,
            })?;
        }
        Cmd::Exec { ref command, ref data, timeout } => {
            let project_root = project::resolve_project_root(project)
                .map_err(|e| anyhow::anyhow!(e))?;
            let code = exec::run(&project_root, command, data.as_deref(), timeout)?;
            std::process::exit(code);
        }
        Cmd::Status => {
            let project_root = project::resolve_project_root(project).ok();
            let lsp_port = discover_lsp_port(cli.port, project_root.as_deref());
            return handle_status_command(&cli.host, lsp_port, project, cli.json).await;
        }
        Cmd::Lsp { ref sub } => {
            let project_root = project::resolve_project_root(project).ok();
            let lsp_port = discover_lsp_port(cli.port, project_root.as_deref());

            let client = match GodotLspClient::connect(&cli.host, lsp_port, project).await {
                Ok(c) => c,
                Err(_) => {
                    eprintln!("Failed to connect to Godot LSP at {}:{}", cli.host, lsp_port);
                    eprintln!(
                        "Make sure Godot is running with: godot --editor --headless --lsp-port {} --path /your/project",
                        lsp_port
                    );
                    std::process::exit(1);
                }
            };

            let result: Result<()> = async {
                match sub {
                    LspCmd::Capabilities => {
                        let caps = client.server_capabilities().await;
                        println!("{}", serde_json::to_string_pretty(&caps)?);
                    }
                    LspCmd::Rename { target, new_name } => {
                        handle_rename_command(&client, target, new_name, project, cli.json).await?;
                    }
                    LspCmd::References { target } => {
                        handle_references_command(&client, target, project, cli.json).await?;
                    }
                    LspCmd::Definition { target } => {
                        handle_definition_command(&client, target, project, cli.json).await?;
                    }
                    LspCmd::Declaration { target } => {
                        handle_declaration_command(&client, target, project, cli.json).await?;
                    }
                    LspCmd::Symbols { file } => {
                        handle_symbols_command(&client, file, project, cli.json).await?;
                    }
                    LspCmd::Hover { target } => {
                        handle_hover_command(&client, target, project, cli.json).await?;
                    }
                    LspCmd::NativeSymbol { members, full, class, member } => {
                        handle_native_symbol_command(&client, class, member.as_deref(), *members, *full, cli.json).await?;
                    }
                    LspCmd::Diagnostics { file } => {
                        handle_diagnostics_command(&client, file.as_deref(), project, cli.json).await?;
                    }
                }
                Ok(())
            }
            .await;

            client.disconnect().await;
            return result;
        }
    }

    Ok(())
```

- [ ] **步骤 2：运行测试验证通过**

运行：`cargo test -p gdcli`
预期：全部通过。

- [ ] **步骤 3：Commit**

```bash
git add -A
git commit -m "refactor(cli): replace unreachable!() with exhaustive match"
```

---

## 任务 7：负向测试覆盖更多旧命令

**文件：**
- 修改：`cli/tests/lsp_subcommand.rs`

- [ ] **步骤 1：添加更多负向测试**

在 `cli/tests/lsp_subcommand.rs` 末尾添加：

```rust
#[test]
fn old_top_level_references_fails() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["references", "player.gd:10:5"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("error"));
}

#[test]
fn old_top_level_definition_fails() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["definition", "player.gd:10:5"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("error"));
}

#[test]
fn old_top_level_native_symbol_fails() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["native-symbol", "Node3D"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("error"));
}

#[test]
fn old_top_level_diagnostics_fails() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["diagnostics"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("error"));
}

#[test]
fn lsp_no_subcommand_shows_help() {
    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["lsp"])
        .assert()
        .failure();
}
```

- [ ] **步骤 2：运行测试验证通过**

运行：`cargo test -p gdcli --test lsp_subcommand`
预期：所有测试通过（包括新增的 5 个）。

- [ ] **步骤 3：Commit**

```bash
git add -A
git commit -m "test(cli): add more negative tests for old top-level commands"
```

---

## 阶段完成标准

执行完所有任务后应达到：

1. `cargo test --workspace` 全部通过
2. 多 Content-Length 不一致时返回 400（而非取最后一个）
3. read_body limit 与 server 的 16 MiB 对齐
4. install 输出的版本号从 plugin.cfg 读取
5. 空 PackedStringArray 不会产生前导逗号
6. project.godot 的行尾符被保留
7. run() 函数使用 match 穷尽检查（编译器保证所有变体被处理）
8. 负向测试覆盖 rename/references/definition/native-symbol/diagnostics + lsp 无子命令
