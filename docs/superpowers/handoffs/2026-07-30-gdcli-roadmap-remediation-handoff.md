# gdcli 全功能路线图整改 Handoff

日期：2026-07-30  
仓库：`D:\AI\godot-ws\gdcli`  
分支：`feat/full-capability`

## 下一 session 必读

1. [审计报告](../../reports/2026-07-30-gdcli-full-capability-roadmap-implementation-audit.md)
2. [整改计划](../plans/2026-07-30-gdcli-full-capability-roadmap-remediation.md)
3. 本 handoff

不要假设当前工作区干净，也不要覆盖现有未提交改动。当前改动尚未提交。

## 当前状态

本 session 只完成了整改计划的部分 P0/P2 工作，路线图不能标记为完成。M5/M6 验收、完整 E2E、异步终态审计和完整事务回滚仍未完成。

### 已完成的改动

- 新增 `tests/e2e/route_manifests.py`，锁定：M3=35、M4=51、M5=27、M6=8；M3/M4 合同不再把整个 `runtime/**` namespace 当作 M3。
- `runtime_protocol.gd` 增加 `request_for_version()`、`reply_for_version()` 和 v2 eval 校验。
- `runtime_broker.gd` 增加 negotiated protocol version、status 字段及版本化 request 支持；保留 v1 fake broker 兼容调用。
- `runtime_route.gd` 增加 `dispatch_versioned()`；`runtime/eval.gd` 改为通过 runtime route dispatch，不再直接在 editor 调用 eval service。
- `runtime_probe.gd` 增加 eval dispatch 和 supported protocol versions 的 hello 字段。
- `eval_service.gd` 从 substring blacklist 改为 identifier allowlist，允许 `==/!=/</<=/>/>=`，拒绝成员访问、未知函数和对象型结果。
- 新增 `network_target_guard.gd`，加入 URL、host/port、解析地址、私网/特殊 IPv4/IPv6/IPv4-mapped IPv6 校验；`network_service.gd` 已接入。
- `capability_policy.gd` 增加 `max_redirects` 字段校验，但 redirect 逐跳处理尚未完成。
- `bulk_file_service.gd` 移除未实现的 regex 参数，并补充 delete/recover 的 `.uid` manifest、`recovered` 标记和重复恢复冲突；replace 仍不是完整 stage/rollback 事务。
- Rust：修复 `io::Error::other`、`PendingMap::is_empty()`、clap formatter 的 Clippy warning。
- 新增/修改 eval 与 protocol 单元测试；M3/M4 合同测试已更新。

## 已验证证据

以下命令在 Godot 4.7.1 环境下通过：

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/test_gdscript_units.py -q
```

结果：20 passed。

```powershell
cargo test --workspace
cargo fmt --check
cargo clippy --workspace
```

结果：Rust tests 全部通过；Clippy 无 warning。

额外验证：

- protocol GDScript test：33 passed。
- broker GDScript test：110 passed。
- route manifest 导入结果：`35 51 27 8`。
- `git diff --check` 通过。
- 最后检查没有残留 Godot/gdcli/pytest 测试进程。

## 当前已知失败/风险

### 1. gdlint 尚未通过

对本次修改过的 `.gd` 文件执行 gdlint 仍报告 10 个问题，主要是既有长函数触发：

- `capability_policy.gd`：`_is_valid_policy`、`_is_valid_capability` 的 max-returns。
- `runtime_broker.gd`：`receive`、`_complete_oversized_reply` 的 max-returns。
- `runtime_probe.gd`：`_on_runtime_capture`、`_dispatch_async` 的 max-returns，以及 property 定义顺序。
- `runtime_route.gd`：`_validate_boundary` 的 max-returns。
- `runtime_transport_file_probe.gd`：class definitions order。
- `tests/fixture_project/tests/test_runtime_protocol.gd`：max-public-methods。

不要通过新增全局 lint 配置禁用这些规则来掩盖问题。应重构函数或拆分测试辅助方法，使默认 `gdlint` 通过。

### 2. runtime protocol v2 仍未端到端协商

builder、broker 字段和 probe hello 已有，但 file/editor transport 的真正版本选择、EngineDebugger hello、v2 reply 全链路仍需补齐。下一步必须增加 protocol v2 negotiation 单测和 `runtime/eval` E2E：

- 未运行游戏时必须 `conflict`。
- 运行游戏后 eval 必须在游戏进程执行。
- v1 不得执行 eval。
- 断开后 pending 必须为 0。

### 3. 网络 redirect 尚未实现

当前仍是 `HTTPRequest.max_redirects = 0`。计划要求选择并实现一种明确语义；建议按计划实现手动 redirect：每一跳解析 `Location`、重新调用 `NetworkTargetGuard.authorize()`、限制 0..5、检测循环，并增加 local HTTP fixture。

### 4. 异步终态 audit 尚未实现

`deferred_task_registry.gd`、`process/run`、`network/http_request` 仍需统一 `{ok, code, summary}` terminal callback，并确保 success/failure/timeout/cancel 只写一次终态 audit。

### 5. bulk replace 仍非完整事务

当前 replace 仍逐文件写入临时文件并立即 rename，没有完整 staging、before/after hash、全量预验证和失败 rollback。必须按计划 Task 6 重做并增加注入失败测试。

### 6. M5/M6 测试与文档尚未补齐

尚未创建计划中要求的 `tests/e2e/m6/` harness、M5 final-state tests、bulk deploy tests、fixture projects；README、安全文档、设计文档、历史状态报告也未同步。

## 下一 session 推荐执行顺序

1. 先运行 `git status --short`，确认不要覆盖本 handoff、审计报告、整改计划及当前代码改动。
2. 先修 gdlint：拆分超长函数和 protocol test，直到修改过的 `.gd` 全部通过。
3. 完成整改计划 Task 2：协议 v2 全链路和 `runtime/eval` E2E。
4. 完成 Task 4：redirect 手动处理及网络 fixture；补 DNS/IP、redirect、response cap、timeout、audit 测试。
5. 完成 Task 5：deferred terminal outcome 与 process/network 终态 audit。
6. 完成 Task 6：bulk replace 全事务、delete/recover 完整 rollback 和 staging 清理。
7. 完成 Task 7：bulk deploy stale-plan/device snapshot、M5 final-state coverage。
8. 再做 Task 8 的 E2E fixture 复用优化；不要为了缩短时间牺牲隔离性。
9. 最后做 Task 9：更新 README/security/spec/status/closure report，并按计划顺序运行全部验证。

## 重要命令门禁

任何修改 `.gd` 后，在 unit/E2E 前必须执行：

```powershell
if (-not (Get-Command gdformat -ErrorAction SilentlyContinue) -or
    -not (Get-Command gdlint -ErrorAction SilentlyContinue)) { uv tool install gdtoolkit }
python scripts/format-gd.py
python scripts/format-gd.py --check
$gdFiles = @(git diff --name-only --diff-filter=ACMR | Where-Object { $_ -like '*.gd' })
if ($gdFiles.Count -gt 0) { gdlint $gdFiles }
```

然后再运行：

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
cargo fmt --check
cargo clippy --workspace
cargo test --workspace
uv run pytest tests/e2e/test_gdscript_units.py -v
```

只有计划 Task 9 的单命令 `uv run pytest tests/e2e/ -v` 新鲜通过后，才能把路线图标记为 complete。
