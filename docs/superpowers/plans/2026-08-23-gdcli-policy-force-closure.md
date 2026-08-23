# gdcli Policy/Force 收口 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 2026-08-01 policy/force 移除计划的验收记录、文档残留和最终验证状态收口到当前 HEAD。

**Architecture:** 不改变 gdcli 功能代码。修正 README 的用户-facing 表述，更新原计划、SDD 进度和 closure 报告，并用当前仓库可复现的命令记录 Rust、GDScript、E2E 与 milestone route manifest 结果。

**Tech Stack:** Markdown、PowerShell/Python 验证脚本、Cargo、gdformat/gdlint、pytest/uv。

**Spec:** `docs/superpowers/plans/2026-08-01-gdcli-policy-force-removal-and-gap-closure.md`

## Global Constraints

1. 不修改 policy/force 移除后的运行时行为。
2. README 不保留 `.godot/gdapi-policy.json`、`force:true` 等已废弃用户配置关键词。
3. 只将实际执行并成功的验证写入 closure 报告；Android skip 必须保留环境原因。
4. route manifest 只验证其声明的 M3/M4/M5/M6 milestone 路由存在且无 manifest-only 路由，不把未纳入 milestone manifest 的历史 M1/M2 路由误判为缺失。

---

### Task 1: 清理用户文档和计划状态

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/plans/2026-08-01-gdcli-policy-force-removal-and-gap-closure.md`
- Modify: `.superpowers/sdd/progress.md`

- [x] **Step 1:** 删除 README 中已废弃配置名和 force 字段的字面残留，保留“默认可用、受硬上限约束”的说明。
- [x] **Step 2:** 将原计划 Task 1–13 的实际完成项标记为完成，并补充 Task 13 的验证边界。
- [x] **Step 3:** 将 SDD progress 更新为 Task 12、Task 13 complete，并记录当前 HEAD。

### Task 2: 更新 closure 报告

**Files:**
- Modify: `docs/reports/2026-08-01-gdcli-policy-force-removal-and-gap-closure.md`
- Modify: `.superpowers/sdd/task-13-brief.md`
- Create: `.superpowers/sdd/task-13-report.md`

- [x] **Step 1:** 用当前 HEAD、当前测试结果替换过时的 fe42c98 和待填充表述。
- [x] **Step 2:** 明确 Android 的 3 个 skip、预算测试未执行，以及生产 addon lint 与全仓故意坏 fixture lint 的边界。
- [x] **Step 3:** 记录 route manifest 的可复现检查方式和 121 条 milestone route 结果。

### Task 3: 执行最终验证并复查

**Files:**
- No source changes.

- [x] **Step 1:** 执行 `cargo fmt --check`、`cargo clippy --workspace --all-targets -- -D warnings`、`cargo test --workspace`。
- [x] **Step 2:** 执行 GDScript format check、`gdlint`（生产 addon 范围）和 route manifest Python 检查。
- [x] **Step 3:** 执行 `uv run pytest tests/e2e/ -m "not budget" -q`。
- [x] **Step 4:** 检查残留关键词、工作区 diff 和计划复选框，确认无未记录的失败。
