# 合并审查整改与验证证据

本文件记录 [合并质量评价报告](2026-10-04-merge-readiness-review.md) 中 R01–R09 及第 3、4 节准入条件的整改内容与本地验证证据。报告本身保持评价结论不变，本文件只补充「整改后实际行为与门禁结果」。

- 验证环境：Windows 10.0.26200，Godot 4.7.2-stable（`D:\app\devel\Godot\v4.7.2\godot_console.exe`），本地 GPU 为 AMD Radeon RX 7900 XTX。
- 证据来源：上一轮原始等待样本与预算 JSON 位于 `.pytest-artifacts/remediation/`；本轮复测 JSON 位于 `.pytest-artifacts/`；另有 GDScript 单元套件（`tests/fixtures/e2e_project/tests/`）及 gdapi Rust 测试结果。

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

本轮复测命令：`uv run python scripts/check.py --gate format`、`cargo fmt --all -- --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace -j 1`、`uv run python scripts/check.py --gate file --gate budget`；JSON 产物位于 `.pytest-artifacts/`。

| 门禁 | 结果 |
|---|---|
| format | `cargo fmt --all -- --check` 通过；`gdformat`/`gdlint` 414 个 GDScript 文件通过 |
| clippy | `cargo clippy --workspace --all-targets -- -D warnings` 通过 |
| unit | `cargo test --workspace -j 1` 219 passed（10 套件）；`tests/e2e/test_gate_timing.py` 25 passed |
| file | 626 selected（4 deselected）→ **625 passed、1 skipped**，347.70 秒；`editor_starts=1`、`transport=file`、`editor_mode=headless` |
| engine | 上一轮本地验证 1 passed，25.63 秒；`transport=engine_debugger`、`editor_starts=1`（本轮未复跑） |
| render | 上一轮本地验证 2 passed，21.41 秒；`editor_mode=gui`、`editor_starts=1`（本轮未复跑） |
| budget | parent wall **348.761 秒 / 360 秒**（余量 11.239 秒，约 3.1%）；与本轮 file gate 共用同一会话 |

file 会话成功等待分布（P50/P95/P99/max，秒）：`editor_metadata` 13.0671/13.0671/13.0671/13.0671、`scene_switch` 0.0155/0.0214/0.0247/0.0309、`undo_bridge` 0.0214/0.0292/0.0461/0.2455（99 次）。

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

## 6. 本轮补充整改与最终复测

- 网络重定向相对路径构造修正格式化占位符错误；零字节响应不再向 Godot 的哈希/Base64 API 传空 buffer，仍返回标准空内容 SHA-256 与 Base64。
- 网络目标校验拒绝空 host、非法或越界 port；延期任务失败即使客户端断开、响应无法入队，也完成一次失败审计。真实断连回归使用 RST，保留 half-close 继续收取响应的语义。
- `project/input_map/action/add` 导入 project.godot 中预配置的 deadzone 与按键/鼠标修饰键；E2E 快照跳过 Godot 保存 `project.godot` 时生成的瞬态 `.tmp`。
- CI 上传包含隐藏目录的 gate JSON，并增加 Ubuntu/macOS Rust workspace 测试矩阵。
- 本轮全 file gate：`625 passed, 1 skipped, 4 deselected`；单次编辑器会话 347.70 秒，parent wall 348.761 秒。IPv6 字面地址网络请求在当前 Godot Windows 构建中无法启动而跳过 E2E；同一/扩展 IPv6 origin 规范化由 GDScript 单元测试验证。
- 额外定向验证：GDScript guard/响应审计单元 3 passed；空响应重定向及相对 URI-reference 4 passed；场景取消、InputMap 导入、HTTP/进程断连和生产 30 秒 handler deadline 回归均通过。
- 远端 CI 未运行；engine/render 仍引用第 3 节标注的上一轮本机结果，本轮未复跑。

