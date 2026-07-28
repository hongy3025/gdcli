# gdcli M3 阶段验收检查总结

日期：2026-07-29
分支：`feat/full-capability`
检查基线：`045d41b docs: M3.1 partial closure — control plane green, data plane E2E analysis`

## 检查范围

- `docs/superpowers/plans/2026-07-21-gdcli-m3-runtime-validation.md`
- `docs/superpowers/plans/2026-07-23-gdcli-m3-closure.md`
- `docs/superpowers/plans/2026-07-23-gdcli-m3.1-file-transport.md`
- M3 runtime route、broker、EngineDebugger transport、file transport、runtime probe
- Rust、GDScript unit、M3 E2E 验证矩阵

本轮仅做检查和取证，没有修改生产代码或测试。工作树在检查前已有 fixture 和
`docs/reports/` 未提交改动，本轮未覆盖这些改动。

## 验收结论

**M3 当前不能验收，里程碑应继续保持 🟡。**

完整 M3 E2E 本轮结果为 **15 passed / 22 failed**。10 条 M3 验收标准中，
第 1、9、10 条通过；第 8 条仅部分通过；第 2–7 条未通过。

当前问题不只是“headless 环境限制”。已确认实现同时存在：

1. runtime HTTP route 绕过 broker，直接在 editor 进程执行 game-side op；
2. broker 与 file transport 的 reply/pending 链路没有接通；
3. EngineDebugger plugin 在 M3.1 提交中被取消注册；
4. closure plan 中 D2、D3、D7 等缺陷仍未真正关闭；
5. file transport probe 目录没有正确清理，会留下可被重新发现的过期 hello。

因此，单纯把 35 个 route 改为 `broker.request()` 仍不足以完成 M3；必须同时修复
file transport 回包桥接、异步 handler、transport 选择和生命周期清理。

## 本轮验证证据

| 命令 | 结果 |
|---|---|
| `cargo fmt --check` | exit 0 |
| `cargo clippy --workspace` | exit 0；3 条 warning |
| `cargo test --workspace` | exit 0；196 passed / 0 failed |
| `git diff --check` | exit 0；仅报告用户工作树的 LF→CRLF 提示 |
| `uv run pytest tests/e2e/test_gdscript_units.py -v` | exit 0；10 passed |
| `uv run pytest tests/e2e/m3 -v --timeout=180` | 无法启动；未安装/声明 `pytest-timeout` |
| `uv run pytest tests/e2e/m3 -v` | exit 1；15 passed / 22 failed，421.26s |

M3 E2E 通过项：

- 35 条 runtime route 精确 manifest；
- route 文档完整性；
- 两轮 run/stop 后 `pending == 0`；
- `runtime/status` 的 stopped/connected/file transport 控制面；
- 部分输入参数拒绝；
- `runtime/node/find`；
- `runtime/debug/performance`、`runtime/debug/breakpoints`。

主要失败形态：

- `/root/RuntimeMain/ProbeTarget` 在 editor SceneTree 中返回 `not_found`；
- `runtime/log/read` 返回 `runtime_probe is not registered`；
- capture、assert、signal、input、node 操作访问不到 game 进程状态；
- 部分异步请求返回 HTTP/network timeout；
- 预期 `invalid_param`、`conflict`、`timeout`、`permission_denied` 的路径被
  `not_found` 或 `unknown` 覆盖。

## 10 条验收标准对照

| # | 验收项 | 状态 | 本轮证据 |
|---|---|---|---|
| 1 | 两轮 `stopped → connecting → connected → stopped` | ✅ | status 与 lifecycle E2E 通过 |
| 2 | scene tree 返回 `RuntimeMain` 和 `ProbeTarget` | ❌ | `test_runtime_tree_root_name` 失败 |
| 3 | node get/set/call/find/info/reparent | ❌ | get/set/call/info 失败；find 通过；reparent cycle 未被 E2E 覆盖 |
| 4 | 五类输入及 sequence 限制 | ❌ | 五类计数器失败；部分参数限制通过 |
| 5 | viewport/camera/frames capture | ❌ | 4/4 capture E2E 失败 |
| 6 | cursor log/read/clear/known logs | ❌ | 3/3 log E2E 失败 |
| 7 | condition/assert/signal await | ❌ | 5/5 E2E 失败 |
| 8 | performance/monitors/errors/breakpoints | 🟡 | performance、breakpoints 通过；monitors 失败；errors 未在当前 E2E 中覆盖 |
| 9 | 精确 35 routes + 完整文档 | ✅ | contract E2E 通过 |
| 10 | 两轮生命周期后 stopped + pending 0 | ✅ | contract E2E 通过 |

## 已确认问题

### P0-1：runtime route 绕过 broker，在 editor 进程本地执行

原始 M3 计划要求所有 public route 调用 `GdApiRuntimeBroker`，由 runtime probe 在
game 进程分派 allowlisted op。当前实现只有 `runtime/status` 使用 broker；其余 route
普遍直接加载 `runtime_node_ops.gd`、`runtime_input_ops.gd` 或
`runtime_capture_ops.gd`。

代表位置：

- `gdapi/addon/routes/runtime/node/info.gd:6-18`
- `gdapi/addon/routes/runtime/scene/tree.gd:12-27`
- `gdapi/addon/routes/runtime/input/key.gd:6-16`
- `gdapi/addon/routes/runtime/log/read.gd:6-22`
- `gdapi/addon/routes/runtime/debug/monitors.gd:8-12`

结果是 route 解析 editor 自己的 `SceneTree.root`，无法按
`/root/RuntimeMain/...` 访问 game 进程节点。这直接解释本轮 22 个 E2E 失败中的大部分。

### P0-2：broker pending 与 file transport outbox 没有桥接

`GdApiRuntimeBroker.request()` 把 callback 存在 broker 自己的 `_pending`，注入的
file sender 只负责写 `inbox/<id>.json`。probe 写回 outbox 后，
`runtime_transport_file_editor.gd::_scan_outbox()` 却只查询 file transport 自己的
`_pending`；该字典只会被它的独立 `request()` 填充。

当请求来自 broker 时，file transport `_pending` 中没有对应 id，于是
`_scan_outbox()` 把合法 reply 当成 unknown id 删除，也没有调用 `broker.receive()`。

代表位置：

- `gdapi/addon/runtime/runtime_broker.gd:171-208`
- `gdapi/addon/runtime/runtime_transport_file_editor.gd:151-169`
- `gdapi/addon/runtime/runtime_transport_file_editor.gd:171-206`

现有 unit test 分别测试 broker 和 file transport 的独立 `request()`，没有覆盖
“broker.request → file sender → probe → outbox → broker.receive”组合链路。

### P0-3：EngineDebugger plugin 实例创建后没有注册

`plugin.gd` 创建并 setup `_runtime_debugger_plugin`，但没有调用
`add_debugger_plugin(_runtime_debugger_plugin)`；退出时却仍调用
`remove_debugger_plugin()`。

该调用在 commit `9d56487` 中被删除。file transport 使 headless status 测试继续通过，
因而掩盖了非 headless EngineDebugger 路径的回归。

代表位置：

- `gdapi/addon/plugin.gd:84-98`
- `gdapi/addon/plugin.gd:129-132`

### P1-1：D2 ring buffer dropped 仍计算错误，测试未锁定

容量 3 的 buffer 写入 4 条后，从 cursor 0 读取应报告至少 1 条被丢弃；当前公式：

```text
_next_cursor - capacity - results.size()
```

会得到 `5 - 3 - 3 = -1`，随后 clamp 为 0。`read()` 还在 `_items.is_empty()` 分支
访问 `_items[0]`。

代表位置：

- `gdapi/addon/runtime/runtime_ring_buffer.gd:62-75`
- `tests/fixture_project/tests/test_runtime_ring_buffer.gd:52-71`

closure plan 要求的两个 dropped 断言没有落地；当前 unit suite 虽然通过，但没有验证 D2。

### P1-2：D3 known logs 没有写入 runtime ring buffer

fixture 的 `emit_known_logs()` 只调用 `print_rich()` 和 `printerr()`，没有调用
`GdApiRuntimeProbe.record_log()`，也没有其它 log relay。即使 route/broker/file
transport 全部修通，`runtime/log/read` 仍无法读到验收要求的 `known-info` 和
`known-error`。

代表位置：

- `tests/fixtures/m3_project/scripts/probe_target.gd:37-39`
- `gdapi/addon/runtime/runtime_probe.gd:285-286`

### P1-3：D7 action counter 不是 closure plan 要求的 polling 实现

`probe_input_action.gd` 的注释称使用 `_process` 轮询，但实际没有 `_process()`；
它只在 `_input(event)` 中调用 `event.is_action_pressed()`。`runtime/input/action`
使用 `Input.action_press()`，不保证产生可被 `_input` 捕获的 `InputEventAction`。

代表位置：

- `tests/fixtures/m3_project/scripts/probe_input_action.gd:10-24`
- `gdapi/addon/runtime/runtime_input_ops.gd:90-100`

当前数据面断裂先于该路径失败，因此需要在 broker/file 链路修复后单独复验。

### P1-4：file probe 停止时没有递归清理目录

probe 目录包含 `hello.json`、`inbox/`、`outbox/`，但 `stop()` 直接对非空目录调用
`DirAccess.remove_absolute(dir)`。本轮 E2E 结束后，绝大多数临时 project 中仍保留
完整的 `<probe_id>/hello.json` 目录。

代表位置：

- `gdapi/addon/runtime/runtime_transport_file_probe.gd:57-78`
- `gdapi/addon/runtime/runtime_transport_file_editor.gd:138-169`

editor manager 没有检测 probe 消失或清理 stale `_probes`。编辑器/插件重启后可能把
过期 hello 当作新 probe，错误地把 status 推到 connected，或把请求发给已退出进程。

### P1-5：双 transport 选择不满足“EngineDebugger 优先”

M3.1 global constraint 要求只在 `EngineDebugger.is_active() == false` 时启用 file
transport。当前 probe 总是启动 file transport；`attach_file_transport()` 总是覆盖
broker `_sender` 和 `_active_transport`。若 EngineDebugger 与 file hello 的到达顺序
变化，最后到达者会抢占 sender，没有稳定优先级。

代表位置：

- `gdapi/addon/runtime/runtime_probe.gd:41-55`
- `gdapi/addon/runtime/runtime_broker.gd:101-111`
- `gdapi/addon/runtime/runtime_broker.gd:130-134`

### P2：验证矩阵和测试覆盖本身不完整

- M3.1 plan 的 `--timeout=180` 命令无法运行，因为项目未声明 `pytest-timeout`；
- `test_runtime_nodes.py` 没有 reparent cycle E2E；
- closure plan 要求的 `test_runtime_reparent.gd` 不存在；
- runtime mutation/input audit 与 secret redaction 没有 M3 测试；
- file transport 单元测试没有覆盖 broker 组合链路和异步 handler；
- `runtime/debug/errors` 未包含在当前 M3 observability E2E。

## 待进一步验证的高风险点

以下问题已有静态代码依据，但尚未用最小复现单独确认：

1. file probe 的 `_dispatch_request()` 同步调用 handler，而实际 handler 对
   screenshot、sequence、assert、signal 使用 `await`；协程挂起时返回值可能不是
   `Dictionary`，异步 reply 可能无法落盘；
2. stale hello 在同一 project 重启 editor 后是否能稳定复现“未运行游戏却 connected”；
3. EngineDebugger 注册恢复后，file/EngineDebugger sender 是否发生竞态切换；
4. route 改为 broker adapter 后，HTTP response 的生命周期与 server handler timeout
   是否足以承载最长 5 秒 runtime callback；
5. mutation audit 缺失是否覆盖所有 set/call/remove/reparent/input accepted/rejected 路径。

## 根因调查顺序

下一步按以下顺序继续，不先修改实现：

1. 用一个同步 op 追踪完整目标数据流：
   `HTTP route → broker.request → file inbox → probe dispatch → outbox → broker.receive → HTTP response`；
2. 建立最小 broker + file transport 组合复现，确认 reply 在 editor `_pending` 分支被删除；
3. 单独复现一个异步 op，确认 file probe handler 的协程返回行为；
4. 在同一 fixture project 重启 editor，验证 stale hello 假连接；
5. 恢复/模拟 EngineDebugger 注册路径，确认 transport 优先级与 sender 切换；
6. 逐项复核 closure D2、D3、D4、D7 和 audit 约束，形成修复前的根因清单。
