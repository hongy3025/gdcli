# 合并审查整改与验证证据

本文件记录 [合并质量评价报告](2026-10-04-merge-readiness-review.md) 中 R01–R09 及第 3、4 节准入条件的整改内容与本地验证证据。报告本身保持评价结论不变，本文件只补充「整改后实际行为与门禁结果」。

- 验证环境：Windows 10.0.26200，Godot 4.7.2-stable（`D:\app\devel\Godot\v4.7.2\godot_console.exe`），本地 GPU 为 AMD Radeon RX 7900 XTX。
- 证据来源：`scripts/check.py` 门禁矩阵（原始等待样本与预算 JSON 位于 `.pytest-artifacts/remediation/`）、GDScript 单元套件（`tests/fixtures/e2e_project/tests/`）、gdapi Rust 集成测试。

## 1. R01–R09 整改映射

| 项 | 缺陷 | 修复位置 | 回归验证 |
|---|---|---|---|
| R01 | 跨 origin 重定向泄露认证头 | `network_service.gd`：按 scheme/host/有效 port 判定 origin，跨源永久剥离认证/Cookie 等敏感头（回到原源也不恢复） | `tests/e2e/m6/test_network_request.py::test_redirect_credentials_follow_origin_boundary[same-origin, same-origin-query, cross-port, return-to-origin]` |
| R02 | 受限 eval 在拒绝输入前已执行代码 | `eval_service.gd`：在 Variant 解码/资源加载前递归拒绝 Object/Resource/Callable/Signal/RID/GDScript/PackedScene | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[...]`（14 组参数） |
| R03 | 超时后任务仍产生副作用并审计成功 | `router.gd`/`response.gd`/`process_service.gd`/`deferred_task_registry.gd` + `gdapi/rust`：请求级绝对期限与取消原因协调 HTTP、实际进程与审计；先清理后返回失败 | `tests/e2e/m6/test_process_run.py`（5 例）、`gdapi/rust/tests/server_e2e.rs`、`gdapi/rust/tests/process_runner_test.rs` |
| R04 | 只读目标另存为误报成功 | `scene_editor.gd`：另存前探测可写性，保存后从磁盘重载并比较解码后的 `SceneState`（而非不稳定的 `PackedScene._bundled` 索引），失败恢复路径/dirty 状态与目标字节 | `test_save_as_read_only_failure_preserves_disk_path_and_unsaved_changes`、`test_save_as_invalid_extension_preserves_unsaved_scene_and_target`、`test_scene_current_save_overwrites_existing_without_force[tscn, scn]` |
| R05 | 删除场景漏查 GDScript preload | `scene_editor.gd`：依赖扫描覆盖 `preload`/`load` 的资源路径、相对路径与 UID，且不执行脚本 | `test_scene_delete_rejects_script_preload_without_executing_script[res, relative, uid]`、`test_scene_delete_ignores_preload_text_in_comments_and_strings` |
| R06 | UID 修复绕过受保护路径写入限制 | `uid_repair.gd`：复用统一写权限校验并逐一预检全部计划目标后才写入；广根扫描跳过受保护目录 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_preflights_all_targets_before_writing` |
| R07 | InputMap 失败回滚反而新增绑定 | `project_config.gd`：保存前快照真实 InputMap 事件/deadzone 与 `ProjectSettings` 原值，失败时分别恢复 | `test_input_map_save_failure_restores_exact_action_and_setting[...]`（6 组）、`test_input_map_bind_failure_restores_absent_project_setting` |
| R08 | 资源类型不匹配却报告赋值成功 | `resource_editor.gd`：按属性 `hint`/子类（含自定义脚本继承）校验，赋值后读回确认，失败不提交 UndoRedo | `test_resource_assign_checks_subclass_and_preserves_undo_redo_on_rejection`、`test_resource_assign_custom_script_inheritance_multiple_hints_and_setter_rejection` |
| R09 | 被拒绝 URL 中的密码进入审计 | `audit_log.gd`：`summarize` 对字符串与字典键统一清除 URL userinfo，包括嵌套字段与错误文本 | `tests/fixtures/e2e_project/tests/test_audit_log_redaction.gd`、`test_rejected_url_credentials_are_not_readable_in_audit[...]` |

## 2. 第 3、4 节准入条件

- **§3.3 测试与生产期限偏差**：E2E 不再覆盖 `GDAPI_HANDLER_TIMEOUT_MS`，会话使用生产默认 30 秒；`process/run` 的业务期限还受当前 HTTP 请求剩余期限约束，并新增默认期限下的副作用回归（`test_process_run_default_handler_deadline_prevents_late_side_effect_and_success_audit`）。
- **§4.1 Unix 进程树清理**：`gdapi/rust/src/process_runner.rs` 在 Unix 原子创建独立进程组并终止整组，Windows 保留 Job Object；自然完成、超时、取消、runner 销毁都会清理持有输出管道的后代，输出排空线程可停止且有界。Linux 容器实测：`process_runner_test.rs` 9 passed、`server_e2e.rs` 9 passed。
- **§4.2 远端 CI**：本地门禁已通过（见第 3 节）；远端 CI 运行状态不在本机验证范围，仍需在合并前确认。
- **§4.3 预算余量**：见第 3 节实测值。

## 3. 门禁矩阵（本地实测）

`uv run python scripts/check.py --gate format --gate clippy --gate unit --gate file --gate engine --gate render --gate budget`，产物在 `.pytest-artifacts/remediation/`。

| 门禁 | 结果 |
|---|---|
| format | `cargo fmt --all -- --check` 通过；`gdformat`/`gdlint` 412 个 GDScript 文件通过 |
| clippy | `cargo clippy --workspace --all-targets -- -D warnings` 通过 |
| unit | `cargo test --workspace` 212 passed（10 套件）；`tests/e2e/test_gate_timing.py` 25 passed |
| file | 595 selected（4 deselected）→ **595 passed**，326.75 秒；会话证据 `editor_starts=1`、`transport=file`、`editor_mode=headless` |
| engine | 1 passed，25.63 秒；`transport=engine_debugger`，`editor_starts=1` |
| render | 2 passed，21.41 秒；`editor_mode=gui`（本机真实 OpenGL），`editor_starts=1` |
| budget | parent wall **327.532 秒 / 360 秒**（余量 32.5 秒，约 9%）；`budget.json` 记录 `parent_wall_clock_seconds=327.5323`，子报告为同一次 file 会话的 `file-waits.json` |

file 会话成功等待分布（P50/P95/P99/max，秒）：`editor_metadata` 13.18/13.18/13.18/13.18、`scene_switch` 0.0174/0.0230/0.0252/0.0290、`undo_bridge` 0.0215/0.0285/0.0418/0.2378（99 次）。

## 4. 本轮额外发现并修复

- `gdcli --json` 曾对 TOON 表格行套用有损压缩（`[]` 写成 `""`、单元素数组降级为标量），与 README「原始 minified JSON」承诺不符；现在只把 `ok` 前置。
- `scene/current.edited` 在 `save-as` 之后失效：编辑器内部场景条目的 path 不随另存为更新，未保存标记却按场景索引记录；改为按索引对齐判断。
- `network/http_request` 对 `http://host?query` 这类无路径 URL 直接被 Godot `HTTPRequest` 拒绝；现在补上 `/`。
- `project/input_map/action/remove` 在设置已不存在（例如刚被 `settings/reset` 删除）时误报 `godot_error`；现在跳过无意义的文件写入校验。
- E2E harness：undo/redo 桥改为带 `request_id` 的幂等协议（重投只重发结果）并容忍 Windows rename 竞态；m5 InputMap 用例自建动作后自行清理；编辑器终止改为整棵进程树（`godot_console.exe` 会以子进程启动真正的 `godot.exe`）。

## 5. 明确未覆盖

- 未运行远端 CI（§4.2）。
- Linux/macOS 未运行完整 E2E，仅运行 gdapi Rust 集成测试。
- 真实渲染门禁依赖本机 AMD 7900 XTX + OpenGL；CI 使用 Mesa llvmpipe，两者结果不互相替代。
