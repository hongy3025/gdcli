# gdcli exec clap 风格输出 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `gdcli exec commands` 和 `gdcli exec command-help` 添加 clap 风格的输出格式，提升人类可读性和 AI agent 友好性。

**Architecture:** 创建新的 `clap_style` 模块，包含两个渲染函数，通过命令类型判断选择不同的渲染路径，保持现有 TOON 格式和 JSON 格式的兼容性。

**Tech Stack:** Rust, serde_json, clap 风格输出格式

## Global Constraints

- 保持 `--json` 标志的原始 JSON 输出功能
- 其他 exec 命令保持现有的 TOON 格式输出
- 错误处理逻辑不变
- 不修改 gdapi addon 的响应内容或协议

---

## File Structure

- **Create:** `cli/src/format/clap_style.rs` - 新模块，包含 clap 风格渲染函数
- **Modify:** `cli/src/format/mod.rs` - 添加模块声明
- **Modify:** `cli/src/exec.rs` - 根据命令类型选择渲染函数
- **Test:** `cli/tests/exec_integration.rs` - 添加集成测试

---

### Task 1: 创建 clap_style 模块基础结构

**Files:**
- Create: `cli/src/format/clap_style.rs`
- Modify: `cli/src/format/mod.rs`

**Interfaces:**
- Consumes: `serde_json::Value` (JSON 响应体)
- Produces: `Cow<'_, str>` (渲染后的字符串)

- [ ] **Step 1: 创建 clap_style.rs 文件并添加基础结构**

```rust
//! clap 风格输出渲染模块。
//!
//! 提供 `render_commands` 和 `render_command_help` 函数，
//! 将 gdapi 响应转换为类似 clap 的帮助输出格式。

use std::borrow::Cow;
use serde_json::Value;

/// 将 commands 响应转换为 clap 风格的子命令列表。
///
/// # Arguments
/// * `body` - JSON 响应体字符串
///
/// # Returns
/// clap 风格的命令列表字符串，如果解析失败则回退到 TOON 格式
pub fn render_commands(body: &str) -> Cow<'_, str> {
    // TODO: 实现渲染逻辑
    Cow::Borrowed(body)
}

/// 将 command-help 响应转换为 clap 风格的完整帮助信息。
///
/// # Arguments
/// * `body` - JSON 响应体字符串
///
/// # Returns
/// clap 风格的帮助信息字符串，如果解析失败则回退到 TOON 格式
pub fn render_command_help(body: &str) -> Cow<'_, str> {
    // TODO: 实现渲染逻辑
    Cow::Borrowed(body)
}
```

- [ ] **Step 2: 修改 format/mod.rs 添加模块声明**

在 `cli/src/format/mod.rs` 文件的第 9 行后添加：

```rust
pub mod clap_style;
```

- [ ] **Step 3: 验证模块编译通过**

Run: `cargo build -p gdcli`
Expected: 编译成功，无错误

- [ ] **Step 4: Commit**

```bash
git add cli/src/format/clap_style.rs cli/src/format/mod.rs
git commit -m "feat(format): add clap_style module skeleton"
```

---

### Task 2: 实现 render_commands 函数

**Files:**
- Modify: `cli/src/format/clap_style.rs:15-25`

**Interfaces:**
- Consumes: `serde_json::Value` (JSON 响应体，包含 `commands` 数组)
- Produces: `Cow<'_, str>` (clap 风格的命令列表)

- [ ] **Step 1: 编写 render_commands 的单元测试**

在 `cli/src/format/clap_style.rs` 文件末尾添加测试模块：

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_commands_normal_list() {
        let body = r#"{"ok":true,"commands":[{"path":"ping","summary":"健康检查","params":[]},{"path":"editor/scene/save","summary":"保存场景","params":["scene_path"]}]}"#;
        let result = render_commands(body);
        assert!(result.contains("Commands:"), "should contain header");
        assert!(result.contains("ping"), "should contain ping command");
        assert!(result.contains("editor/scene/save"), "should contain editor/scene/save");
        assert!(result.contains("健康检查"), "should contain summary");
        assert!(result.contains("保存场景"), "should contain summary");
    }

    #[test]
    fn render_commands_empty_list() {
        let body = r#"{"ok":true,"commands":[]}"#;
        let result = render_commands(body);
        assert!(result.contains("Commands:"), "should contain header");
    }

    #[test]
    fn render_commands_missing_commands_field() {
        let body = r#"{"ok":true}"#;
        let result = render_commands(body);
        // 应回退到原始格式
        assert_eq!(result, body);
    }

    #[test]
    fn render_commands_invalid_json() {
        let body = "not json";
        let result = render_commands(body);
        assert_eq!(result, body);
    }
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cargo test -p gdcli --lib format::clap_style::tests`
Expected: 测试失败，因为 render_commands 还是返回原始 body

- [ ] **Step 3: 实现 render_commands 函数**

替换 `cli/src/format/clap_style.rs` 中的 `render_commands` 函数：

```rust
pub fn render_commands(body: &str) -> Cow<'_, str> {
    // 解析 JSON
    let value: Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => return Cow::Borrowed(body),
    };

    // 检查是否为对象且包含 commands 字段
    let obj = match value.as_object() {
        Some(o) => o,
        None => return Cow::Borrowed(body),
    };

    let commands = match obj.get("commands").and_then(|v| v.as_array()) {
        Some(c) => c,
        None => return Cow::Borrowed(body),
    };

    // 如果命令列表为空，只返回标题
    if commands.is_empty() {
        return Cow::Owned("Commands:\n".to_string());
    }

    // 计算最长命令名，用于对齐
    let max_path_len = commands
        .iter()
        .filter_map(|cmd| cmd.as_object())
        .filter_map(|cmd| cmd.get("path").and_then(|p| p.as_str()))
        .map(|p| p.len())
        .max()
        .unwrap_or(0);

    // 构建输出
    let mut output = String::from("Commands:\n");
    for cmd in commands {
        let cmd_obj = match cmd.as_object() {
            Some(o) => o,
            None => continue,
        };

        let path = match cmd_obj.get("path").and_then(|p| p.as_str()) {
            Some(p) => p,
            None => continue,
        };

        let summary = cmd_obj
            .get("summary")
            .and_then(|s| s.as_str())
            .unwrap_or("");

        // 格式化：左对齐命令名，右对齐描述
        let padding = " ".repeat(max_path_len - path.len() + 2);
        output.push_str(&format!("  {}{}{}\n", path, padding, summary));
    }

    Cow::Owned(output)
}
```

- [ ] **Step 4: 运行测试验证通过**

Run: `cargo test -p gdcli --lib format::clap_style::tests`
Expected: 所有测试通过

- [ ] **Step 5: Commit**

```bash
git add cli/src/format/clap_style.rs
git commit -m "feat(format): implement render_commands function"
```

---

### Task 3: 实现 render_command_help 函数

**Files:**
- Modify: `cli/src/format/clap_style.rs:35-45`

**Interfaces:**
- Consumes: `serde_json::Value` (JSON 响应体，包含 `doc` 对象)
- Produces: `Cow<'_, str>` (clap 风格的帮助信息)

- [ ] **Step 1: 编写 render_command_help 的单元测试**

在 `cli/src/format/clap_style.rs` 文件的测试模块中添加：

```rust
#[test]
fn render_command_help_full_doc() {
    let body = r#"{"ok":true,"doc":{"path":"editor/scene/save","summary":"保存场景","params":[{"name":"scene_path","type":"string","required":true,"desc":"场景文件路径"},{"name":"new_path","type":"string","required":false,"desc":"另存为路径"}],"returns":"bool","example":"gdcli exec editor/scene/save --data '{\"scene_path\":\"new.tscn\"}'"}}"#;
    let result = render_command_help(body);
    assert!(result.contains("保存场景"), "should contain summary");
    assert!(result.contains("Usage:"), "should contain usage");
    assert!(result.contains("Arguments:"), "should contain arguments");
    assert!(result.contains("<scene_path>"), "should contain required param");
    assert!(result.contains("[new_path]"), "should contain optional param");
    assert!(result.contains("Returns:"), "should contain returns");
    assert!(result.contains("Example:"), "should contain example");
}

#[test]
fn render_command_help_minimal_doc() {
    let body = r#"{"ok":true,"doc":{"path":"ping","summary":"健康检查"}}"#;
    let result = render_command_help(body);
    assert!(result.contains("健康检查"), "should contain summary");
    assert!(result.contains("Usage:"), "should contain usage");
    assert!(!result.contains("Arguments:"), "should not contain arguments");
    assert!(!result.contains("Returns:"), "should not contain returns");
    assert!(!result.contains("Example:"), "should not contain example");
}

#[test]
fn render_command_help_missing_doc_field() {
    let body = r#"{"ok":true}"#;
    let result = render_command_help(body);
    assert_eq!(result, body);
}

#[test]
fn render_command_help_invalid_json() {
    let body = "not json";
    let result = render_command_help(body);
    assert_eq!(result, body);
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cargo test -p gdcli --lib format::clap_style::tests`
Expected: 新测试失败，因为 render_command_help 还是返回原始 body

- [ ] **Step 3: 实现 render_command_help 函数**

替换 `cli/src/format/clap_style.rs` 中的 `render_command_help` 函数：

```rust
pub fn render_command_help(body: &str) -> Cow<'_, str> {
    // 解析 JSON
    let value: Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => return Cow::Borrowed(body),
    };

    // 检查是否为对象且包含 doc 字段
    let obj = match value.as_object() {
        Some(o) => o,
        None => return Cow::Borrowed(body),
    };

    let doc = match obj.get("doc").and_then(|v| v.as_object()) {
        Some(d) => d,
        None => return Cow::Borrowed(body),
    };

    // 获取基本信息
    let summary = doc
        .get("summary")
        .and_then(|s| s.as_str())
        .unwrap_or("");
    let path = doc
        .get("path")
        .and_then(|p| p.as_str())
        .unwrap_or("");

    // 构建输出
    let mut output = String::new();

    // 第一行：摘要
    output.push_str(summary);
    output.push('\n');

    // Usage 行
    output.push_str(&format!("\nUsage: gdcli exec {} [OPTIONS]\n", path));

    // 参数部分
    if let Some(params) = doc.get("params").and_then(|p| p.as_array()) {
        if !params.is_empty() {
            output.push_str("\nArguments:\n");
            for param in params {
                let param_obj = match param.as_object() {
                    Some(o) => o,
                    None => continue,
                };

                let name = param_obj
                    .get("name")
                    .and_then(|n| n.as_str())
                    .unwrap_or("");
                let desc = param_obj
                    .get("desc")
                    .and_then(|d| d.as_str())
                    .unwrap_or("");
                let required = param_obj
                    .get("required")
                    .and_then(|r| r.as_bool())
                    .unwrap_or(false);

                // 格式化参数
                let param_format = if required {
                    format!("<{}>", name)
                } else {
                    format!("[{}]", name)
                };

                // 计算对齐空格
                let padding = " ".repeat(14usize.saturating_sub(param_format.len()));
                let required_mark = if required { " [required]" } else { "" };

                output.push_str(&format!(
                    "  {}{}{}{}\n",
                    param_format, padding, desc, required_mark
                ));
            }
        }
    }

    // 返回值部分
    if let Some(returns) = doc.get("returns").and_then(|r| r.as_str()) {
        output.push_str(&format!("\nReturns:\n  {}\n", returns));
    }

    // 示例部分
    if let Some(example) = doc.get("example").and_then(|e| e.as_str()) {
        output.push_str(&format!("\nExample:\n  {}\n", example));
    }

    Cow::Owned(output)
}
```

- [ ] **Step 4: 运行测试验证通过**

Run: `cargo test -p gdcli --lib format::clap_style::tests`
Expected: 所有测试通过

- [ ] **Step 5: Commit**

```bash
git add cli/src/format/clap_style.rs
git commit -m "feat(format): implement render_command_help function"
```

---

### Task 4: 集成到 exec 模块

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

---

### Task 5: 验证和文档更新

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: 无
- Produces: 更新后的文档

- [ ] **Step 1: 运行所有测试确保功能正常**

Run: `cargo test --workspace`
Expected: 所有测试通过

- [ ] **Step 2: 运行 lint 和格式检查**

Run: `cargo clippy --workspace && cargo fmt --check`
Expected: 无警告，格式正确

- [ ] **Step 3: 更新 README.md 添加示例**

在 `README.md` 的 "Usage Examples" 部分添加：

```markdown
### Clap-Style Output

The `commands` and `command-help` subcommands now output in a clap-style format for better readability:

```bash
# List all commands in clap-style format
$ gdcli exec commands
Commands:
  ping                  健康检查
  editor/scene/save     保存场景
  shared/godot/version  获取 Godot 版本

# Get command help in clap-style format
$ gdcli exec command-help editor/scene/save
保存场景

Usage: gdcli exec editor/scene/save [OPTIONS]

Arguments:
  <scene_path>   场景文件路径 [required]
  [new_path]     另存为路径

Example:
  gdcli exec editor/scene/save --data '{"scene_path":"new.tscn"}'
```

For raw JSON output, use the `--json` flag:
```bash
$ gdcli --json exec commands
{"ok":true,"commands":[...]}
```
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add clap-style output examples to README"
```

---

## Self-Review

**1. Spec coverage:**
- ✅ `render_commands` 函数实现
- ✅ `render_command_help` 函数实现
- ✅ 集成到 exec 模块
- ✅ 单元测试和集成测试
- ✅ 文档更新
- ✅ 错误处理和回退逻辑

**2. Placeholder scan:**
- ✅ 无 TBD、TODO 或不完整的部分
- ✅ 所有步骤都包含实际代码

**3. Type consistency:**
- ✅ 函数签名和返回类型一致
- ✅ 测试中的断言与实现一致

**Plan complete and saved to `docs/superpowers/plans/2026-06-27-exec-clap-style-output.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
