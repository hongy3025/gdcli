//! clap 风格输出渲染模块。
//!
//! 提供 `render_commands` 和 `render_command_help` 函数，
//! 将 gdapi 响应转换为类似 clap 的帮助输出格式。

#[allow(unused_imports)]
use serde_json::Value;
use std::borrow::Cow;

/// 将 commands 响应转换为 clap 风格的子命令列表。
///
/// # Arguments
/// * `body` - JSON 响应体字符串
///
/// # Returns
/// clap 风格的命令列表字符串，如果解析失败则回退到 TOON 格式
pub fn render_commands(body: &str) -> Cow<'_, str> {
    let value: Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => return Cow::Borrowed(body),
    };

    let obj = match value.as_object() {
        Some(o) => o,
        None => return Cow::Borrowed(body),
    };

    let commands = match obj.get("commands").and_then(|v| v.as_array()) {
        Some(c) => c,
        None => return Cow::Borrowed(body),
    };

    if commands.is_empty() {
        return Cow::Owned("Commands:\n".to_string());
    }

    let max_path_len = commands
        .iter()
        .filter_map(|cmd| cmd.as_object())
        .filter_map(|cmd| cmd.get("path").and_then(|p| p.as_str()))
        .map(|p| p.len())
        .max()
        .unwrap_or(0);

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

        let padding = " ".repeat(max_path_len - path.len() + 2);
        output.push_str(&format!("  {}{}{}\n", path, padding, summary));
    }

    Cow::Owned(output)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_commands_normal_list() {
        let body = r#"{"ok":true,"commands":[{"path":"ping","summary":"健康检查","params":[]},{"path":"editor/scene/save","summary":"保存场景","params":["scene_path"]}]}"#;
        let result = render_commands(body);
        assert!(result.contains("Commands:"), "should contain header");
        assert!(result.contains("ping"), "should contain ping command");
        assert!(
            result.contains("editor/scene/save"),
            "should contain editor/scene/save"
        );
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
        assert_eq!(result, body);
    }

    #[test]
    fn render_commands_invalid_json() {
        let body = "not json";
        let result = render_commands(body);
        assert_eq!(result, body);
    }
}
