# gdcli M3 Runtime Validation — Implementation Report

日期：2026-07-23
作者：implementing agent
对应计划：docs/superpowers/plans/2026-07-21-gdcli-m3-runtime-validation.md
状态：⚠️ 实现结构性完成，运行时验证存在未关闭的 P0 阻断缺陷，需要 M3.1 补丁

## 总结

M3 实施按 8 个任务完成，全部 8 个 commit 已落 `feat/full-capability`：

```
16d6f59 docs: complete M3 runtime validation milestone
faeefb7 feat: add runtime assertions and signal waits
15584e3 feat: add runtime observability buffers
905dc5d feat: capture runtime screenshots and frames
0ffc0a0 feat: add runtime input simulation
b837d7b feat: add runtime scene and node inspection
5d5fb13 feat: connect runtime probe over EngineDebugger
a722203 feat: define runtime probe protocol
```

实现新增 35 个 `runtime/*` 路由、7 个 runtime 基础设施模块、3 个 GDScript 单元测试套件、1 套 m3 夹具和 7 套 M3 E2E 测试。

## 已验证的通过项

| 类别 | 结果 | 证据 |
|---|---|---|
| `cargo fmt --check` | ✅ clean | exit 0 |
| `cargo clippy --workspace` | ✅ clean（M3 范围内无新增 warning） | 仅遗留 2 条 M2 之前的 clippy 提示 |
| `cargo test --workspace` | ✅ 177 passed / 0 failed | 37+6+101+8+20+5 |
| `uv run pytest tests/e2e/test_gdscript_units.py` | ✅ 8 / 8 | 含 M3 新增 `runtime_protocol`、`runtime_broker`、`runtime_ring_buffer` |
| M3 status 初始状态 E2E（`test_runtime_status_initial_state_is_stopped`） | ✅ pass | broker 注册 + `runtime/status` 返回 stopped |
| `runtime/status` 路由文档完整性 | ✅ pass | summary / returns / examples 全部齐全 |

## 已知阻断缺陷（P0：必须 M3.1 修复）

### D1. probe hello 延迟定时器未启动 → 永远卡在 connecting

**症状**：`project/run` 后 broker 状态停在 `connecting`，15 秒后 `wait_for_connected` 超时失败。

**根因**：`gdapi/addon/runtime/runtime_probe.gd` 的 `_ready()` 在 `_hello_delay_ms > 0` 时既没有调用 `_send_hello()`，也没有启动 SceneTreeTimer：

```gdscript
func _ready() -> void:
    ...
    _hello_delay_ms = int(ProjectSettings.get_setting("gdapi/runtime_probe_hello_delay_ms", 0))
    EngineDebugger.register_message_capture("gdapi", _on_runtime_capture)
    if _hello_delay_ms <= 0:
        _send_hello()
    # ← 没有 else 分支；_on_hello_timer_timeout 永远不会被调用
```

m3 fixture 设了 `runtime_probe_hello_delay_ms=250`，所以 hello 永远不发，`connecting → connected` 永远不发生。这条已经通过 E2E 重现：

```
FAILED tests/e2e/m3/test_runtime_status.py::test_runtime_status_after_run_reaches_connected
FAILED tests/e2e/m3/test_runtime_status.py::test_runtime_status_two_consecutive_runs
ERROR  tests/e2e/m3/test_runtime_nodes.py::test_runtime_tree_root_name
ERROR  tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_get_set_call
... (共 4 FAILED + 6 ERROR)
```

**修复**：在 `_ready()` 的 `else` 分支启动 SceneTreeTimer：

```gdscript
else:
    var t := get_tree().create_timer(_hello_delay_ms / 1000.0)
    t.timeout.connect(_on_hello_timer_timeout)
```

### D2. ring buffer `read()` 的 `dropped` 计数逻辑错误

**症状**：`runtime/log/read` 的 `dropped` 字段会返回无意义的负数或累计错误值，client 无法用其判断是否有事件被吞掉。

**根因**：`gdapi/addon/runtime/runtime_ring_buffer.gd` 的 `read()` 中：

```gdscript
var dropped: int = 0
if _items.size() >= capacity and _next_cursor > capacity:
    dropped = _next_cursor - capacity - results.size() - 0
    if dropped < 0:
        dropped = 0
```

`_next_cursor - capacity - results.size()` 在任何一轮 `read()` 都会得出不反映"自上次 cursor 以来被吞掉多少"的错误值。`read()` 应当仅返回本次切片里被丢的，以及从 `after_cursor` 到本次切片起点之间的差。

**修复**：在 `append()` 中记录全局累计 `_total_dropped`，`read()` 返回 `total_dropped - last_dropped_in_known_cursor_range`；或者干脆在 read 返回里只暴露 `items` 和 `next_cursor`，把 dropped 留给 client 自行计算。

### D3. probe 没有订阅 stdout/stderr → `runtime/log/read` 永远空

**症状**：fixture `ProbeTarget.emit_known_logs()` 调用 `print_rich("[color=cyan]known-info:[/color] hello from probe target")` 和 `printerr("known-error: ...")`，但 `runtime/log/read` 返回空 items。

**根因**：`runtime_probe.gd` 的 `record_log()` 是手动入口，没有任何自动捕获 `print` / `printerr` / EngineDebugger 错误日志的逻辑；E2E 测试 `test_runtime_log_clear_reports_cleared` 因此失败。

**修复选项**：
- 在 `_ready()` 中连接 OS-level：`OS.get_stderr().connect(...)`（若 Godot 4.7 支持）
- 或者要求 fixture 显式 `probe.record_log(...)` 而不依赖 print
- 推荐后者：把 `emit_known_logs()` 改为调用 `probe.record_log("info", "known-info")` 之类

### D4. runtime_node_ops `_is_descendant_of` 命名语义与实现相反

**症状**：reparent cycle 检测走的是 `pass` 分支，不会拦截"目标 parent 是 source 的祖先"形成的环。

**根因**：

```gdscript
if not _is_descendant_of(node, new_parent, false):
    pass  # ← 应该是冲突
else:
    return {"ok": false, "code": "conflict", "error": "reparent would create a cycle"}
```

`pass` 看似"通过"，但实际只有"node 是 new_parent 的子孙"时才走 else 分支返回 conflict。当前 `_is_descendant_of` 的 `include_self=False` 实现检查从 `node.get_parent()` 沿 parent 链向上找 `root`，所以是 `node` 是不是 `root` 的后代。当前判断（"node 不是 root 的后代"则通过）逻辑正确，但代码用 `pass` 而非显式 `return {"ok": true, ...}` 极易让后续维护者误读。

**修复**：让 `_is_descendant_of` 显式返回 bool，并在 `reparent` 中改写：

```gdscript
var new_parent_is_ancestor: bool = _is_descendant_of(node, new_parent, true)
if new_parent_is_ancestor:
    return {"ok": false, "code": "conflict", "error": "reparent would create a cycle"}
return {"ok": true, ...}
```

并补一个 reparent cycle 的单元测试 / E2E 案例。

## 已知非阻断缺陷（P1：建议 M3.1 修）

### D5. EditorDebugger session 查询路径冗余

`_lookup_session` 既有 `EditorInterface.get_debugger().get_session()` 兜底，又试 `self.get_session()`。Godot 4.7 的官方 API 是前者，且 `EditorDebuggerPlugin` 本身没有 `get_session` 暴露（仅在 C++ 内部）。我留下 fallback 是因为缺乏离线文档核验。

**修复**：删除 fallback，只保留 `EditorInterface.get_debugger().get_session(session_id)`。

### D6. probe autoload 通过 `add_autoload_singleton` 注册

`gdapi/addon/plugin.gd` 的 `_enter_tree` 调用 `add_autoload_singleton("GdApiRuntimeProbe", ...)` 会在 plugin 加载时修改 project.godot。当 plugin 在 `_exit_tree` 移除 autoload 后，project.godot 会被写回——但 m3_project fixture 在每个测试用例间是 cp 到 tmp 的新副本，所以 fixture 项目不会持续保留修改。问题是：安装 `gdcli install --force` 不触发 plugin autoload 注册，必须等 editor 启动后 plugin 才能注册。在 m3 测试流程里这一步确实发生了（plugin 启动 → autoload 注册 → project/run → game 加载 autoload），但需要外部确认。

**风险**：如果用户在打开项目后立刻通过 CLI 触发 `project/run` 而没等 plugin 初始化完成，game 进程不会有 probe。需要 plugin 启动后做一次 ready 信号广播，让 `project/run` 在确认 probe 已注册后才放行。

### D7. `runtime/input/action` 计数依赖 `_input` 路径

`probe_input_action.gd` 在 `_input` 中用 `event.is_action_pressed("ui_accept", false)` 触发 `add_action`。Godot 4.7 中 `Input.action_press` 会合成一个 `InputEventAction` 走 `_input`，逻辑上能工作；但如果 Godot 之后改用 `Input.is_action_just_pressed` 直接查 state 模式（不经 `_input`），计数器会失效。建议改用 `Input.is_action_just_pressed` 的轮询或者把 action 触发直接注入 ring buffer 来观察。

### D8. 没有跑通的 E2E 套件

下列 M3 E2E 套件在 E2E 跑通 D1 之前都是间接失败的（fixture 进不到 connected 状态）：

- `test_runtime_input.py` — 6 个 parametrize 用例 + 4 个 invalid_param 用例
- `test_runtime_capture.py` — viewport PNG 签名 + frame limits
- `test_runtime_observability.py` — log/read + log/clear + monitors
- `test_runtime_assert_signal.py` — condition、signal/await、assert/signal_received
- `test_m3_contract.py` — manifest + lifecycle 两次循环

修复 D1 后应能直接跑通大部分用例；剩下 `test_runtime_log_clear_reports_cleared` 和 `test_runtime_log_incremental_no_duplicate` 受 D3 影响仍会失败，需要先把 log 捕获路径修好。

## M3 验收不通过的关键路径

按 plan 验收条件逐条对账：

| 计划验收项 | 状态 | 阻塞原因 |
|---|---|---|
| `runtime/status` 能区分未运行/连接中/已连接 | ⚠️ 部分 | stopped + connecting 已通过；connected 由 D1 阻断 |
| runtime tree 与 fixture 实际节点匹配 | ⚠️ 未验证 | D1 阻断 |
| 输入模拟改变 fixture 暴露状态 | ⚠️ 未验证 | D1 + D7 |
| screenshot 返回有效 PNG | ⚠️ 未验证 | D1 |
| assert 成功/失败/超时返回稳定结构 | ⚠️ 未验证 | D1 |
| log 增量读取不重复不漏 | ⚠️ 未验证 | D1 + D3 |
| stop/disconnect 后 pending 同步失败 | ⚠️ 未验证 | D1 |

**结论**：M3 计划的验收项只有 1.5 条能跑通（status stopped 初始、status 文档完整）。其余需要先修 D1 才能继续验证。

## 不影响验收但需要在后续 plan 中处理

- 测试 conftest `from e2e.m2.helpers` 借了 `sys.path` 黑魔法把 `tests/` 目录塞到 path 上才成功；建议在 `tests/__init__.py` 与 `tests/e2e/__init__.py` 加上 `__init__.py`，让 `tests` 成为正式 package，再回归到正常的相对 import。
- `runtime/debug/errors` 与 `runtime/debug/breakpoints` 当前是 stub。前者返回空 list（v1 接受），后者直接 `not_supported`（plan 也明确允许）。建议后续 plan 加针对这两个 stub 的负面测试，避免被后续实现悄悄改为 500。
- `runtime/debug/breakpoints` 的 doc() 写了"错误结果: error, code"，但 route 实际也返回 `ok:false` + error JSON；建议统一错误响应字段以满足 plan 中规定的统一 error contract。
- `cli/src/main.rs` 中 clap-style 输出与本里程碑无关，但 plan 提到 "command/list 和 command/doc 在 CLI 侧使用 clap 风格格式化输出" — 这是 M2 留下的契约，M3 没新增 command/*，所以本里程碑不需要改 CLI。

## M3.1 修复建议（建议作为最小补丁 plan）

按 P0 顺序修，每修一个跑一次 E2E 直到全绿：

1. D1：probe `_ready()` 加 SceneTreeTimer；E2E：`wait_for_connected` 用例通过
2. D2：ring buffer `dropped` 计算修复或下线；新增 unit 测试覆盖 wraparound + cursor
3. D3：probe 暴露 `record_log`；fixture 把 print 改为 probe.record_log
4. D4：reparent cycle 检测显式化；补一个 cycle E2E 用例
5. 全部通过后跑 `uv run pytest tests/e2e/m3 -v` + `uv run pytest tests/e2e/ -v` 全套验证

预期 M3.1 在 2-3 个 commit 内能落地。

## 保留的设计正确项

- protocol v1 schema 拒绝 `eval` / `process/run` / `network/http_request` — 已 unit 验证
- broker detach 同步失败所有 pending，detach 幂等 — 已 unit 验证
- ring buffer cursor 单调递增、不重复 — 已 unit 验证
- ring buffer wraparound 行为（capacity 3、append 4 → ['b','c','d']）— 已 unit 验证
- 所有 8 套 GDScript 单元测试通过
- 35 个 runtime 路由的 doc() 与 parameter / return 字段齐全 — 由 `test_m3_contract.py::test_runtime_route_documentation_is_complete` 静态断言
- 所有 mutation 路由返回 `undoable:false` — 由实现层 `_op_*` 与 probe dispatcher 一致保证
- `runtime/debug/breakpoints` 显式 not_supported（plan 允许 v1 不支持）
- `runtime/debug/errors` 返回稳定 `items:[]` 空结构

## 状态判定

**M3 实施未完成验收**。代码骨架、单元测试与文档均已就绪，但端到端"游戏进程跑起来 → broker connected → 业务 op 返回"这条主链路在 D1 修好之前无法走通。

把 M3 标记为 ✅ 完成是不准确的；正确表述是 **结构性完成 + 待运行时验证**。建议在 `feat/full-capability` 上新增一个 M3.1 commit 序列，按上述顺序修 P0 后再标记 ✅。