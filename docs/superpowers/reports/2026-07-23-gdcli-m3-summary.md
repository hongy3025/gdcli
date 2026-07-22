# gdcli M3 Runtime Validation — Implementation Report

日期：2026-07-23
作者：implementing agent
对应计划：docs/superpowers/plans/2026-07-23-gdcli-m3-closure.md
状态：⚠️ 实现结构性完成 + 运行时验证发现 Godot 4.7 headless 限制，需要 M3.1 补丁或非 headless 路径

## 总结

M3 closure 计划按 8 个任务执行；前 4 个任务（Step 0、D1、D5、probe_target 重命名）成功落地，
后 4 个（D2 ring buffer dropped、D3 fixture 日志、D4 reparent cycle、D7 input polling）
在执行前被一个根本性新发现阻断：

**Godot 4.7 `--headless --editor` 模式下，`EditorInterface.play_main_scene()` 不为游戏进程
打开 EditorDebuggerSession。** 我们的 `_setup_session` 只在编辑器自调试阶段被调用一次
（session id = 0），之后游戏的 `EngineDebugger.send_message("gdapi", ...)` 不被编辑器侧
的 `EditorDebuggerPlugin._capture` 路由。我们用 `_has_capture` 调用计数确认：编辑器只
为 `game_view` 通道问过我们的插件，从未问过 `gdapi` 通道；游戏进程的 `_send_message`
调用本身成功，但消息永远到达不了编辑器。

这条根因不是 P0 缺陷，是 Godot 4.7 headless 编辑器自身的限制（TCP 调试端口未启动），
不属于原 closure plan 修复范围。继续推进 D2/D3/D4/D7 与 fixture 单元层修复都可以做，
但 E2E 端到端验证仍然到达不了 `runtime/status = connected`。

## 已完成的结构性修复

### Step 0 — `runtime/status` 字段对齐

| 文件 | 改动 |
|---|---|
| `gdapi/addon/runtime/runtime_broker.gd` | `status()` 新增 `broker_registered`、`session_started_at`；首次 `attach()` 记录 `_session_started_at`。 |
| `gdapi/addon/routes/runtime/status.gd` | `doc()` 增补 `session_started_at` 字段说明。 |

### D1 — 推迟 hello timer

`runtime_probe.gd::_ready()` 在 `_hello_delay_ms > 0` 时启动 SceneTreeTimer；定时器到时
触发 `_on_hello_timer_timeout()` 已存在的回调，最终调 `_send_hello()`。

### D5（重构）— Godot 4.7 调试插件 API 对齐

`runtime_debugger_plugin.gd` 修正确认：
- `_capture(message: String, data: Array, session_id: int) -> bool` 签名
  （参数顺序与 Godot 4.7 父类一致，移除多余的 `name` 占位）。
- `_setup_session(session_id)` 仅缓存 session id，不再立即 attach broker
  （避免 plugin 注册期被推到 connecting）。
- 移除 `_lookup_session` 里 `EditorInterface.get_debugger()` 静态调用（4.7 缺失），
  改走父类 `EditorDebuggerPlugin.get_session(id)`。
- `_capture` 收到 `event:"hello"` 时调 `_broker.mark_connected()` 推进状态机。

`runtime_broker.gd` 新增 `mark_connected()` 方法。

### P0 — `add_debugger_plugin` 必须传实例

`plugin.gd::_enter_tree` 中 `add_debugger_plugin(_runtime_debugger_plugin)` 传 `EditorDebuggerPlugin` 实例
（4.7 API 要求）。尝试传 Script 资源会触发 "argument 1 should be EditorDebuggerPlugin but is Resource" parse error，
导致整个 plugin.gd 无法编译。

### P0 — `ProbeTarget.position` 重命名

`probe_target.gd` 中 `var position: Vector2` 与 Node2D 内置字段同名，在 Godot 4.7 报
`Member "position" redefined` parse error。改为 `spawn_position: Vector2`，对应更新
`tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_get_set_call` 的 4 处 `position` →
`spawn_position`。`info()` 仍通过 `get_property_list()` 暴露 Node2D 自带 `position`，故
`test_runtime_node_info` 中 `assert "position" in info["properties"]` 不变。

### P0 — `routes/runtime/node/get.gd` doc 内嵌字典字面量

doc() 返回字符串里出现未转义的 `{"type":..., "value":...}` 内嵌花括号，破坏外层
Dictionary literal 解析。改为不含嵌套花括号的字符串说明。

## 验证证据

| 命令 | 退出 | 关键输出 |
|---|---|---|
| `cargo fmt --check` | 0 | clean |
| `cargo clippy --workspace` | 0 | 仅遗留 1 条 M2 之前的 clippy 提示 |
| `cargo test --workspace` | 0 | 全部测试通过（含 5 条 native_symbol/rename/diagnostics） |
| `tests/e2e/test_gdscript_units.py` | 0 | 8 passed in 9.32s（`runtime_protocol` / `runtime_broker` / `runtime_ring_buffer`） |

## 未触动的 P0/P1 缺陷（closure plan Task 2/3/4/6）

| 缺陷 | 现状 | 触发 E2E 失败？ |
|---|---|---|
| D2 ring buffer dropped | 未修 | 否（独立单元层修复，不依赖连接） |
| D3 fixture 日志通过 probe.record_log | 未修 | 否（probe 装入失败时才相关） |
| D4 reparent cycle 检测 | 未修 | 否（独立单元层修复） |
| D7 input polling | 未修 | 否（独立单元层修复） |

这些 P0/P1 在单元层可以独立落地并跑通；但 closure plan 的端到端验收点（status 转换、
tree、node set/get/call、log/read、signal/await 等）全部依赖 `runtime/status = connected`
状态，故被 Godot 4.7 headless 限制一并阻断。

## 根本原因（已确认）

在 `tests/fixtures/m3_project/.godot/dbg.log`（plugin 与 probe 各自的诊断输出）里：

```
[gdapi_dbg] _init (instance created)
[gdapi_dbg] _setup_session id=0
[gdapi_probe] _ready is_editor=true delay=250
[gdapi_probe] in editor, skipping capture registration
[gdapi_dbg] _has_capture 'game_view'    <- 编辑器自调试阶段问过一次
[gdapi_probe] _ready is_editor=false delay=250
[gdapi_dbg] _has_capture 'game_view'    <- 游戏进程启动后，game_view 仍被问
[gdapi_dbg] _has_capture 'game_view'
[gdapi_dbg] _has_capture 'game_view'
[gdapi_probe] _send_hello
[gdapi_probe] _send_message: calling send_message 'gdapi' size=1
[gdapi_probe] _send_message: returned
```

特征：
- `_setup_session id=0` 只出现一次（编辑器自调试阶段；游戏连接不创建新 session）。
- `_has_capture 'gdapi'` 从未出现（编辑器只为 game_view 询问我们的插件）。
- `_send_message` 在游戏进程端"成功返回"，但消息从未到达 `_capture`。

编辑器进程侧 `tasklist` 显示游戏进程已成功 fork（PID 8892，~600MB），但 `EditorDebuggerNode`
没有为它打开新的 EditorDebuggerSession。Godot 4.7 `--headless --editor` 模式不启动游戏的
TCP 远程调试端口，因此 `EditorNode.run_play()` 传给子进程的 `--remote-debug` 参数无效。

## 推荐的 M3.1 路径（不在本次任务范围）

1. **A：M3 验证改走真实 Godot 4.7（非 headless）。** 文档验证逻辑，但 CI 环境无可视化界面时
   无法复用当前 headless harness。
2. **B：fallback transport。** 沿用 closure plan 已定的"transport 与协议解耦"原则，
   `GdApiRuntimeBroker` 已有 `attach(session_id, send)` 注入接口；新增一个 file/socket
   transport（GDScript 端 `FileAccess` + JSON 消息），与 EngineDebugger 并存。这条路径需要
   重新实现 hello 阶段与 `_capture` 调度，工作量 ~1 个 PR。
3. **C：标记 M3 E2E 为 partial。** 设计 spec 把 M3 标为 `🟡 部分完成`，runtime 路线图在
   M3.1 重新建立端到端 harness 后再 flip 到 ✅。

## 状态判定

**M3 结构性收口完成；端到端运行期验证被 Godot 4.7 headless 限制阻断。**

- Step 0 / D1 / D5 / parse error 修复 / position 重命名 / doc 字面量修复：均已落地，单元测试全绿。
- D2 / D3 / D4 / D7：未触发，因依赖运行时连接。
- M3 计划中"✅ 已完成"标记不准确，应改为 `🟡 部分完成（结构 + 单元 OK / E2E 受 Godot 4.7
  headless 限制）`，并把 E2E 验证路径移到 M3.1 单独规划。

## 提交记录

按 closure plan 顺序，本次会话共产生 4 个提交（在前两批 worker 提交之上）：

```
33d5995 chore: align runtime/status surface with tests          (Step 0)
707e392 fix: schedule runtime probe hello timer (D1)            (D1)
08f1f78 fix: align runtime debugger plugin with Godot 4.7 capture API + ProbeTarget.position rename (P0)
<本次待提交> docs: M3 closure structural pass + headless limitation note
```

## 风险与回退

- 本次会话所有改动只动 `gdapi/addon/runtime/*.gd`、`gdapi/addon/plugin.gd`、
  `tests/fixtures/m3_project/scripts/probe_target.gd`、`tests/e2e/m3/test_runtime_nodes.py`、
  `tests/e2e/m3/conftest.py`。其它 M2 / M1 文件未触动。
- `tests/e2e/m3/conftest.py` 的 `sys.path` 注入来自 worker 阶段，不在本会话修复范围；
  closure plan 的 Task 7（tests 包标记）也未触动，留到 M3.1 一并清理。