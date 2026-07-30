# M6 高风险能力策略

高风险 route 默认拒绝。项目调用方不能通过请求体开启能力；只有编辑器启动前写入 `res://.godot/gdapi-policy.json` 的策略生效，策略缺失、格式错误、版本未知或字段未知都会 fail closed。每次调用还必须携带 `force:true`。

策略骨架：

```json
{"version":1,"capabilities":{
  "editor_eval":{"enabled":false,"max_source_bytes":16384,"allowed_input_keys":[]},
  "runtime_eval":{"enabled":false,"max_source_bytes":16384,"allowed_input_keys":[]},
  "process":{"enabled":false,"executables":[],"cwd_roots":["res://"],"max_timeout_ms":60000,"max_output_bytes":1048576},
  "network":{"enabled":false,"schemes":["https"],"hosts":[],"ports":[443],"allow_private":false,"max_timeout_ms":30000,"max_response_bytes":4194304},
  "bulk_files":{"enabled":false},"bulk_deploy":{"enabled":false}
}}
```

能力与 route 映射为 `editor_eval → editor/eval`、`runtime_eval → runtime/eval`、`process → process/run`、`network → network/http_request`、`bulk_files → filesystem/batch/{delete,replace,recover}`、`bulk_deploy → export/android/deploy_many`。进程使用 argv 直传，不经过 shell；网络会重新校验每个目标和重定向；表达式只暴露固定输入和 VariantCodec 支持的值；批量文件操作先 dry-run、再以源摘要和 `plan_hash` 应用，删除可从 trash manifest 恢复；多设备部署按排序后的 serial 顺序执行并为每个设备返回终态。

审计记录只保留边界信息，自动脱敏 token、Authorization/Cookie、环境变量、表达式源代码和进程输出。启用能力即向本地项目调用方授予策略配置的范围，应按最小权限配置并在不需要时关闭。

2026-07-30 整改验收确认：
- `network_target_guard.gd` — DNS 解析结果和每次重定向均重新校验 policy，拒绝私有地址目标并支持重定向环检测。
- `deferred_task_registry.gd` — 新增 `"finish"` 回调键（兼容 `"terminal"`），`_task_outcome` 可从委托 state 读取 outcome。
- `bulk_file_service.gd` — 替换先 dry-run 计划、再以源摘要和 `plan_hash` 提交；失败回滚；删除可从 trash manifest 恢复 UID。
- 安全性细节见 `docs/reports/2026-07-30-gdcli-full-capability-roadmap-remediation-closure.md`。
