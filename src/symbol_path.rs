//! symbol_path.rs — 符号路径解析器
//!
//! 【这个文件的作用】
//! 提供一种人类友好的方式来指定 Godot/GDScript 源码中的符号（类、变量、函数等）。
//! 符号路径的格式为 `文件路径:符号路径`，例如：
//!   - player.gd:Player.health → player.gd 文件中 Player 类的 health 成员
//!   - player.gd:health        → player.gd 中的 health 符号（简写，省略类名）
//!
//! 【为什么需要这个模块】
//! gdcli 的命令行参数需要让用户指定"要重命名/查找的符号是什么"。
//! 除了传统的 file:line:col 格式外，符号路径更直观，用户不需要知道具体行列号。
//!
//! 【实现要点】
//! 以最后一个 `:` 分割文件路径和符号路径（这样 `res://` 前缀不会误伤）；
//! 符号路径以 `.` 分隔各级符号（如 Class.member.submember）。

// ==================== 导入 ====================

/// PathBuf 是标准库中拥有的（可变的）路径类型，
/// 与 Path（借用/只读）相对。SymbolPath 需要存储文件路径，所以用 PathBuf。
use std::path::PathBuf;

// ==================== SymbolPath 结构体 ====================

/// 【符号路径】
///
/// 把字符串 `文件路径:符号路径` 解析成结构化的数据，方便后续查找和定位。
///
/// 【#[derive(Debug, Clone, PartialEq, Eq)] 说明】
/// Debug：调试打印；Clone：可复制；
/// PartialEq / Eq：支持 == 比较（测试中会大量用到 assert_eq!）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SymbolPath {
    /// 文件路径部分（如 "player.gd" 或 "res://scenes/player.gd"）
    pub file: PathBuf,
    /// 符号路径按 `.` 分割后的各级名称
    /// 例如 "Player.health" → vec!["Player", "health"]
    pub segments: Vec<String>,
}

impl SymbolPath {
    /// 解析符号路径字符串。
    ///
    /// 【算法说明】
    /// 1. 用 rfind(':') 找到最后一个冒号，以此分割文件路径和符号路径。
    ///    为什么用最后一个？因为文件路径里可能包含 `res://` 的冒号。
    /// 2. 检查两侧是否为空。
    /// 3. 用 `.` 分割符号路径得到各级 segment。
    /// 4. 检查是否有空的 segment（如 Player..health 是非法的）。
    ///
    /// 【Result<Self, String> 说明】
    /// Result<T, E> 是 Rust 中处理可能失败的操作的标准方式：
    ///   - Ok(T) 表示成功，携带结果值
    ///   - Err(E) 表示失败，携带错误信息
    /// 这里用 String 作为错误类型，直接返回人类可读的错误描述。
    pub fn parse(input: &str) -> Result<Self, String> {
        let colon_pos = input.rfind(':').ok_or("missing ':' separator")?;
        let file_part = &input[..colon_pos];
        let symbol_part = &input[colon_pos + 1..];

        if file_part.is_empty() {
            return Err("empty file path".into());
        }
        if symbol_part.is_empty() {
            return Err("empty symbol path".into());
        }

        let segments: Vec<String> = symbol_part.split('.').map(String::from).collect();
        if segments.iter().any(|s| s.is_empty()) {
            return Err("empty segment in symbol path".into());
        }

        Ok(SymbolPath {
            file: PathBuf::from(file_part),
            segments,
        })
    }

    /// 判断字符串是否符合符号路径格式（含 `:` 且两侧非空）。
    ///
    /// 这是一个快捷方法，内部直接调用 parse 看是否成功。
    pub fn is_symbol_path(input: &str) -> bool {
        Self::parse(input).is_ok()
    }

    /// 获取类名（第一段符号），仅当 segments 数量大于 1 时返回 Some。
    ///
    /// 例如：
    ///   - player.gd:Player.health → Some("Player")
    ///   - player.gd:health        → None（只有一段，没有类名前缀）
    pub fn class_name(&self) -> Option<&str> {
        if self.segments.len() > 1 {
            Some(&self.segments[0])
        } else {
            None
        }
    }

    /// 获取成员路径（类名之后的部分）。
    ///
    /// 如果没有类名（只有一段），则返回全部 segments。
    /// 例如：
    ///   - a.gd:Foo.bar.baz → &["bar", "baz"]
    ///   - a.gd:foo         → &["foo"]
    pub fn member_path(&self) -> &[String] {
        if self.segments.len() > 1 {
            &self.segments[1..]
        } else {
            &self.segments
        }
    }
}

// ==================== 单元测试 ====================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_basic() {
        let sp = SymbolPath::parse("player.gd:Player.health").unwrap();
        assert_eq!(sp.file, PathBuf::from("player.gd"));
        assert_eq!(sp.segments, vec!["Player", "health"]);
    }

    #[test]
    fn parse_short_form() {
        let sp = SymbolPath::parse("player.gd:health").unwrap();
        assert_eq!(sp.file, PathBuf::from("player.gd"));
        assert_eq!(sp.segments, vec!["health"]);
    }

    #[test]
    fn parse_res_prefix() {
        let sp = SymbolPath::parse("res://scenes/player.gd:Player.health").unwrap();
        assert_eq!(sp.file, PathBuf::from("res://scenes/player.gd"));
        assert_eq!(sp.segments, vec!["Player", "health"]);
    }

    #[test]
    fn parse_deep_path() {
        let sp = SymbolPath::parse("player.gd:Player.stats.health.current").unwrap();
        assert_eq!(sp.segments, vec!["Player", "stats", "health", "current"]);
    }

    #[test]
    fn parse_file_with_extension_in_symbol() {
        // 注意：当文件名中包含点号（如 2d_in_3d.gd）时，
        // 完整写法 2d_in_3d.gd:2d_in_3d.gd.counter 会被解析为
        // segments = ["2d_in_3d", "gd", "counter"]（因为按 . 分割）。
        // 用户遇到这种情况应使用简写：2d_in_3d.gd:counter
        let sp = SymbolPath::parse("2d_in_3d.gd:2d_in_3d.gd.counter").unwrap();
        assert_eq!(sp.file, PathBuf::from("2d_in_3d.gd"));
        assert_eq!(sp.segments, vec!["2d_in_3d", "gd", "counter"]);
    }

    #[test]
    fn parse_no_colon() {
        assert!(SymbolPath::parse("player.gd").is_err());
    }

    #[test]
    fn parse_empty_file() {
        assert!(SymbolPath::parse(":health").is_err());
    }

    #[test]
    fn parse_empty_symbol() {
        assert!(SymbolPath::parse("player.gd:").is_err());
    }

    #[test]
    fn parse_empty_segment() {
        assert!(SymbolPath::parse("player.gd:Player..health").is_err());
    }

    #[test]
    fn is_symbol_path_valid() {
        assert!(SymbolPath::is_symbol_path("player.gd:Player.health"));
        assert!(SymbolPath::is_symbol_path("player.gd:health"));
        assert!(SymbolPath::is_symbol_path("res://a/b.gd:X.y"));
    }

    #[test]
    fn is_symbol_path_invalid() {
        assert!(!SymbolPath::is_symbol_path("player.gd"));
        assert!(!SymbolPath::is_symbol_path(""));
        assert!(!SymbolPath::is_symbol_path(":foo"));
    }

    #[test]
    fn class_name_some() {
        let sp = SymbolPath::parse("a.gd:Foo.bar").unwrap();
        assert_eq!(sp.class_name(), Some("Foo"));
    }

    #[test]
    fn class_name_none_single_segment() {
        let sp = SymbolPath::parse("a.gd:foo").unwrap();
        assert_eq!(sp.class_name(), None);
    }

    #[test]
    fn member_path_with_class() {
        let sp = SymbolPath::parse("a.gd:Foo.bar.baz").unwrap();
        assert_eq!(sp.member_path(), &["bar", "baz"]);
    }

    #[test]
    fn member_path_without_class() {
        let sp = SymbolPath::parse("a.gd:foo").unwrap();
        assert_eq!(sp.member_path(), &["foo"]);
    }
}
