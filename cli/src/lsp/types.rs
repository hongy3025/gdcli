//! types.rs — LSP 协议数据类型与工具函数
//!
//! 【这个文件的作用】
//! 定义了 gdcli 与 Godot LSP 服务器通信时使用的基础数据结构，
//! 以及文件路径和 URI 之间的相互转换、符号种类名称映射等工具函数。
//!
//! 【关于 LSP（Language Server Protocol）】
//! LSP 是微软提出的一种标准化协议，让编辑器/IDE 和语言服务器之间
//! 通过 JSON-RPC 通信，实现语法高亮、跳转定义、重命名等功能。
//! 本文件中的结构体直接对应 LSP 规范中定义的消息格式。
//!
//! 【serde 序列化/反序列化】
//! 这些结构体都带有 #[derive(Serialize, Deserialize)]，
//! 意味着它们可以自动转换为 JSON（发给服务器）或从 JSON 转换回来（接收服务器响应）。

// ==================== 导入 ====================

/// percent_encoding 提供 URL 百分号编码/解码功能
/// 用于将文件路径中的中文、空格等特殊字符转换为 URL 安全格式
use percent_encoding::{percent_decode_str, utf8_percent_encode, AsciiSet, CONTROLS};
/// serde 是 Rust 中最流行的序列化框架
/// Serialize：把 Rust 结构体变成 JSON 字符串
/// Deserialize：把 JSON 字符串变回 Rust 结构体
use serde::{Deserialize, Serialize};
/// Path 是 Rust 标准库中跨平台的文件路径抽象
use std::path::Path;

// ==================== LSP 基础数据结构 ====================

/// 【Position — 文本中的位置】
///
/// 在 LSP 协议中，所有位置都用 (行号, 列号) 表示：
///   - line：从 0 开始的行号（第 1 行对应 line=0）
///   - character：从 0 开始的字符偏移（UTF-16 码元单位）
///
/// 【#[derive(...)] 宏说明】
/// Debug：可以用 {:?} 格式打印调试信息
/// Clone：可以调用 .clone() 创建副本
/// Serialize / Deserialize：支持与 JSON 的自动转换
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Position {
    /// 行号，0-based（第 1 行 = 0）
    pub line: u32,
    /// 列号（字符偏移），0-based
    pub character: u32,
}

/// 【Range — 文本范围】
///
/// 表示代码中的一段连续文本，由起始位置和结束位置组成。
/// 例如：第 5 行第 0 列 到 第 5 行第 10 列
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Range {
    /// 范围的起始位置
    pub start: Position,
    /// 范围的结束位置（不包含）
    pub end: Position,
}

/// 【Location — 位置信息】
///
/// LSP 中"跳转定义"、"查找引用"等功能的返回值。
/// 包含一个文件 URI 和一个 Range，告诉客户端目标符号在哪里。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Location {
    /// 文件的 URI（如 "file:///C:/project/player.gd"）
    pub uri: String,
    /// 在该文件中的具体范围
    pub range: Range,
}

/// 【TextEdit — 文本编辑操作】
///
/// 表示对文档的一次修改，LSP 的重命名、代码操作等功能返回此结构。
/// 客户端收到后按照 range 替换为 new_text。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TextEdit {
    /// 要替换的文本范围
    pub range: Range,
    /// 【#[serde(rename = "newText")] 说明】
    /// serde 默认会把 Rust 字段名原样写入 JSON（即 new_text）。
    /// 但 LSP 协议中这个字段叫 "newText"（驼峰命名），
    /// rename 属性告诉 serde：序列化/反序列化时用 "newText" 而不是 "new_text"。
    #[serde(rename = "newText")]
    pub new_text: String,
}

/// 【WorkspaceEdit — 工作区编辑】
///
/// 批量文本编辑的集合，用于重命名等需要修改多个文件的操作。
///
/// 【#[serde(default, skip_serializing_if = "Option::is_none")] 说明】
/// - default：如果 JSON 中没有这个字段，使用默认值（这里是 None）
/// - skip_serializing_if = "Option::is_none"：如果值为 None，序列化时跳过这个字段，
///   不输出 "changes": null，使生成的 JSON 更干净
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct WorkspaceEdit {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    /// 传统格式：键为文件 URI，值为该文件的编辑列表
    pub changes: Option<std::collections::HashMap<String, Vec<TextEdit>>>,
    #[serde(rename = "documentChanges", default, skip_serializing_if = "Option::is_none")]
    /// LSP 3.16+ 格式：支持创建/删除/重命名文档的变更列表
    pub document_changes: Option<serde_json::Value>,
}

/// 【Diagnostic — 诊断信息】
///
/// 编译错误或警告，LSP 服务器通过 publishDiagnostics 通知推送给客户端。
/// Godot LSP 会检查 GDScript 语法并返回这类信息。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Diagnostic {
    /// 问题所在的代码范围
    pub range: Range,
    /// 严重程度：1=Error, 2=Warning, 3=Information, 4=Hint
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub severity: Option<u32>,
    /// 错误代码（如类型检查错误编号）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<serde_json::Value>,
    /// 人类可读的诊断消息
    pub message: String,
    /// 诊断来源（如 "gdscript"）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

// ==================== URI 编码/解码 ====================

/// `encodeURI` 风格的保留字符集。
///
/// 在把文件路径转成 file:// URI 时，需要对特殊字符做百分号编码（%20 等）。
/// 这个常量定义了"哪些字符需要被编码"。
///
/// 【AsciiSet 和 CONTROLS】
/// CONTROLS 是标准库预定义的控制字符集合（ASCII 0x00-0x1F 和 0x7F）。
/// 我们用 .add(b' ') 等方法继续往集合里加需要编码的字符。
/// 最终：空格、引号、尖括号、反斜杠、中文等非 ASCII 字符都会被编码。
const URI_ENCODE_SET: &AsciiSet = &CONTROLS
    .add(b' ')
    .add(b'"')
    .add(b'<')
    .add(b'>')
    .add(b'\\')
    .add(b'^')
    .add(b'`')
    .add(b'{')
    .add(b'|')
    .add(b'}');

/// 将本地文件路径转换为 LSP 使用的 file:/// URI。
///
/// 处理流程：
///   1. 把相对路径转为绝对路径（基于当前工作目录）
///   2. 反斜杠（Windows）替换为正斜杠
///   3. 去掉开头的 /（Windows 路径如 C:/foo 不需要前导斜杠）
///   4. 对特殊字符做百分号编码
///   5. 加上 file:/// 前缀
///
/// 【to_string_lossy() 说明】
/// 路径可能包含非 UTF-8 字符（Windows 的某些旧 API），
/// to_string_lossy() 会尽可能转换，遇到非法序列用 � 替换，不会报错。
pub fn file_to_uri(path: &Path) -> String {
    // 如果不是绝对路径，基于当前目录拼接
    let abs = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|c| c.join(path))
            .unwrap_or_else(|_| path.to_path_buf())
    };
    // Windows 反斜杠替换为正斜杠，统一格式
    let s = abs.to_string_lossy().replace('\\', "/");
    // 去掉开头的 /，避免 file:////C:/foo 这种四斜杠
    let trimmed = s.trim_start_matches('/');
    // 对保留集之外的字符做百分号编码
    let encoded = utf8_percent_encode(trimmed, URI_ENCODE_SET).to_string();
    format!("file:///{}", encoded)
}

/// 将 file:/// URI 转换回本地文件路径字符串。
///
/// 处理流程：
///   1. 去掉 file:/// 前缀
///   2. 对百分号编码的字符做解码（如 %20 → 空格）
///   3. 返回 UTF-8 字符串
///
/// 【percent_decode_str 和 decode_utf8_lossy】
/// percent_decode_str 把 %XX 还原为原始字节；
/// decode_utf8_lossy 再把字节转为 UTF-8 字符串（非法字节用 � 替换）。
pub fn uri_to_file(uri: &str) -> String {
    let stripped = uri.strip_prefix("file:///").unwrap_or(uri);
    percent_decode_str(stripped).decode_utf8_lossy().to_string()
}

// ==================== 符号种类映射 ====================

/// LSP 规范中 SymbolKind 枚举的字符串名称表，索引对应 kind 编号。
///
/// LSP 定义了 27 种符号种类（从 1 开始编号），
/// 例如：1=File, 5=Class, 12=Function, 13=Variable。
/// 这个数组按索引 0~26 存放名称，方便把数字转成人可读的名字。
const SYMBOL_KINDS: [&str; 27] = [
    "Unknown", "File", "Module", "Namespace", "Package", "Class",
    "Method", "Property", "Field", "Constructor", "Enum",
    "Interface", "Function", "Variable", "Constant",
    "String", "Number", "Boolean", "Array", "Object",
    "Key", "Null", "EnumMember", "Struct", "Event",
    "Operator", "TypeParameter",
];

/// 将 LSP SymbolKind 编号转换为人可读的名称。
///
/// 【.get(kind as usize) 说明】
/// 数组的 get 方法返回 Option<&T>：
///   - 如果索引在范围内，返回 Some(&元素)
///   - 如果越界，返回 None
///     这里配合 unwrap_or_else 处理越界情况，返回 "Unknown(编号)"。
pub fn symbol_kind_name(kind: u32) -> String {
    SYMBOL_KINDS
        .get(kind as usize)
        .map(|s| s.to_string())
        .unwrap_or_else(|| format!("Unknown({})", kind))
}

// ==================== 单元测试 ====================

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
        assert!(
            uri.contains("%E6%B8%B8") || uri.contains("%e6%b8%b8"),
            "chinese should be encoded: {}",
            uri
        );
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
            assert!(
                uri.contains("C:/foo/bar.gd"),
                "colon and slash preserved: {}",
                uri
            );
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
