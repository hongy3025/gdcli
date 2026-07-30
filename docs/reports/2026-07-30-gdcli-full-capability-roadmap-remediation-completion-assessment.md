# gdcli Full-Capability Roadmap Remediation Completion Assessment

日期：2026-07-30

审计 / 整改基线：

- 审计基线：`8fa22c85ea6001bc6969f995d92a6f7ef51724dc`
- 整改 HEAD：`ed0b469 fix: resolve parse errors and add bulk deploy E2E tests`
- 整改分支：`feat/full-capability`
- 整改计划：`docs/superpowers/plans/2026-07-30-gdcli-full-capability-roadmap-remediation.md`
- 上游审计报告：`docs/reports/2026-07-30-gdcli-full-capability-roadmap-implementation-audit.md`
- Godot：`D:\app\devel\Godot\v4.7.1\godot_console.exe`

## 结论

整改计划完成度 ≈ 70%。M3–M6 的代码能力面已基本成形，但**验收证据链未闭环**：
M3 合同 1 项失败、M5 验收 2 项失败、5 个缺失的 M6 E2E 文件未创建、E2E 时长优化未做、closure 报告与文档收口未做。

`Plan Self-Review / Completion Gate`（"fresh single-command full E2E pass"）**未达成**。

## 按 Task 逐项判定

### Task 1：里程碑合同 + M6 harness — 70%

- ✅ `tests/e2e/route_manifests.py`（35/51/27/8 个 route 集合与断言）
- ✅ `tests/e2e/m6/{__init__,conftest,test_m6_contract,test_bulk_deploy}.py`
- ✅ `tests/fixtures/m6_project/{project.godot,main.tscn,main.gd,tools/{sleep,echo_args,emit_output}.py}`
- ✅ `m3/test_m3_contract.py::test_runtime_manifest_match` 与 `m4/test_m4_contract.py::test_m4_bridge_does_not_add_runtime_routes` 改用 manifest
- ✅ M6 contract 16/16 + bulk_deploy 2/2 通过
- ❌ `tests/e2e/m3/test_m3_contract.py::test_runtime_manifest_has_no_aliases` 仍断言 35 — 实测 FAIL：`36 == 35`
- ❌ `tests/fixtures/m6_project/bulk/{a.txt,b.txt}` 缺失
- ❌ `tests/e2e/m2/test_m2_contract.py`、`m5/test_m5_smoke.py` 未引用 manifest

### Task 2：协议 v2 + runtime eval → probe — 85% 代码 / 0% E2E

- ✅ `runtime_protocol.gd::request_for_version/reply_for_version`、`SUPPORTED_VERSIONS=[1,2]`、`DENIED_OPS`、`validate_message`
- ✅ `runtime_broker.gd::_negotiated_version`、`negotiate()`、`status()`
- ✅ `runtime/eval.gd` 通过 `dispatch_versioned(req, res, "eval", VERSION_V2, ...)`，继承 `runtime_route.gd`
- ✅ probe 端仅在 v2 协商后处理 `eval` op（commit 30362da）
- ✅ 22/22 GDScript unit 通过（含新增 transport 编辑 / broker / protocol / debugger_plugin）
- ❌ `tests/e2e/m6/test_runtime_eval.py` 缺失

### Task 3：eval 标识符 allowlist — 80%

- ✅ `eval_service.gd` 替换为 token 化 + allowlist（`ALLOWED_GLOBALS`、literal、比较/布尔、policy-approved input）
- ✅ 支持 `== != < <= > >= and or not`
- ✅ `_validate_result` 递归拒绝 Object/RID/Callable/Signal/Resource
- ✅ `test_eval_service.gd` 单元通过
- ❌ `tests/e2e/m6/test_eval.py` 缺失

### Task 4：网络 DNS/IP/redirect — 85% 代码 / 0% E2E

- ✅ 新建 `network_target_guard.gd::authorize()`，覆盖 IPv4 RFC1918/CGNAT/link-local、IPv6 ULA/multicast/IPv4-mapped、unspecified
- ✅ `network_service.gd` 保持 `max_redirects=0`，对 301/302/303/307/308 手动解析 Location → 重新 `authorize()`，用 `visited` 防循环
- ✅ Policy `max_redirects` clampi 到 0..5
- ✅ `test_network_target_guard.gd` 单元通过
- ❌ `tests/e2e/m6/test_network_request.py` 缺失

### Task 5：process/network 终态审计 — 80%

- ✅ `deferred_task_registry.gd::{register,tick,cancel_all}`，outcome 形状 `{ok, code, summary}`，task 携带 `terminal` callback 由 registry 终态一次性触发
- ✅ `process_service.gd::tick` 把 outcome 写入 state 才返回 done；不再"注册即成功"
- ✅ `network_service.gd` 同理
- ⚠️ 计划要求 callable 名 `finish`，实现用 `terminal` — 语义等价，命名不同
- ❌ `tests/e2e/m6/test_process_run.py` 缺失

### Task 6：bulk file 全事务 + UID — 90%

- ✅ `bulk_file_service.gd::plan/apply/rollback`，`plan_hash`、stage 与备份、`details.rolled_back=true/failed_path`
- ✅ Delete 主文件 + `.uid` 双备份，manifest 写到 trash
- ✅ Recover 先验目的地再 move，写 `recovered:true`
- ✅ Replace 移除 `regex` 参数
- ❌ `tests/e2e/m6/test_bulk_files.py` 缺失

### Task 7：bulk deploy + M5 验收 — 60%

- ✅ `routes/export/android/deploy_many.gd`、`test_bulk_deploy_service.gd` 单元通过（stale plan / artifact / device 冲突）
- ✅ `tests/e2e/m5/` 新增 5 个文件：`test_project_config_routes`、`test_classdb_routes`、`test_diagnostics_routes`、`test_uid_repair`、`test_export_android`、`test_snapshot_restore`
- ⚠️ 部分通过：classdb、分页、UID 幂等、snapshot restore
- ❌ **M5 实测 8 passed / 2 FAILED**：
  - `test_export_run_returns_matching_artifact_digest`：gdcli 5s 超时，`export/run` 在 headless 不返回（Network Error: timed out reading response）
  - `test_android_routes_are_deterministic_without_real_device`：返回 `'unknown'` 而非 plan 要求的 `'not_supported'`

### Task 8：E2E 时长优化 — 0%（未做）

- ❌ `tests/e2e/m2/conftest.py::m2_editor` 仍是 function-scoped
- ❌ `tests/e2e/m4/conftest.py` 同上
- ❌ `tests/e2e/test_full_suite_budget.py` 缺失
- ❌ 无 autouse `isolated_test_state` / `reset_project_state`
- 实测：M2 = 527s（plan 要求 ≤6 分钟）、M4 = 311s，合计 ≈ 14 分钟 — **未缩短**

### Task 9：closure 报告 + 文档 + 全 E2E — 30%

- ✅ 3 个原 Clippy warning 修复（`io::Error::other`、`PendingMap::is_empty`、clap-style 重写）
- ⚠️ 新增 1 个 `assertions_on_constants` warning（`http.rs:261`）
- ✅ `cargo fmt --check`、`cargo test --workspace` 通过（202 passed）
- ✅ `cargo clippy --workspace` exit 0
- ✅ GDScript unit 22/22
- ✅ M6 contract 16/16、bulk_deploy 2/2
- ⚠️ M3 contract 1 项失败
- ⚠️ M5 验收 2 项失败
- ❌ 尚未完整跑通 `uv run pytest tests/e2e/ -v --durations=30`（外层 timeout 仍触发）
- ❌ `docs/reports/2026-07-30-gdcli-full-capability-roadmap-remediation-closure.md` 缺失
- ❌ `docs/reports/2026-07-29-gdcli-roadmap-implementation-status.md` 未做历史化标记（仍含 M4/M5/M6 ❌ 过期条目）
- ❌ README 未声明"35 M3 runtime routes + post-M3 runtime/eval"
- ❌ spec 中 M6 段落未翻成 ✅
- ❌ `git diff --check` 与 `rg -n 'M4.*未实现|...'` 文档自检未做

## 新鲜实测总览

| 命令 | 结果 | 耗时 |
|---|---|---:|
| `cargo test --workspace` | 202 passed | ~14s |
| `cargo clippy --workspace --all-targets` | exit 0，**1 warning**（`http.rs:261` `assertions_on_constants`） | 2.24s |
| `tests/e2e/test_gdscript_units.py` | 22 passed | 17s |
| `tests/e2e/m6/test_m6_contract.py` | 16 passed | 11s |
| `tests/e2e/m6/test_bulk_deploy.py` | 2 passed | 12s |
| `tests/e2e/m3/test_m3_contract.py` | **3 passed, 1 FAILED** | 16s |
| `tests/e2e/m4/test_m4_contract.py` | 2 passed | 23s |
| `tests/e2e/m5/` | **8 passed, 2 FAILED** | 173s |
| `tests/e2e/m4/` | 31 passed | 311s |
| `tests/e2e/m2/` | 54 passed | 527s |

合计：M2 (527s) + M4 (311s) + M3 (16s) + M5 (173s) + M6 (23s) ≈ 17 分钟 — 仍会撞外层 timeout。

## 完成门差距

| 审计发现 → 计划 task | 完成度 |
|---|---|
| M3/M4 35-vs-36 regression → Task 1 | 部分（m3/m4 已用 manifest；m3 还有一处老断言失败） |
| Missing M6 fixture and contract → Task 1 | 部分（contract + deploy done；fixture 缺 bulk 文件；5 个 M6 专项 E2E 缺失） |
| Runtime eval executes in editor → Task 2 | 代码 ✅ / E2E 缺失 |
| Protocol v2 not negotiated end to end → Task 2 | 代码 ✅ / E2E 缺失 |
| Eval comparison false positives → Task 3 | 代码 ✅ / 单元 ✅ / E2E 缺失 |
| DNS/IP/redirect SSRF → Task 4 | 代码 ✅ / 单元 ✅ / E2E 缺失 |
| Process/network terminal audit → Task 5 | 代码 ✅ / E2E 缺失 |
| Bulk replace partial mutation → Task 6 | 代码 ✅ / E2E 缺失 |
| Delete/recover omits .uid → Task 6 | 代码 ✅ / E2E 缺失 |
| Bulk deploy stale plan → Task 7 | 代码 + 单测 ✅ / E2E 仅 default-deny + doc |
| M5 acceptance shallow → Task 7 | 大幅补强但 2 项失败 |
| M2/M4 E2E duration → Task 8 | **未做** |
| Three Clippy warnings → Task 9 | 3/3 修复，新增 1 项 |
| README/spec/security/status stale → Task 9 | **未做** |
| No fresh single-command closure → Task 9 | **未做**（closure 报告缺失） |

## 优先续作顺序

1. 修 `test_runtime_manifest_has_no_aliases` 断言（Task 1 收尾）
2. 补 5 个缺失 M6 E2E 文件（Tasks 2/3/4/5/6）
3. 修 `export/run` headless 超时 + Android `'unknown'` → `'not_supported'`（Task 7）
4. M2/M4 改 module-scoped + autouse reset（Task 8）
5. 跑全量单次 E2E + 写 closure 报告 + 文档收口（Task 9）
