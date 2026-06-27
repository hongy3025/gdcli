# Task 2: 实现 render_commands 函数

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
