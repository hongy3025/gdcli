# Step 0 + Task 1 (D1) — Worker Report

日期：2026-07-23
执行人：worker subagent
状态：**DONE_WITH_CONCERNS**

## 范围

按父会话调度，本轮只覆盖：

- Step 0：补齐 `runtime/status` 的 `broker_registered` + `session_started_at` 字段，使 M3 E2E 现存断言成立。
- Task 1 (D1)：在 `runtime_probe.gd::_ready()` 加入 SceneTreeTimer 分支，使 `runtime_probe_hello_delay_ms > 0` 时也能发出 hello，broker 状态机从 `connecting` 过渡到 `connected`。

未触动 D2/D3/D4/D5/D7、`tests/e2e/m3/conftest.py`、fixtures 或 `tests/__init__.py`。

## 改动文件

| 文件 | 改动 |
|---|---|
| `gdapi/addon/runtime/runtime_broker.gd` | `status()` 新增 `broker_registered` 与 `session_started_at`；新增 `_session_started_at` 实例变量并在首次 `attach()` 时记录。 |
| `gdapi/addon/routes/runtime/status.gd` | `doc()` 的 `returns.fields` 增补 `session_started_at` 说明。两条 dispatch 分支（broker null / 非 null）原本就分别输出 `broker_registered:false` / `true`，验证后保持不动。 |
| `gdapi/addon/runtime/runtime_probe.gd` | `_ready()` 末尾由"仅在延迟 <=0 时 `_send_hello()`"扩展为"延迟 >0 时 `create_timer` + `timeout.connect(_on_hello_timer_timeout)`"。 |

## 提交

```
33d5995 chore: align runtime/status surface with tests
707e392 fix: schedule runtime probe hello timer (D1)
```

## 验证证据

| 命令 | 退出 | 关键输出 |
|---|---|---|
| `cargo build --workspace` | 0 | `Finished 'dev' profile [unoptimized + debuginfo] target(s) in 1.65s` |
| `./.venv/Scripts/python -m pytest tests/e2e/test_gdscript_units.py -v` | 0 | `8 passed in 7.03s`（含 `test_runtime_protocol`、`test_runtime_broker`、`test_runtime_ring_buffer`） |
| `./.venv/Scripts/python -m pytest tests/e2e/m3/test_runtime_status.py -v` | 1 | `2 failed, 2 passed in 58.59s`（初始 state 与 doc 测试通过；`after_run_reaches_connected` 与 `two_consecutive_runs` 失败：`RuntimeError: runtime probe never reached connected state`） |

## D1 失败的原因（不属于本轮任务）

`tests/e2e/m3/test_runtime_status.py::test_runtime_status_after_run_reaches_connected` 与 `test_runtime_status_two_consecutive_runs` 失败，但根因并非 D1 修复不生效：

- fixture `tests/fixtures/m3_project/scripts/probe_target.gd:6` 触发 `SCRIPT ERROR: Parse Error: Member "position" redefined (original in native class 'Node2D')` —— `Node2D` 自带 `position`，fixture 用同名变量覆盖造成 parse 失败，autoload 加载链中断。
- `gdapi/addon/runtime/runtime_debugger_plugin.gd:58,112` 触发 `Parse Error: The function signature doesn't match the parent. Parent signature is "_capture(String, Array, int) -> bool"` 与 `Static function "get_debugger()" not found in base "GDScriptNativeClass"` —— 这些 Godot 4.7 API 形态错误在父任务历史 commit 中已存在（早于本轮）。
- `gdapi/addon/routes/runtime/node/get.gd:24` 也存在 dictionary 闭合错误。

这些都是 fixture/route 自身实现 bug，与本轮 `runtime_broker.status()` 字段扩展或 `runtime_probe._ready()` timer 修复无关。父任务里 D3（fixture 日志链路）、D5（debugger session fallback 清理）以及 routes 子目录内 GDScript 兼容 4.7 的修订必然要先落地，连接到 connected 的测试才会真正绿。

## D1 修复正确性的独立旁证

- 单元测试 `tests/fixture_project/tests/test_runtime_broker.gd` 已覆盖 broker 状态机三态迁移、`attach/detach` 语义、`tick()` 超时清理、idempotent detach 等全部路径，仍 8/8 通过。说明本轮对 `runtime_broker.status()` / `_session_started_at` 的修改没有破坏 broker 状态契约。
- 字段在 Godot 4.7 GDScript 静态语法层通过（`Engine.has_meta`、`Time.get_unix_time_from_system()`、`create_timer` 均已在 4.7 提供）。
- D1 的 `_on_hello_timer_timeout` 已存在并直接调用 `_send_hello()`，仅补一个 timer 即可。

## 已观察到的其它问题（不在本轮处理）

- `tests/fixture_project/tests/` 缺少 `test_runtime_condition.gd`，但 `tests/e2e/test_gdscript_units.py` 没有 parametrize 该文件，因此不影响本轮验证。
- `runtime/debug/errors` 与 `runtime/debug/breakpoints` 当前 doc 与实际响应字段与 plan 期望不完全一致，但 plan 已允许 v1 行为，本轮不修。

## 残留风险

1. `runtime_probe` 的 hello delay timer 在 Godot 4.7 上 `create_timer` 返回的是 `SceneTreeTimer` 单次触发；正常停止或再次 attach 后该 timer 不需要清理。若未来引入长延迟可配置或 reconnect 周期，D6（autoload 注册 race）会放大此问题。
2. `_session_started_at` 在首次 attach 之前为 0。`runtime/status` 文档已声明，但客户端若依赖"非零即有 session"语义需注意。
3. 当前未修复的 fixture/route parse 错误会让 `m3_running` 夹具无法 ready；本轮不修，但父任务需明确把它们纳入后续修复（与 D3/D5 同期）。

## 推荐下一步

- 把 D5（`runtime_debugger_plugin.gd` Godot 4.7 API 修正）与 fixture `probe_target.gd::position` 改名、`routes/runtime/node/get.gd` 的字典闭合一并修掉，再回头跑 D1 E2E —— 这样 connected 路径才能真正跑通。
- D2（ring buffer dropped）与 D4（reparent cycle）可在不依赖游戏运行的单元层先绿，再把 D3 + D5 + probe_target fixture 同步修完后做端到端验证。