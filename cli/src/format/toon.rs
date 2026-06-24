//! 包装 `toon-format` crate 的薄层。
//!
//! 固定使用 `Delimiter::Pipe` + 2 spaces indent，
//! 这与 docs/superpowers/specs/2026-06-24-exec-toon-output-design.md §3.4 的决策对应。

use serde_json::Value;
use toon_format::{encode as toon_encode, Delimiter, EncodeOptions};

/// 把 `serde_json::Value` 编码为 TOON 字符串。
///
/// 失败时返回 `Err(String)`（错误信息，调用方决定是否透传原 body）。
pub fn encode(value: &Value) -> Result<String, String> {
    let opts = EncodeOptions::new()
        .with_delimiter(Delimiter::Pipe)
        .with_spaces(2);
    toon_encode(value, &opts).map_err(|e| format!("toon encode failed: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn primitive_kv_object() {
        let v = json!({"ok": true, "version": "0.2.0"});
        let s = encode(&v).unwrap();
        assert!(s.contains("ok: true"), "got: {s}");
        assert!(s.contains(r#"version: "0.2.0""#), "got: {s}");
    }

    #[test]
    fn tabular_uniform_array() {
        let v = json!({
            "rows": [
                {"id": 1, "name": "alpha"},
                {"id": 2, "name": "beta"},
            ]
        });
        let s = encode(&v).unwrap();
        assert!(
            s.contains("rows[2|]{id|name}:"),
            "expected pipe-delim tabular header, got: {s}"
        );
        assert!(s.contains("1|alpha"), "got: {s}");
        assert!(s.contains("2|beta"), "got: {s}");
    }

    #[test]
    fn primitive_array_inline() {
        let v = json!({"tags": ["a", "b", "c"]});
        let s = encode(&v).unwrap();
        assert!(
            s.contains("tags[3|]: a|b|c"),
            "expected pipe-delim inline array, got: {s}"
        );
    }

    #[test]
    fn nested_object_indented() {
        let v = json!({"server": {"host": "localhost", "port": 8080}});
        let s = encode(&v).unwrap();
        assert!(s.contains("server:"), "got: {s}");
        assert!(s.contains("  host: localhost"), "got: {s}");
        assert!(s.contains("  port: 8080"), "got: {s}");
    }

    #[test]
    fn empty_object_encodes() {
        let v = json!({});
        let s = encode(&v).unwrap();
        assert_eq!(s, "");
    }

    #[test]
    fn null_value() {
        let v = json!({"x": null});
        let s = encode(&v).unwrap();
        assert!(s.contains("x: null"), "got: {s}");
    }
}
