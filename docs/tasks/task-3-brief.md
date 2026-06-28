# Task 3: 实现 render_command_help 函数

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
