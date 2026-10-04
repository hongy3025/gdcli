# TODO: 目标收口（Android 除外）

**当前 backlog 已由 [目标收口计划](../superpowers/plans/2026-10-03-gdcli-goal-closure.md) 接管；执行结果见 [收口报告](../reports/2026-10-03-gdcli-goal-closure.md)。**

**遗留问题（待开专题）见 [2026-10-03 遗留问题清单](2026-10-03-open-issues.md)**（T1–T8：1 项未定位的稳定性问题 + 能力域差距 + 行为边界 + 环境事项）。

本文件只保留指向与范围说明，不再单独维护任务清单，避免与计划、closure 报告出现互相矛盾的状态。

## 适用范围

- 分支范围以 [分支总目标与范围（Android 除外）](../superpowers/specs/2026-10-03-gdcli-branch-goal-and-scope.md) 为准。
- **Android 平台能力已移出目标**：设备查询、打包、部署、ADB 集成不要求、不验收；以 Android 环境为由的 `pytest.mark.skip` 必须在收口计划 Task 1–2 中移除。
- `capability_policy` / `force:true` 门禁已于 2026-08-01 取消，不再恢复；相关历史条目（policy 恢复测试、overlay fixture）已作废。

## 已作废的历史条目

| 旧条目 | 结论 |
|---|---|
| Export/run handler timeout 需要验证并解 skip | 已由收口计划 Task 2 接管；根因已定位：fixture 预设平台名非法（`Windows`），且旧模块整体 skip 掩盖了桌面导出用例 |
| `exec_error` 不支持 `extra_args` | 已修复，条目作废 |
| `test_edit_action.py` 仍需迁移到共享 editor | 已迁移，条目作废 |
| Policy restoration tests / M6 policy overlay fixtures | 需求已取消，条目作废 |
| GDScript format/lint 与全量 E2E「尚未执行」 | 属历史状态；后续验证要求见收口计划 Task 14 |
