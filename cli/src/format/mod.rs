//! 输出格式化层。
//!
//! 提供 `render_exec_body`，把 gdapi HTTP 响应的 JSON body 渲染为 TOON 字符串。
//! 当 body 不是合法 JSON、或编码失败时，原样透传（zero-copy）。

use std::borrow::Cow;

pub mod normalize;
pub mod toon;

/// 把 HTTP 响应 body 渲染为 TOON 字符串。
///
/// - 若 body 是合法 JSON → 应用 R1/R2/R3/R4 启发式预处理 → TOON 编码
/// - 若 body 不是合法 JSON 或 TOON 编码失败 → 原样透传（`Cow::Borrowed`）
pub fn render_exec_body(body: &str) -> Cow<'_, str> {
    match serde_json::from_str::<serde_json::Value>(body) {
        Ok(value) => {
            let normalized = normalize::normalize(value);
            match toon::encode(&normalized) {
                Ok(s) => Cow::Owned(s),
                Err(_) => Cow::Borrowed(body),
            }
        }
        Err(_) => Cow::Borrowed(body),
    }
}
