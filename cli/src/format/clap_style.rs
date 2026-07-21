//! clap 风格输出渲染模块。
//!
//! 提供 `render_commands` 和 `render_command_help` 函数，
//! 将 gdapi 响应转换为类似 clap 的帮助输出格式。

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

    let ok = obj.get("ok").and_then(|v| v.as_bool()).unwrap_or(false);
    if !ok {
        return Cow::Borrowed(body);
    }

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
    let value: Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => return Cow::Borrowed(body),
    };

    let obj = match value.as_object() {
        Some(o) => o,
        None => return Cow::Borrowed(body),
    };

    let ok = obj.get("ok").and_then(|v| v.as_bool()).unwrap_or(false);
    if !ok {
        return Cow::Borrowed(body);
    }

    let doc = match obj.get("doc").and_then(|v| v.as_object()) {
        Some(d) => d,
        None => return Cow::Borrowed(body),
    };

    let summary = doc.get("summary").and_then(|s| s.as_str()).unwrap_or("");
    let path = doc.get("path").and_then(|p| p.as_str()).unwrap_or("");
    let params = doc.get("params").and_then(|p| p.as_array());
    let has_params = params.map(|p| !p.is_empty()).unwrap_or(false);

    let mut output = String::new();

    // 第一行：摘要
    output.push_str(summary);
    output.push('\n');

    // Usage 行
    if has_params {
        output.push_str(&format!("\nUsage: gdcli exec {} --data {{DATA}}\n", path));
    } else {
        output.push_str(&format!("\nUsage: gdcli exec {}\n", path));
    }

    // DATA 部分（JSON 格式）
    if let Some(params) = params {
        if !params.is_empty() {
            output.push_str("\nDATA:\n{\n");
            for (i, param) in params.iter().enumerate() {
                let param_obj = match param.as_object() {
                    Some(o) => o,
                    None => continue,
                };

                let name = param_obj.get("name").and_then(|n| n.as_str()).unwrap_or("");
                // 支持 "desc" 和 "description" 两种字段名
                let desc = param_obj
                    .get("desc")
                    .or_else(|| param_obj.get("description"))
                    .and_then(|d| d.as_str())
                    .unwrap_or("");
                let type_name = param_obj.get("type").and_then(|t| t.as_str()).unwrap_or("");
                let required = param_obj
                    .get("required")
                    .and_then(|r| r.as_bool())
                    .unwrap_or(false);

                let required_mark = if required { "required" } else { "optional" };

                // 构建 JSON 行
                let comma = if i < params.len() - 1 { "," } else { "" };
                let type_mark = if !type_name.is_empty() {
                    format!(" {}", type_name)
                } else {
                    String::new()
                };
                // 占位文本：参数名大写，例如 scene_path -> SCENE_PATH
                let placeholder = name.to_uppercase();
                output.push_str(&format!(
                    "  \"{}\": \"{}\"{} // ({}{})  {}\n",
                    name, placeholder, comma, required_mark, type_mark, desc
                ));
            }
            output.push_str("}\n");
        }
    }

    // 详细描述
    if let Some(description) = doc.get("description").and_then(|d| d.as_str()) {
        if !description.is_empty() {
            output.push_str(&format!("\nDescription:\n  {}\n", description));
        }
    }

    // Returns 部分
    match doc.get("returns") {
        Some(Value::String(s)) => {
            if !s.is_empty() {
                output.push_str(&format!("\nReturns:\n  {}\n", s));
            }
        }
        Some(Value::Object(obj)) => {
            let returns_desc = obj
                .get("description")
                .and_then(|d| d.as_str())
                .unwrap_or("");
            if !returns_desc.is_empty() {
                output.push_str(&format!("\nReturns:\n  {}\n", returns_desc));
            }
            if let Some(fields) = obj.get("fields").and_then(|f| f.as_object()) {
                if !fields.is_empty() {
                    output.push_str("\nReturn Fields:\n");
                    for (key, value) in fields {
                        let field_desc = value.as_str().unwrap_or("");
                        output.push_str(&format!("  {:<20} {}\n", key, field_desc));
                    }
                }
            }
        }
        _ => {}
    }

    // Examples 部分
    if let Some(example) = doc.get("example").and_then(|e| e.as_str()) {
        if !example.is_empty() {
            output.push_str(&format!("\nExample:\n  {}\n", example));
        }
    } else if let Some(examples) = doc.get("examples").and_then(|e| e.as_array()) {
        if !examples.is_empty() {
            output.push_str("\nExamples:\n");
            for example in examples {
                if let Some(s) = example.as_str() {
                    output.push_str(&format!("  {}\n", s));
                }
            }
        }
    }

    Cow::Owned(output)
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
    fn render_commands_ok_false_fallback() {
        let body = r#"{"ok":false,"commands":[]}"#;
        let result = render_commands(body);
        assert_eq!(result, body);
    }

    #[test]
    fn render_commands_ok_missing_fallback() {
        let body = r#"{"commands":[{"path":"ping","summary":"test"}]}"#;
        let result = render_commands(body);
        assert_eq!(result, body);
    }

    #[test]
    fn render_command_help_ok_false_fallback() {
        let body = r#"{"ok":false,"doc":{"path":"ping","summary":"test"}}"#;
        let result = render_command_help(body);
        assert_eq!(result, body);
    }

    #[test]
    fn render_command_help_ok_missing_fallback() {
        let body = r#"{"doc":{"path":"ping","summary":"test"}}"#;
        let result = render_command_help(body);
        assert_eq!(result, body);
    }

    #[test]
    fn render_commands_invalid_json() {
        let body = "not json";
        let result = render_commands(body);
        assert_eq!(result, body);
    }

    #[test]
    fn render_command_help_full_doc() {
        let body = r#"{"ok":true,"doc":{"path":"scene/save","summary":"保存场景","params":[{"name":"scene_path","type":"string","required":true,"desc":"场景文件路径"},{"name":"new_path","type":"string","required":false,"desc":"另存为路径"}],"returns":"bool","example":"gdcli exec scene/save --data '{\"scene_path\":\"new.tscn\"}'"}}"#;
        let result = render_command_help(body);
        assert!(result.contains("保存场景"), "should contain summary");
        assert!(result.contains("Usage:"), "should contain usage");
        assert!(
            result.contains("--data {DATA}"),
            "should contain DATA placeholder"
        );
        assert!(result.contains("DATA:"), "should contain DATA section");
        assert!(
            result.contains("\"scene_path\""),
            "should contain param name in JSON"
        );
        assert!(
            result.contains("\"new_path\""),
            "should contain param name in JSON"
        );
        assert!(
            result.contains("(required string)"),
            "should contain required mark and type"
        );
        assert!(
            result.contains("(optional string)"),
            "should contain optional mark and type"
        );
        assert!(
            result.contains("场景文件路径"),
            "should contain param description"
        );
        assert!(
            result.contains("另存为路径"),
            "should contain param description"
        );
        assert!(result.contains("Returns:"), "should contain returns");
        assert!(result.contains("Example:"), "should contain example");
    }

    #[test]
    fn render_command_help_minimal_doc() {
        let body = r#"{"ok":true,"doc":{"path":"ping","summary":"健康检查"}}"#;
        let result = render_command_help(body);
        assert!(result.contains("健康检查"), "should contain summary");
        assert!(result.contains("Usage:"), "should contain usage");
        assert!(!result.contains("DATA:"), "should not contain DATA section");
        assert!(
            !result.contains("--data {DATA}"),
            "should not contain DATA placeholder"
        );
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

    #[test]
    fn render_command_help_gdapi_real_format() {
        // 模拟实际 gdapi 返回的格式
        let body = r#"{
            "ok": true,
            "doc": {
                "path": "editor/uid/update_all",
                "summary": "批量更新项目中所有资源的 UID",
                "description": "扫描指定目录下的场景文件和脚本文件，重新保存以生成或更新 UID；用于解决 UID 缺失或损坏导致的资源引用问题",
                "params": [
                    {
                        "name": "project_path",
                        "type": "String",
                        "required": false,
                        "description": "要扫描的项目子目录路径，默认为 res://",
                        "default": "res://"
                    }
                ],
                "returns": {
                    "description": "处理结果统计",
                    "fields": {
                        "ok": "bool",
                        "scenes_processed": "int, 处理的场景文件数",
                        "scenes_saved": "int, 成功保存的场景数",
                        "scenes_errors": "int, 保存失败的场景数",
                        "scripts_missing_uids": "int, 缺少 UID 的脚本数",
                        "uids_generated": "int, 新生成的 UID 数"
                    }
                },
                "examples": []
            }
        }"#;
        let result = render_command_help(body);
        assert!(
            result.contains("批量更新项目中所有资源的 UID"),
            "should contain summary"
        );
        assert!(result.contains("Usage:"), "should contain usage");
        assert!(
            result.contains("--data {DATA}"),
            "should contain DATA placeholder"
        );
        assert!(result.contains("DATA:"), "should contain DATA section");
        assert!(
            result.contains("\"project_path\""),
            "should contain param name in JSON"
        );
        assert!(
            result.contains("(optional String)"),
            "should contain optional mark and type"
        );
        assert!(
            result.contains("要扫描的项目子目录路径"),
            "should contain param description"
        );
        assert!(
            result.contains("PROJECT_PATH"),
            "should contain placeholder text"
        );
        assert!(result.contains("Returns:"), "should contain returns");
        assert!(
            result.contains("处理结果统计"),
            "should contain returns description"
        );
        assert!(
            result.contains("Return Fields:"),
            "should contain return fields"
        );
        assert!(
            result.contains("scenes_processed"),
            "should contain field name"
        );
        assert!(
            result.contains("Description:"),
            "should contain description section"
        );
        assert!(
            result.contains("扫描指定目录下的场景文件"),
            "should contain description text"
        );
    }

    #[test]
    fn render_command_help_with_examples_array() {
        let body = r#"{
            "ok": true,
            "doc": {
                "path": "scene/save",
                "summary": "保存场景",
                "description": "",
                "params": [],
                "returns": {"description": "", "fields": {}},
                "examples": ["gdcli exec scene/save --data '{\"scene_path\":\"new.tscn\"}'"]
            }
        }"#;
        let result = render_command_help(body);
        assert!(
            result.contains("Examples:"),
            "should contain examples header"
        );
        assert!(
            result.contains("gdcli exec scene/save"),
            "should contain example"
        );
    }

    #[test]
    fn render_command_help_with_description_field() {
        let body = r#"{
            "ok": true,
            "doc": {
                "path": "test",
                "summary": "测试命令",
                "description": "这是详细描述",
                "params": [],
                "returns": {"description": "", "fields": {}},
                "examples": []
            }
        }"#;
        let result = render_command_help(body);
        assert!(
            result.contains("Description:"),
            "should contain description header"
        );
        assert!(
            result.contains("这是详细描述"),
            "should contain description text"
        );
    }
}
