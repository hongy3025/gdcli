//! R1/R2/R3/R4 启发式预处理：在 TOON 编码前调整 `serde_json::Value` 结构，
//! 使更多数据落入紧凑的 tabular 形态。
//!
//! 详见 docs/superpowers/specs/2026-06-24-exec-toon-output-design.md §4。

use serde_json::Value;

/// 递归后序遍历 JSON 值并应用 R1/R2/R3/R4 变换。
pub fn normalize(v: Value) -> Value {
    // 占位：当前直接返回原值。后续任务将填入完整规则。
    v
}
