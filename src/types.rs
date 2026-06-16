use percent_encoding::{percent_decode_str, utf8_percent_encode, AsciiSet, CONTROLS};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Position {
    pub line: u32,
    pub character: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Range {
    pub start: Position,
    pub end: Position,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Location {
    pub uri: String,
    pub range: Range,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TextEdit {
    pub range: Range,
    #[serde(rename = "newText")]
    pub new_text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct WorkspaceEdit {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changes: Option<std::collections::HashMap<String, Vec<TextEdit>>>,
    #[serde(rename = "documentChanges", default, skip_serializing_if = "Option::is_none")]
    pub document_changes: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Diagnostic {
    pub range: Range,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub severity: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<serde_json::Value>,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

/// `encodeURI` 风格保留集：保留 `:`、`/`、`?`、`#`、`[`、`]`、`@`、`!`、`$`、`&`、`'`、`(`、`)`、`*`、`+`、`,`、`;`、`=` 与未保留字符，
/// 编码所有控制字符与中文/空格等非 ASCII 字节。简化为：仅编码 CONTROLS + space + 非 ASCII 字节。
const URI_ENCODE_SET: &AsciiSet = &CONTROLS.add(b' ').add(b'"').add(b'<').add(b'>').add(b'\\').add(b'^').add(b'`').add(b'{').add(b'|').add(b'}');

pub fn file_to_uri(path: &Path) -> String {
    let abs = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|c| c.join(path))
            .unwrap_or_else(|_| path.to_path_buf())
    };
    let s = abs.to_string_lossy().replace('\\', "/");
    let trimmed = s.trim_start_matches('/');
    let encoded = utf8_percent_encode(trimmed, URI_ENCODE_SET).to_string();
    format!("file:///{}", encoded)
}

pub fn uri_to_file(uri: &str) -> String {
    let stripped = uri.strip_prefix("file:///").unwrap_or(uri);
    percent_decode_str(stripped).decode_utf8_lossy().to_string()
}

const SYMBOL_KINDS: [&str; 27] = [
    "Unknown", "File", "Module", "Namespace", "Package", "Class",
    "Method", "Property", "Field", "Constructor", "Enum",
    "Interface", "Function", "Variable", "Constant",
    "String", "Number", "Boolean", "Array", "Object",
    "Key", "Null", "EnumMember", "Struct", "Event",
    "Operator", "TypeParameter",
];

pub fn symbol_kind_name(kind: u32) -> String {
    SYMBOL_KINDS
        .get(kind as usize)
        .map(|s| s.to_string())
        .unwrap_or_else(|| format!("Unknown({})", kind))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn uri_roundtrip_simple() {
        // 注意：file_to_uri 会把相对路径转为绝对，测试时直接拿绝对路径
        let p = if cfg!(windows) {
            PathBuf::from(r"C:\foo\bar.gd")
        } else {
            PathBuf::from("/foo/bar.gd")
        };
        let uri = file_to_uri(&p);
        assert!(uri.starts_with("file:///"));
        let back = uri_to_file(&uri);
        let expected = p.to_string_lossy().replace('\\', "/");
        let expected_trimmed = expected.trim_start_matches('/');
        assert_eq!(back, expected_trimmed);
    }

    #[test]
    fn uri_encodes_space_and_chinese() {
        let p = if cfg!(windows) {
            PathBuf::from(r"C:\游戏 项目\player.gd")
        } else {
            PathBuf::from("/游戏 项目/player.gd")
        };
        let uri = file_to_uri(&p);
        assert!(uri.contains("%20"), "space should be percent-encoded: {}", uri);
        assert!(uri.contains("%E6%B8%B8") || uri.contains("%e6%b8%b8"), "chinese should be encoded: {}", uri);
        let back = uri_to_file(&uri);
        assert!(back.contains("游戏 项目"));
    }

    #[test]
    fn uri_preserves_colon_and_slash() {
        let p = if cfg!(windows) {
            PathBuf::from(r"C:\foo\bar.gd")
        } else {
            PathBuf::from("/foo/bar.gd")
        };
        let uri = file_to_uri(&p);
        if cfg!(windows) {
            assert!(uri.contains("C:/foo/bar.gd"), "colon and slash preserved: {}", uri);
        } else {
            assert!(uri.contains("foo/bar.gd"));
        }
    }

    #[test]
    fn symbol_kind_known() {
        assert_eq!(symbol_kind_name(5), "Class");
        assert_eq!(symbol_kind_name(12), "Function");
        assert_eq!(symbol_kind_name(13), "Variable");
    }

    #[test]
    fn symbol_kind_unknown() {
        assert_eq!(symbol_kind_name(99), "Unknown(99)");
    }
}
