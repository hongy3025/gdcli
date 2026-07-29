# M3 移除 CI 验收门槛设计

日期：2026-07-29

## 目标

M3 的正式验收不再要求 CI 中的 M3 E2E 时长或 CI 运行证据。M3 是否完成只由可重复的本地验证矩阵决定。

## 范围

修改当前 M3 remediation 的权威文档：

- `docs/superpowers/specs/2026-07-29-gdcli-m3-runtime-remediation-design.md`
- `docs/superpowers/plans/2026-07-29-gdcli-m3-runtime-remediation.md`
- `docs/handoff/2026-07-29-gdcli-m3-runtime-remediation-handoff.md`
- `docs/reports/2026-07-29-gdcli-m3-runtime-remediation-closure.md`
- `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`

保留本地 warm-build `tests/e2e/m3` ≤60 秒、完整 `tests/e2e/`、route manifest、cleanup、pending 与安全契约的现有要求。

不修改历史 M3/M3.1 报告、非 M3 的通用 CI 描述或 pytest 行为。

## 结果

closure report 将明确：CI 性能并非 M3 验收条件。本地矩阵已通过（M3 122 passed、完整 E2E 232 passed、M3 warm-build 49.01s），因此 roadmap 的 M3 标记更新为 ✅，并链接此 closure report。

## 验证

- 搜索当前 M3 remediation 文档，确认不再将 CI 时长或 CI 运行证据列为 M3 必要条件。
- 重新运行 `tests/e2e/m3 -v --durations=20`，确认本地 ≤60 秒仍满足。
- 运行 `tests/e2e/ -v`，确认完整 E2E 仍通过。
- 运行 `git diff --check` 并确认保护文件未被纳入提交。
