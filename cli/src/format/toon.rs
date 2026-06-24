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
