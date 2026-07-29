# gdcli M3 Runtime Remediation Handoff

日期：2026-07-29
分支：`feat/full-capability`
当前 HEAD：`c7b14ec docs: design M3 runtime remediation`

## 用户目标

用户对现有 M3 完成质量和 E2E 结果非常不满意，要求：

1. 修复全部未达标的 M3 runtime route；
2. 让实现完全对齐 full-capability roadmap 的 M3 目标；
3. 尽最大可能缩短 M3 E2E；
4. 保持 35 条公开 route、protocol v1 和 CLI 行为不变；
5. 保留 EngineDebugger 优先、file transport fallback 的双 transport 边界；
6. 完整验证后才将 roadmap M3 从 🟡 翻为 ✅。

用户已经逐段批准整改方案 B。下一 session 不需要重新讨论方案选择，应直接从详细实施计划
开始。

## 必读文档

按顺序阅读：

1. `AGENTS.md`
2. `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`
3. `docs/reports/2026-07-29-gdcli-m3-acceptance-review.md`
4. `docs/superpowers/specs/2026-07-29-gdcli-m3-runtime-remediation-design.md`
5. `docs/superpowers/plans/2026-07-21-gdcli-m3-runtime-validation.md`
6. `docs/superpowers/plans/2026-07-23-gdcli-m3-closure.md`
7. `docs/superpowers/plans/2026-07-23-gdcli-m3.1-file-transport.md`
8. `docs/superpowers/reports/2026-07-24-gdcli-m3.1-summary.md`
9. `docs/superpowers/reports/2026-07-24-m3.1-failures.md`

验收报告和整改设计已提交：

```text
c7b14ec docs: design M3 runtime remediation
```

## 已完成工作

本 session 完成：

- 读取三份 M3 plan，并提取 10 条 acceptance criteria；
- 检查 route、broker、debugger plugin、runtime probe 和 file transport；
- 本轮重新运行 Rust、GDScript unit 和完整 M3 E2E；
- 记录 M3 当前不能验收的正式报告；
- 与用户确认整改边界和方案 B；
- 完成并提交 M3 remediation design。

本 session 没有修改生产实现或测试实现。

## 本轮验证证据

| 命令 | 结果 |
|---|---|
| `cargo fmt --check` | exit 0 |
| `cargo clippy --workspace` | exit 0；3 条 warning |
| `cargo test --workspace` | 196 passed / 0 failed |
| `git diff --check` | exit 0；用户 fixture 文件有 LF→CRLF 提示 |
| `uv run pytest tests/e2e/test_gdscript_units.py -v` | 10 passed |
| `uv run pytest tests/e2e/m3 -v --timeout=180` | pytest 不认识 `--timeout`；项目未声明 `pytest-timeout` |
| `uv run pytest tests/e2e/m3 -v` | 15 passed / 22 failed，421.26s |
| `uv run pytest tests/e2e/m3/test_runtime_status.py -q --durations=0` | 4 passed，28.89s |

status timing 中 23.67/28.89 秒花在四次函数级 fixture setup。当前 harness 每个测试都：

- `cargo build --workspace`
- copy fixture
- `gdcli install`
- 启动一个 Godot editor
- 等待 metadata/ping
- 多数测试再 run/stop 一次 game

这是 E2E 缓慢的首要原因。

## 当前 M3 验收状态

10 条 acceptance criteria：

- ✅ #1 lifecycle 状态转换；
- ❌ #2 runtime scene tree；
- ❌ #3 runtime node operations；
- ❌ #4 runtime input；
- ❌ #5 capture；
- ❌ #6 log；
- ❌ #7 assert/signal；
- 🟡 #8 debug 部分通过；
- ✅ #9 35 routes + docs；
- ✅ #10 两轮 lifecycle 后 pending 0。

完整 suite：15 passed / 22 failed。

## 已确认根因

### 1. Route 在 editor 进程本地执行

除 `runtime/status` 外，大量 route 直接：

```text
load("res://addons/gdapi/runtime/runtime_*_ops.gd")
```

然后读取 editor 的 `SceneTree.root`。它们没有调用 `GdApiRuntimeBroker.request()`，所以
`/root/RuntimeMain/...` 无法解析到 game 进程。

代表文件：

- `gdapi/addon/routes/runtime/node/info.gd`
- `gdapi/addon/routes/runtime/scene/tree.gd`
- `gdapi/addon/routes/runtime/input/key.gd`
- `gdapi/addon/routes/runtime/log/read.gd`
- `gdapi/addon/routes/runtime/debug/monitors.gd`

### 2. Broker/file pending 所有权断裂

`runtime_broker.gd` 把 callback 存入 broker `_pending`，file sender 只写 inbox。
`runtime_transport_file_editor.gd::_scan_outbox()` 却只检查 transport 自己的 `_pending`。

broker 发出的 reply 会走：

```text
outbox file
  → transport-local pending 不含 id
  → 当作 unknown id 删除
  → 从不调用 broker.receive()
```

现有 unit test 分开测试 broker.request 和 transport.request，没有组合测试。

### 3. Async file handler 未闭环

probe scanner 同步调用 handler，但真正的 runtime handler 对 screenshot、frames、sequence、
assert 和 signal await 使用 `await`。必须先 claim inbox，再用独立协程 await op，完成后写
outbox，并跟踪 inflight id。

### 4. EngineDebugger plugin 没有注册

`gdapi/addon/plugin.gd` 创建并 setup `_runtime_debugger_plugin`，但 commit `9d56487` 删除了：

```text
add_debugger_plugin(_runtime_debugger_plugin)
```

退出时仍调用 `remove_debugger_plugin()`。headless file status 绿灯掩盖了该回归。

### 5. File transport 生命周期不安全

- probe `stop()` 对非空目录直接 `DirAccess.remove_absolute()`；
- E2E 后临时 project 中实际留下 `<probe_id>/hello.json`、`inbox/`、`outbox/`；
- editor manager 不检测 stale probe 消失；
- stale hello 可能在 editor/plugin 重启后造成假 connected；
- file hello 可覆盖 EngineDebugger sender，没有稳定优先级。

### 6. Closure defects 未关闭

- ring buffer dropped 公式错误，empty 分支访问 `_items[0]`；
- ring buffer unit 没有 closure plan 要求的 dropped 断言；
- fixture `emit_known_logs()` 只 print，没有 `record_log()`；
- `test_runtime_reparent.gd` 不存在，E2E 没有 reparent cycle；
- `probe_input_action.gd` 注释称 `_process` polling，实际只有 `_input()`；
- runtime mutation audit/redaction 没有实现或 E2E；
- `runtime/debug/errors` 未被当前 M3 E2E 覆盖。

## 已批准的目标架构

数据流：

```text
gdcli
  → HTTP runtime route
  → GdApiRuntimeRoute.dispatch()
  → GdApiRuntimeBroker.request()
  → EngineDebugger or file sender
  → game RuntimeProbe
  → allowlisted op
  → protocol reply
  → broker.receive()
  → HTTP response exactly once
```

关键决策：

- 新增统一 `gdapi/addon/runtime/runtime_route.gd`；
- `runtime/status` 保持 editor-side；
- 其余 34 条 route 都走 broker；
- broker 独占 ID/pending/deadline/generation；
- transport 只收发，不维护业务 pending；
- transport 优先级固定 `engine_debugger > file > none`；
- 每次 run 清理旧 root，第一条有效 hello 绑定新 generation；
- file outbox 直接 `broker.receive(reply)`；
- async probe op 完成后才写 outbox；
- 成功/拒绝 mutation 均审计并递归 redaction；
- timeout：operation 默认 5s、最大 25s；broker 最大 26s；HTTP/CLI 30s。

完整设计以
`docs/superpowers/specs/2026-07-29-gdcli-m3-runtime-remediation-design.md`
为准，不要从本 handoff 反向简化 design。

## 已批准的 E2E 架构

最终 M3 matrix：

```text
build once
  → copy/install once
  → start one editor
  → lifecycle run/stop × 2
  → start one data-plane game
  → all data-plane tests with fixture reset
  → stop game/editor once
```

门槛：

- editor 启动次数 1；
- game 启动次数最多 3；
- 本地 warm-build M3 E2E ≤60s；
- route 行为仍通过真实 `gdcli --json exec`；
- 不以 direct HTTP、skip、弱化断言或固定 sleep 换速度。

共享 data-plane game 只能在 `runtime/node/call` 和 fixture `reset_fixture()` 验证通过后启用。
在此之前可以先复用 editor，game 仍按测试组重启。

## 下一 session 首要任务

使用 `superpowers:writing-plans`，基于已批准 design 写详细实施计划：

建议路径：

```text
docs/superpowers/plans/2026-07-29-gdcli-m3-runtime-remediation.md
```

计划必须是逐任务、逐文件、逐测试的 TDD 计划，并至少拆为：

1. 基线与 broker/file sync+async 组合 RED tests；
2. broker pending ownership + file reply bridge；
3. async probe inflight；
4. EngineDebugger 注册、优先级和 fallback；
5. generation/stale cleanup；
6. `runtime_route.gd` adapter；
7. `runtime/node/get` 纵向 slice；
8. session editor harness 和 diagnostics；
9. scene/node family；
10. fixture reset + shared data-plane game；
11. input family；
12. capture family；
13. log/debug family；
14. assert/signal family；
15. D2/D3/D4/D7；
16. audit/redaction/bounds/disconnect/exactly-once；
17. 完整 regression、durations、roadmap/closure report。

每个 task 必须包含：

- 精确文件；
- 先失败的测试；
- RED 命令和预期失败；
- 最小实现；
- GREEN 命令；
- `git diff --check`；
- 独立 commit 建议；
- 不满足时的停止条件。

## 首个实施 slice 的推荐测试

在修改 34 条 route 前，先建立组合测试证明：

1. `broker.request()` 经 file sender 写 inbox；
2. probe 同步 op 写 outbox；
3. editor scanner 调用 `broker.receive()`；
4. broker callback 只触发一次；
5. pending 归零；
6. async handler suspend/resume 后同样完成；
7. unknown/duplicate reply 不触发 callback；
8. timeout 与 late reply 不会双完成。

然后只迁移 `runtime/node/get`，跑真实：

```text
gdcli --json exec runtime/node/get \
  --project <m3 fixture> \
  --data '{"node_path":"/root/RuntimeMain/ProbeTarget","property":"spawn_position"}'
```

必须返回 game 进程的 typed Vector2，不能从 editor SceneTree 获取。

## 验收命令

最终必须重新运行：

```text
cargo fmt --check
cargo clippy --workspace
cargo test --workspace
GODOT_BIN=... uv run pytest tests/e2e/test_gdscript_units.py -v
GODOT_BIN=... uv run pytest tests/e2e/m3 -v --durations=20
GODOT_BIN=... uv run pytest tests/e2e/ -v
git diff --check
```

在添加 `pytest-timeout` 后，M3 命令还应带 suite 防挂死 timeout。

只有完整矩阵全绿、10 条 acceptance criteria 全满足、M3 E2E 达到性能门槛，才能更新
roadmap 为 ✅。

## 工作树保护

handoff 创建时，以下改动已存在且不属于本 session：

```text
 M .gitignore
 M tests/fixture_project/project.godot
 M tests/fixtures/m3_project/project.godot
 M tests/fixtures/m3_project/scenes/runtime_main.tscn
?? docs/reports/2026-07-29-gdcli-roadmap-implementation-status.md
?? tests/fixtures/m3_project/addons/
```

不要 reset、checkout、删除或覆盖这些文件。尤其 `tests/fixtures/m3_project/addons/` 可能是
用户为本地 E2E 准备的 addon 副本/链接。实施前先检查 diff，并让新改动避开或明确合并。

本机 Godot：

```text
D:\app\devel\Godot\v4.7.1\godot_console.exe
```

PowerShell：

```text
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
```

## 注意事项

- 所有辅助脚本只能使用 Python，不新增 `.sh` 或 `.ps1`。
- 不要把 editor-process 本地 runtime ops 保留为临时 fallback。
- 不要一次迁移 34 条 route 后才跑 E2E；必须先组合测试和纵向 slice。
- 不要相信旧 closure report 的“结构完成”；以 2026-07-29 验收报告和 fresh test 为准。
- 不要把 file transport 换成 TCP；用户已批准保留当前 transport 边界。
- 不要在完整验证前把 roadmap M3 翻为 ✅。
