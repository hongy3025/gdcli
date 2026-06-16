use std::path::PathBuf;

/// 符号路径，格式为 `文件路径:符号路径`
///
/// 示例：
/// - `player.gd:Player.health` — 文件 player.gd 中 Player 类的 health 成员
/// - `player.gd:health` — 文件 player.gd 中的 health 符号（简写）
/// - `res://scenes/player.gd:Player.health` — 带 res:// 前缀
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SymbolPath {
    pub file: PathBuf,
    pub segments: Vec<String>,
}

impl SymbolPath {
    /// 解析符号路径字符串。
    ///
    /// 以最后一个 `:` 分割文件路径和符号路径（兼容 `res://` 前缀）；
    /// 符号路径以 `.` 分隔各级符号。
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
    pub fn is_symbol_path(input: &str) -> bool {
        Self::parse(input).is_ok()
    }

    /// 第一段为类名（可选），无类名时返回 `None`。
    pub fn class_name(&self) -> Option<&str> {
        if self.segments.len() > 1 {
            Some(&self.segments[0])
        } else {
            None
        }
    }

    /// 类名之后的成员路径；若只有一段则返回全部。
    pub fn member_path(&self) -> &[String] {
        if self.segments.len() > 1 {
            &self.segments[1..]
        } else {
            &self.segments
        }
    }
}

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
        // Note: When file name contains dots (like 2d_in_3d.gd), 
        // the full form 2d_in_3d.gd:2d_in_3d.gd.counter will be parsed as
        // segments = ["2d_in_3d", "gd", "counter"] due to dot splitting.
        // Users should use short form: 2d_in_3d.gd:counter
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
