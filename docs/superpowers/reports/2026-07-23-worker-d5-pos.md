# D5 + ProbeTarget.position — Worker Report

日期：2026-07-23
执行人：worker subagent
状态：**DONE_WITH_CONCERNS**

## 范围

按父会话派单，本轮只覆盖：

- 修复 `runtime_debugger_plugin.gd` 的 Godot 4.7 编译错误（`_capture` / `_setup_session` 签名 + `EditorInterface.get_debugger()` 静态方法缺失）。
- 修复 `probe_target.gd` 中 `var position: Vector2` 与 `Node2D.position` 重定义导致的 parse error。
- 修复 `runtime/node/get.gd` 的字典字面量未转义内嵌花括号导致的 parse error。
- 同步更新 `tests/e2e/m3/test_runtime_nodes.py` 中读取/写入 `position` 的用例改为 `spawn_position`。
- 不触动 D2/D3/D4/D7、`runtime_broker.gd`、`runtime_probe.gd`、`tests/__init__.py`、`tests/e2e/m3/conftest.py`、其余 fixtures。

## 修复前的 RED（基线证据）

读取最近一次失败日志 `pytest-of-hongy/pytest-24/m3_editor1/project/.godot/godot.log`：

```
SCRIPT ERROR: Parse Error: The function signature doesn't match the parent. Parent signature is "_setup_session(int) -> void".
   at: GDScript::reload (res://addons/gdapi/runtime/runtime_debugger_plugin.gd:40)
SCRIPT ERROR: Parse Error: The function signature doesn't match the parent. Parent signature is "_capture(String, Array, int) -> bool".
   at: GDScript::reload (res://addons/gdapi/runtime/runtime_debugger_plugin.gd:58)
SCRIPT ERROR: Parse Error: Static function "get_debugger()" not found in base "GDScriptNativeClass".
   at: GDScript::reload (res://addons/gdapi/runtime/runtime_debugger_plugin.gd:112)
SCRIPT ERROR: Compile Error: Failed to compile depended scripts.
   at: GDScript::reload (res://addons/gdapi/plugin.gd:0)
ERROR: Failed to load script "res://addons/gdapi/plugin.gd" with error "Compilation failed".
SCRIPT ERROR: Invalid call. Nonexistent function 'new' in base 'GDScript'.
   at: _enter_tree (res://addons/gdapi/plugin.gd:85)
SCRIPT ERROR: Parse Error: Expected closing "}" after dictionary elements.
   at: GDScript::reload (res://addons/gdapi/routes/runtime/node/get.gd:24)
```

这些错误来自 M3 主体 commit `5d5fb13`（feat: connect runtime probe over EngineDebugger）以及 `b837d7b`（feat: add runtime scene and node inspection），属于与 4.7 API 不对齐的预先存在缺陷——D1 修复无法独自通过 `connected` E2E，必须先消除 parse 错误。

## 修改文件

| 文件 | 变更 |
|---|---|
| `gdapi/addon/runtime/runtime_debugger_plugin.gd` | `_setup_session(int) -> void`（去掉自己加的 `-> bool`）；`_capture(name: String, data: Array, session_id: int) -> bool`（删掉多余的 `_message` 参数）；`_lookup_session()` 不再调用 `EditorInterface.get_debugger()`（4.7 中为缺失的静态方法），改用 `self.get_session()` 与父类 `_sessions` 回退路径。 |
| `tests/fixtures/m3_project/scripts/probe_target.gd` | `var position: Vector2` → `var spawn_position: Vector2`。`Node2D.position` 是 native 字段，子类同名 `var` 在 4.7 parse 失败。 |
| `tests/e2e/m3/test_runtime_nodes.py` | `test_runtime_node_get_set_call` 的 4 处 `"position"` 改为 `"spawn_position"`。`test_runtime_node_info` 保持不变——它断言 `"position" in info["properties"]`，仍由 Node2D 内置 `position` 满足。 |
| `gdapi/addon/routes/runtime/node/get.gd` | doc 里出现未转义的 `{"type":..., "value":...}` 内嵌花括号，破坏 dict literal 解析。改为不含嵌套花括号的字符串说明。 |

## 提交

```
08f1f78 fix: align runtime debugger plugin with Godot 4.7 capture API + ProbeTarget.position rename (P0)
```

（4 files changed, 28 insertions(+), 29 deletions(-)）

## 验证证据

| 命令 | 退出 | 关键输出 |
|---|---|---|
| `cargo build --workspace` | 0 | `Finished 'dev' profile [unoptimized + debuginfo] target(s) in 1.75s` |
| `./.venv/Scripts/python -m pytest tests/e2e/test_gdscript_units.py -v` | 0 | `8 passed in 7.04s` |
| `./.venv/Scripts/python -m pytest tests/e2e/m3/test_runtime_status.py -v` | 1 | `3 failed, 1 passed in 55.92s` |

### cargo build

```
   Compiling gdcli v0.2.0 (D:\AI\godot-ws\gdcli\cli)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 1.75s
```

### GDScript units — 全部 8 套通过

```
tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_request.gd] PASSED [ 12%]
tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_route_doc.gd] PASSED [ 25%]
tests/e2e/test_gdscript_unit_suite[res://tests/test_router.gd] PASSED [ 37%]
tests/e2e/test_gdscript_unit_suite[res://tests/test_path_guard.gd] PASSED [ 50%]
tests/e2e/test_gdscript_unit_suite[res://tests/test_variant_codec.gd] PASSED [ 62%]
tests/e2e/test_gdscript_unit_suite[res://tests/test_runtime_protocol.gd] PASSED [ 75%]
tests/e2e/test_gdscript_unit_suite[res://tests/test_runtime_broker.gd] PASSED [ 87%]
tests/e2e/test_gdscript_unit_suite[res://tests/test_runtime_ring_buffer.gd] PASSED [100%]
============================== 8 passed in 7.04s ==============================
```

### test_runtime_status.py — 编译错误已消除，但 3 个用例仍未绿

```
FAILED tests/e2e/m3/test_runtime_status.py::test_runtime_status_initial_state_is_stopped - AssertionError: assert 'connecting' == 'stopped'
FAILED tests/e2e/m3/test_runtime_status.py::test_runtime_status_after_run_reaches_connected - RuntimeError: runtime probe never reached connected state
FAILED tests/e2e/m3/test_runtime_status.py::test_runtime_status_two_consecutive_runs - RuntimeError: runtime probe never reached connected state
1 passed (test_runtime_status_doc_has_returns)
3 failed, 1 passed in 55.92s
```

固定 godot.log 读取后显示 **所有 parse error 与 compile error 都已消失**：

```
[gdapi] listening on 127.0.0.1:7891 (107 routes)
[gdapi] routes reloaded (107 routes)
[ DONE ] first_scan_filesystem
[ DONE ] update_scripts_classes
[ DONE ] loading_editor_layout
```

plugin 成功注册，路由 107 个全部加载——先前阻塞的 `plugin.gd:85 Nonexistent function 'new' in base 'GDScript'` cascade 已消失。

## 仍存在的问题（已确认不属于本轮范围）

### 1. autoload race / D6——`runtime/status` 初始状态为 `connecting`

`_setup_session(0)` 被 Godot 在 `add_debugger_plugin` 时调用（即使没有运行游戏）。它让我们直接 `_broker.attach(0, send)`，将状态机从 `stopped` 推到 `connecting`。`runtime/status` 因此在 fixture 启动后立刻读为 `connecting`。这是父任务里早就识别的 D6 autoload 注册 race，且父任务明确要求本轮"do not change unless necessary, note in the report"。

### 2. 运行游戏时 `connected` 不可达——fixture 端 `_send_hello` 与 broker capture 时序仍需协调

`test_runtime_status_after_run_reaches_connected` 失败的根因不是任何 parse/compile 错误，而是 `_capture` 与 `_send_hello` 时序。`runtime_probe.gd` 的 `_ready()` 已经按 D1 在延迟 250ms 后通过 SceneTreeTimer 调 `_send_hello()`，`hello` 事件通过 `EngineDebugger.send_message("gdapi", [{event: "hello"}])` 推回编辑器。然后 `_capture` 收到并转发到 `_broker.begin_connect()`。但 `begin_connect()` 只在 `_state != "connected"` 时把状态设为 `"connecting"`——问题是 _setup_session 已经把 state 推到 connecting，且 probe hello 之后没有任何代码把 state 推到 connected（`request()` 在 connecting 时被允许发出去但不会推到 connected）。state 仍停留在 connecting。

**修复路径**（不在本轮范围）：
- 在 `_capture` 里收到 `hello` 时一并调用 `_broker.attach()` 重新绑定 session_id；或
- 在 broker 里加显式 `mark_connected()` 方法，hello 触发时调用；或
- 让 `begin_connect()` 等收到带 `op:"hello"` 的 reply 后才推 `connected`。

父任务 plan 中"D6 风险不补丁"段落写明"未来 CI 环境如暴露该 race，加 follow-up task"，本轮按指令不修复。

### 3. fixtures 端 `probe_input_action.gd` 与 `_input` 路径耦合（D7）

父任务 plan 把 D7 标为 P1，并要求本轮不修。但 `test_runtime_input.py` 依赖 action counter 在 `_input` 中自增——若 D1 真让 run → connected 通了，下一步必须按 plan Task 6 改 `probe_input_action.gd` 使用 `_process` 轮询。

### 4. `_setup_session` 通过父类 `_sessions` 反查——平台依赖

`_lookup_session()` 当前用 `self.get_session()` + `_sessions` 属性反射。Godot 4.7 中 `EditorDebuggerPlugin` 实际暴露的方法签名可能不同（实测结果是父类确实注入了 `_sessions` 且可读），但这是黑魔法路径。如有更稳定的官方访问方式建议优先替换；本轮以最小修改让测试可运行为目标。

## 残留风险

1. **autoload race（D6）未修**，按指令保留。
2. **`runtime_capture_ops.gd` / `runtime_input_ops.gd` / `runtime_node_ops.gd` 4.7 兼容性**：尚未在真实 4.7 run 中执行过 capture / sequence / assert；只有 unit 层有覆盖。
3. **`routes/runtime/**/*.gd` 的 dict 字面量潜在未转义**：本轮只 grep 到 `node/get.gd:24` 一处需要修复。父任务后续大规模 E2E 跑通时可能在 capture 或其他 route doc 上暴露类似问题。

## 推荐下一步（父任务）

1. 在 `_capture` 收到 `hello` 事件时调用一个新加的 broker 方法 `mark_connected()`，把状态机推到 `connected`；同步修正 `test_runtime_status_initial_state_is_stopped` 的初始 expectation——或让 broker 在 plugin-register 完成时仍保持 `stopped`，仅在 probe 真正 hello 时推到 connecting（避免 setup_session 副作用）。
2. 按 plan 继续 D7 输入 polling 修复 + D2 ring buffer dropped + D3 fixture 日志链路 + D4 reparent 显式化。
3. 新增完整 fixtures E2E 之前，重跑 `tests/e2e/m3 -v` 全量，验证 M3 整段无回归。

## 本轮交付的硬指标

| 任务验收点 | 状态 |
|---|---|
| 4 个文件正确改动 | ✅ |
| `cargo build --workspace` exit 0 | ✅ |
| `tests/e2e/test_gdscript_units.py` 8 passed | ✅ |
| `runtime_debugger_plugin.gd` parse error 消失 | ✅（godot.log 验证） |
| `runtime/node/get.gd` parse error 消失 | ✅（godot.log 验证） |
| `probe_target.gd` parse error 消失 | ✅（godot.log 验证） |
| `plugin.gd` cascade 编译失败消失 | ✅（godot.log 验证） |
| `test_runtime_status.py` 4 passed | ⚠️ 仅 1 passed（autoload race D6 阻断） |

## 命令清单（按父任务要求原样执行）

```bash
GODOT_BIN="D:/app/devel/Godot/v4.7.1/godot_console.exe" cargo build --workspace
# exit 0
# Finished `dev` profile [unoptimized + debuginfo] target(s) in 1.75s

GODOT_BIN="D:/app/devel/Godot/v4.7.1/godot_console.exe" ./.venv/Scripts/python -m pytest tests/e2e/test_gdscript_units.py -v
# exit 0 — 8 passed in 7.04s

GODOT_BIN="D:/app/devel/Godot/v4.7.1/godot_console.exe" ./.venv/Scripts/python -m pytest tests/e2e/m3/test_runtime_status.py -v
# exit 1 — 3 failed, 1 passed in 55.92s (autoload race D6)
```
