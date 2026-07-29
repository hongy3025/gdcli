# gdcli M3 Runtime Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 M3 runtime 的 broker/file/EngineDebugger 数据面闭环，使 35 条公开 route 在真实 game 进程执行，并在不改变 protocol v1、CLI 行为和 transport 边界的前提下达到完整 M3 验收与性能门槛。

**Architecture:** `runtime/status` 保持 editor-side；其它 34 条 route 只通过 `GdApiRuntimeRoute.dispatch()` 调用 editor-side `GdApiRuntimeBroker`。Broker 独占 request id、pending、deadline、generation 和 exactly-once completion，EngineDebugger/file transport 只收发消息；probe 对同步和异步 allowlisted op 都先 claim inbox、完成后写 outbox。E2E 使用一个 session-scoped editor，scene/node 与 reset_fixture 通过后才共享 data-plane game。

**Tech Stack:** Godot 4.7.x、GDScript `@tool` addon、Rust `gdcli` CLI、Python pytest/uv、现有 EngineDebugger 与 file transport、现有 protocol v1。

## Global Constraints

- 公开 runtime route 精确保持 35 条，`runtime/status` 是唯一 editor-side route，其余 34 条必须经 broker 在 game 进程执行。
- protocol 顶层 request/reply/event 结构和 version `1` 保持兼容；不得引入 TCP、WebSocket 或第三种 transport。
- EngineDebugger 优先级固定为 `engine_debugger > file > none`；Godot 4.7 headless 使用 file fallback。
- CLI E2E 必须继续调用真实 `gdcli --json exec`；不得改成 direct HTTP、skip 或弱化断言。
- operation timeout 默认 5000 ms、最大 25000 ms；broker grace 为 1000 ms；HTTP/CLI deadline 保持 30 秒。
- request/reply 最大 4 MiB；capture 最大 1920×1080；frames 最大 60；input sequence 最大 100 events 且累计 10 秒。
- runtime mutation 不接入 UndoRedo；成功响应必须包含 `changed`、`undoable:false` 和摘要，成功/拒绝均审计并递归 redaction。
- 所有辅助脚本使用 Python；不新增 `.sh` 或 `.ps1`。
- 不修改交接中既有用户改动：`.gitignore`、两个 `project.godot`、`runtime_main.tscn`、`docs/reports/2026-07-29-gdcli-roadmap-implementation-status.md`、`tests/fixtures/m3_project/addons/`。
- 每个任务必须先 RED、再最小实现、再 GREEN；GREEN 前不得迁移下一组 route。任何组合测试失败、callback 重复、pending 非零、stale 目录残留或 route manifest 变化都停止该任务并保留最小失败证据。

## Mandatory preflight contract gate

当前仓库的 route 文件和 manifest 原先各为 32 条；用户已确认补齐三条 node mutation route：`runtime/node/create`、`runtime/node/duplicate`、`runtime/node/rename`。Task 9 必须先为这三条建立 RED，再实现 game-side op、route doc、audit 和 E2E，完成后 manifest 才能精确为 35 条。不得用 alias 代替独立 route，也不得把其它命令误计入 runtime manifest。

## File Map

| File | Responsibility after remediation |
|---|---|
| `gdapi/addon/runtime/runtime_broker.gd` | 唯一的 id/pending/deadline/generation/state/transport owner；接收所有 reply。 |
| `gdapi/addon/runtime/runtime_transport_file_editor.gd` | 扫描 hello/outbox、写 inbox、报告 transport 变化；不再有业务 pending。 |
| `gdapi/addon/runtime/runtime_transport_file_probe.gd` | claim inbox、启动同步/异步 handler、原子写 outbox、清理 probe generation。 |
| `gdapi/addon/runtime/runtime_debugger_plugin.gd` | EngineDebugger session 生命周期、hello generation、`broker.receive()` bridge。 |
| `gdapi/addon/runtime/runtime_probe.gd` | file/EngineDebugger 共用 dispatch，暴露 generation、reset/log helper。 |
| `gdapi/addon/runtime/runtime_route.gd` | 34 条 route 的异步 adapter、timeout/error mapping、mutation audit。 |
| `gdapi/addon/plugin.gd` | debugger plugin 注册/移除、run/stop generation cleanup、file manager 生命周期。 |
| `gdapi/addon/routes/runtime/**/*.gd` | 只保留固定 op、mutation 标记和 `doc()`；不得加载 runtime ops。 |
| `tests/fixture_project/tests/test_runtime_*.gd` | broker/transport/route/safety 的可重复 unit/combination tests。 |
| `tests/e2e/m3/conftest.py` and `tests/e2e/m3/test_*.py` | session harness、reset/recovery、真实 CLI route assertions、diagnostics。 |
| `tests/fixtures/m3_project/scripts/*.gd` | known logs、action edge polling、reparent/signal/reset fixture hooks。 |

---

### Task 1: Lock the RED baseline and add broker/file sync+async combination tests

**Files:**
- Create: `tests/fixture_project/tests/test_runtime_transport_integration.gd`
- Modify: `tests/e2e/test_gdscript_units.py`

**Interfaces:**
- Consumes: existing `GdApiRuntimeBroker.request/receive/tick`, `GdApiRuntimeTransportFileProbe.start/tick/stop`, `GdApiRuntimeTransportFileEditor.start/tick`.
- Produces: executable tests named `test_broker_file_sync_roundtrip`, `test_broker_file_async_roundtrip`, `test_reply_completes_once`, `test_unknown_and_duplicate_reply_are_ignored`, `test_timeout_then_late_reply_is_ignored`, `test_generation_and_priority_reject_stale_hello`.

- [ ] **Step 1: Write the failing tests.** Build a temporary `.godot/gdapi_runtime_test` root, instantiate a real broker, editor file manager and probe transport, connect the editor sender to the broker, and use handlers that return immediately or `await process_frame` before returning. Assert the callback result, callback count, broker pending count, and outbox removal. Add a duplicate reply file after the first reply and assert the callback count stays one.

- [ ] **Step 2: Run RED.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k runtime_transport_integration -v`

  Expected: FAIL because the editor transport owns a private pending map and the probe scanner writes a reply before the broker can consume it; the async test must also demonstrate that a suspended handler is not treated as a completed dictionary.

  Also run: `@("gdapi/addon/routes/runtime/*.gd", "tests/e2e/m3/test_m3_contract.py") | Out-Null; (rg --files gdapi/addon/routes/runtime -g '*.gd').Count`

  Expected contract evidence: the pre-change baseline is `32`; Task 9 must add exactly the three approved node routes and make the final manifest `35`.

- [ ] **Step 3: Write only the test harness helpers.** Add `_make_root()`, `_cleanup(root)`, `_write_inbox(root, probe_id, id, message)`, `_write_outbox(...)`, and callback counters. Do not alter production transport behavior in this task.

- [ ] **Step 4: Re-run RED and record the first failure.** The expected first functional failure is `callback count == 0` or `pending == 0` before broker completion; if the test fails during setup, fix only the test harness.

- [ ] **Step 5: Check and commit the test baseline.**

  Run: `git diff --check`

  Commit: `git add tests/fixture_project/tests/test_runtime_transport_integration.gd tests/e2e/test_gdscript_units.py; git commit -m "test(m3): lock runtime transport integration failures"`

  Stop if the RED test passes without a production change, because that means the baseline or the test is not exercising the broken ownership path.

### Task 2: Move pending ownership into the broker and bridge file replies directly

**Files:**
- Modify: `gdapi/addon/runtime/runtime_broker.gd`
- Modify: `gdapi/addon/runtime/runtime_transport_file_editor.gd`
- Modify: `tests/fixture_project/tests/test_runtime_broker.gd`
- Modify: `tests/fixture_project/tests/test_runtime_transport_file_editor.gd`
- Test: `tests/fixture_project/tests/test_runtime_transport_integration.gd`

**Interfaces:**
- Consumes: `broker.request(op, payload, timeout_ms, callback)` as the only request entry point.
- Produces: broker methods `attach_file_transport(probe_id, send, generation)`, `detach_file_transport(reason, generation)`, `set_transport_connected(name, connected, generation)`, and transport `send(message) -> bool`; `_scan_outbox()` calls `broker.receive(reply)` after deleting a valid file.

- [ ] **Step 1: Add RED assertions.** Assert the editor file transport exposes no business `request`, `pending_count`, or local timeout path; a broker request writes `inbox/<broker id>.json`, an outbox reply invokes the broker callback, pending returns to zero, and unknown/duplicate/malformed replies do not invoke any callback or consume a live broker pending entry. Add an EngineDebugger/file selection assertion that an attached file probe cannot replace an already-connected EngineDebugger sender.

- [ ] **Step 2: Run RED.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_broker or runtime_transport_file_editor or runtime_transport_integration" -v`

  Expected: the combination callback does not fire because `_scan_outbox()` checks the editor transport `_pending`, which does not contain the broker id.

- [ ] **Step 3: Implement the minimum ownership change.** Remove editor transport `_pending`, `_next_id`, `request()`, and timeout callbacks. Keep `setup`, `start`, `tick`, `stop_all`, `active_probe_ids`, and `send` creation. Have `_scan_outbox()` parse a complete protocol dictionary and call `_broker.receive(dict)`; malformed or unknown files are deleted without a callback. Put id allocation, deadline, timeout, late-reply rejection, and exactly-once erase-before-callback in the broker.

- [ ] **Step 4: Add bounds/validation at the broker boundary.** Validate request and reply with `Protocol.validate_message`, reject a serialized message over `Protocol.MAX_MESSAGE_BYTES` with `invalid_param`, and preserve stable codes instead of mapping failures to `unknown`.

- [ ] **Step 5: Run GREEN for this task and preserve later RED evidence.**

  Run: `$env:GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe'; uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_broker or runtime_transport_file_editor" -v`

  Expected: all broker/editor ownership, priority, malformed/unknown/duplicate/late-reply tests pass; callback count is exactly one and broker pending is zero. Run the separate integration script afterward and record its async/generation failures as intentional RED for Tasks 3 and 5; do not claim that later-task RED is Task 2 failure.

- [ ] **Step 6: Check and commit.**

  Run: `git diff --check`

  Commit: `git add gdapi/addon/runtime/runtime_broker.gd gdapi/addon/runtime/runtime_transport_file_editor.gd tests/fixture_project/tests/test_runtime_broker.gd tests/fixture_project/tests/test_runtime_transport_file_editor.gd tests/fixture_project/tests/test_runtime_transport_integration.gd; git commit -m "fix(m3): make broker own runtime pending replies"`

  Stop if any transport-local pending remains on the request path or a late reply can invoke a callback after timeout/detach.

### Task 3: Close the async probe inflight lifecycle

**Files:**
- Modify: `gdapi/addon/runtime/runtime_transport_file_probe.gd`
- Modify: `gdapi/addon/runtime/runtime_probe.gd`
- Modify: `tests/fixture_project/tests/test_runtime_transport_file_probe.gd`
- Modify: `tests/fixture_project/tests/test_runtime_transport_integration.gd`

**Interfaces:**
- Consumes: probe handler callable returning either `Dictionary` or an awaitable result through `await _dispatch_async(op, payload)`.
- Produces: probe `_inflight: Dictionary`, `_claim_inbox(id)`, `_start_request(id, message)`, `_finish_request(id, reply)`, and `tick()` behavior that writes outbox only after the awaited handler resolves.

- [ ] **Step 1: Add RED async assertions.** Register a handler that awaits two `process_frame` ticks, call `transport.tick()` several times, and assert the inbox is claimed once, no outbox exists while suspended, then one outbox appears after resume. Add two files with the same id and assert only one handler invocation.

- [ ] **Step 2: Run RED.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_transport_file_probe or runtime_transport_integration" -v`

  Expected: the existing synchronous scanner either writes an invalid reply for an unresolved coroutine or blocks/does not close the request; the test must fail before production changes.

- [ ] **Step 3: Implement claim/inflight.** In `_scan_inbox()`, atomically read and remove each complete request before dispatch; skip ids already in `_inflight`. Start a coroutine per id, await the handler/dispatch result, validate and size-check the reply, atomically write `outbox/<id>.json`, then erase `_inflight[id]`. On handler error/timeout, write a structured reply rather than silently dropping the id.

- [ ] **Step 4: Preserve EngineDebugger behavior.** Make `_handle_file_transport_request` and `_dispatch` use the same `_dispatch_async` implementation; do not introduce a second op allowlist or a third transport.

- [ ] **Step 5: Run GREEN.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_transport_file_probe or runtime_transport_integration" -v`

  Expected: sync and suspended handlers each produce one valid reply, duplicate inbox ids produce no duplicate, and pending reaches zero through the broker bridge.

- [ ] **Step 6: Check and commit.**

  Run: `git diff --check`

  Commit: `git add gdapi/addon/runtime/runtime_transport_file_probe.gd gdapi/addon/runtime/runtime_probe.gd tests/fixture_project/tests/test_runtime_transport_file_probe.gd tests/fixture_project/tests/test_runtime_transport_integration.gd; git commit -m "fix(m3): complete async file probe requests"`

  Stop if an async op can write outbox before completion, be processed twice, or leave `_inflight` after a reply.

### Task 4: Register EngineDebugger, enforce transport priority, and verify fallback

**Files:**
- Modify: `gdapi/addon/plugin.gd`
- Modify: `gdapi/addon/runtime/runtime_broker.gd`
- Modify: `gdapi/addon/runtime/runtime_debugger_plugin.gd`
- Modify: `gdapi/addon/runtime/runtime_transport_file_editor.gd`
- Modify: `tests/fixture_project/tests/test_runtime_broker.gd`
- Create: `tests/fixture_project/tests/test_runtime_debugger_plugin.gd`
- Modify: `tests/e2e/test_gdscript_units.py`

**Interfaces:**
- Consumes: `EditorPlugin.add_debugger_plugin(EditorDebuggerPlugin)` and `remove_debugger_plugin`, debugger `_capture`, file manager hello scanner.
- Produces: broker selection `engine_debugger > file > none`, file hello that cannot displace an active EngineDebugger sender, EngineDebugger detach that falls back to same-generation file, and unit-observable registration hooks.

- [ ] **Step 1: Add RED tests.** Extend broker tests with both senders attached and assert requests use EngineDebugger; after debugger disconnect assert file is selected; after both detach assert all pending fail once. Add a debugger plugin test using a fake session/capture payload to assert hello attaches and replies enter `broker.receive`. Add a plugin source-contract test or Godot integration assertion that `_enter_tree()` calls `add_debugger_plugin(_runtime_debugger_plugin)`.

- [ ] **Step 2: Run RED.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_broker or runtime_debugger_plugin" -v`

  Expected: no priority/fallback behavior exists and `plugin.gd` currently has no debugger registration call.

- [ ] **Step 3: Implement the minimum selection state.** Store `_engine_sender`, `_file_sender`, `_engine_connected`, `_file_connected`, `_active_transport`; centralize `_select_sender()` and never overwrite a connected engine sender from a file hello. Include generation checks in each attach/detach. Have the debugger plugin mark engine connected only after a valid hello and pass replies/events to the broker.

- [ ] **Step 4: Register and unregister the plugin.** Call `add_debugger_plugin(_runtime_debugger_plugin)` immediately after setup in `_enter_tree()` and retain the paired removal in `_exit_tree()`; ensure registration happens before game lifecycle requests.

- [ ] **Step 5: Run GREEN.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_broker or runtime_debugger_plugin" -v`

  Expected: all priority, fallback, registration, and exactly-once detach tests pass.

- [ ] **Step 6: Check and commit.**

  Run: `git diff --check`

  Commit: `git add gdapi/addon/plugin.gd gdapi/addon/runtime/runtime_broker.gd gdapi/addon/runtime/runtime_debugger_plugin.gd gdapi/addon/runtime/runtime_transport_file_editor.gd tests/fixture_project/tests/test_runtime_broker.gd tests/fixture_project/tests/test_runtime_debugger_plugin.gd tests/e2e/test_gdscript_units.py; git commit -m "fix(m3): register debugger and prioritize transports"`

  Stop if file hello changes an active engine transport, or if a debugger session is never registered/removed as a pair.

### Task 5: Add generation binding and stale transport cleanup

**Files:**
- Modify: `gdapi/addon/runtime/runtime_protocol.gd`
- Modify: `gdapi/addon/runtime/runtime_broker.gd`
- Modify: `gdapi/addon/runtime/runtime_transport_file_editor.gd`
- Modify: `gdapi/addon/runtime/runtime_transport_file_probe.gd`
- Modify: `gdapi/addon/runtime/runtime_debugger_plugin.gd`
- Modify: `gdapi/addon/runtime/runtime_probe.gd`
- Modify: `gdapi/addon/plugin.gd`
- Modify: `tests/fixture_project/tests/test_runtime_protocol.gd`
- Modify: `tests/fixture_project/tests/test_runtime_broker.gd`
- Modify: `tests/fixture_project/tests/test_runtime_transport_file_editor.gd`
- Modify: `tests/fixture_project/tests/test_runtime_transport_file_probe.gd`

**Interfaces:**
- Consumes: protocol v1 event result metadata and project lifecycle hooks.
- Produces: broker `begin_generation() -> String`, generation-aware `begin_connect`, hello/result fields `{generation, pid, started_at, transport}`, stale hello/outbox rejection, and safe recursive cleanup at run start, stop, probe exit, and plugin exit.

- [ ] **Step 1: Add RED lifecycle tests.** Seed an old hello and outbox, start a new generation, and assert old files are removed/rejected. Assert a hello from generation A cannot connect generation B, a disappeared hello detaches the probe, and stopping a probe removes the entire probe directory even when inbox/outbox contain files.

- [ ] **Step 2: Run RED.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_protocol or runtime_broker or runtime_transport_file" -v`

  Expected: old hello can be attached, hello has no generation metadata, and probe stop leaves non-empty directories/files.

- [ ] **Step 3: Implement generation without changing the top-level protocol shape.** Add generation to `event.result` and request/reply metadata where needed; broker accepts only the current generation and binds the first valid hello. Use explicit root cleanup helpers that recurse only under `res://.godot/gdapi_runtime`.

- [ ] **Step 4: Handle disappearance and stop.** File manager detects missing hello/process generation and calls broker detach/fallback; plugin calls cleanup before `begin_connect()` on every `project/run`, on `project/stop`, and during `_exit_tree()`.

- [ ] **Step 5: Run GREEN.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_protocol or runtime_broker or runtime_transport_file" -v`

  Expected: stale files never connect, current generation replies complete, and all transport roots are empty/removed after stop.

- [ ] **Step 6: Check and commit.**

  Run: `git diff --check`

  Commit: `git add gdapi/addon/runtime/runtime_protocol.gd gdapi/addon/runtime/runtime_broker.gd gdapi/addon/runtime/runtime_transport_file_editor.gd gdapi/addon/runtime/runtime_transport_file_probe.gd gdapi/addon/runtime/runtime_debugger_plugin.gd gdapi/addon/runtime/runtime_probe.gd gdapi/addon/plugin.gd tests/fixture_project/tests/test_runtime_protocol.gd tests/fixture_project/tests/test_runtime_broker.gd tests/fixture_project/tests/test_runtime_transport_file_editor.gd tests/fixture_project/tests/test_runtime_transport_file_probe.gd; git commit -m "fix(m3): isolate runtime generations and clean stale probes"`

  Stop if a stale hello reaches `connected`, an old outbox completes a current request, or cleanup traverses outside the runtime root.

### Task 6: Add the unified runtime route adapter and error/audit contract

**Files:**
- Create: `gdapi/addon/runtime/runtime_route.gd`
- Modify: `gdapi/addon/runtime/error_codes.gd`
- Modify: `gdapi/addon/runtime/audit_log.gd`
- Modify: `gdapi/addon/runtime/response.gd`
- Create: `tests/fixture_project/tests/test_runtime_route.gd`
- Modify: `tests/e2e/test_gdscript_units.py`

**Interfaces:**
- Produces: `GdApiRuntimeRoute.dispatch(req: GdApiRequest, res: GdApiResponse, op: String, mutation: bool = false)`, `GdApiRuntimeRoute.operation_timeout(req)`, `GdApiRuntimeRoute.http_status(code)`, and recursive `GdApiRuntimeRoute.redact(value)`.
- Consumes: `GdApiRuntimeBroker.instance().request(op, payload, broker_timeout, callback)` and `Engine.get_meta("gdapi_plugin")` audit API.

- [ ] **Step 1: Add RED adapter tests.** Test disconnected broker, invalid/missing timeout, timeout max, all error-code-to-status mappings, successful envelope, mutation fields, recursive secret redaction, base64/large-array summaries, and response exactly-once behavior with a fake broker/response.

- [ ] **Step 2: Run RED.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k runtime_route -v`

  Expected: the adapter file/classes do not exist and route code has inconsistent 500 mappings.

- [ ] **Step 3: Implement the adapter.** Validate `req.body`, split operation timeout from broker timeout (`operation + 1000 ms`, capped at 26000), call the broker, erase/complete through the broker callback, map codes exactly as specified, and guard `res._sent`/a local completion flag. Mutation success and rejection call the audit logger with redacted payload and result; mutation success adds `changed`, `undoable:false`, and operation summary.

- [ ] **Step 4: Run GREEN.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k runtime_route -v`

  Expected: all adapter unit tests pass with one response and stable HTTP status for every listed error code.

- [ ] **Step 5: Check and commit.**

  Run: `git diff --check`

  Commit: `git add gdapi/addon/runtime/runtime_route.gd gdapi/addon/runtime/error_codes.gd gdapi/addon/runtime/audit_log.gd gdapi/addon/runtime/response.gd tests/fixture_project/tests/test_runtime_route.gd tests/e2e/test_gdscript_units.py; git commit -m "feat(m3): add unified runtime route adapter"`

  Stop if any adapter path loads editor-local runtime ops, sends two responses, exposes secrets, or maps `timeout` away from HTTP 408.

### Task 7: Migrate `runtime/node/get` as the vertical slice

**Files:**
- Modify: `gdapi/addon/routes/runtime/node/get.gd`
- Modify: `tests/e2e/m3/test_runtime_nodes.py`
- Modify: `tests/e2e/m3/conftest.py`
- Add one focused assertion to: `tests/fixture_project/tests/test_runtime_route.gd`

**Interfaces:**
- Consumes: `GdApiRuntimeRoute.dispatch(req, res, "runtime/node/get")`.
- Produces: a real CLI path returning the game probe's typed `Vector2` from `/root/RuntimeMain/ProbeTarget`.

- [ ] **Step 1: Add/strengthen RED.** Assert `runtime/node/get` returns `[10.0,20.0]`, includes `ok:true`, and the route source contains no `load("...runtime_node_ops.gd")`.

- [ ] **Step 2: Run RED.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_get_set_call -v`

  Expected: current route reads editor SceneTree and returns `not_found` for `/root/RuntimeMain/ProbeTarget`.

- [ ] **Step 3: Replace only this route's local call.** Make the handler extend `runtime_route.gd`, call `dispatch(req, res, "runtime/node/get")`, and retain its existing `doc()` unchanged except for accurate returns text.

- [ ] **Step 4: Run GREEN through the real CLI.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_get_set_call -v`

  Expected: typed `Vector2` comes from the game process and no editor-process path is used.

- [ ] **Step 5: Check and commit.**

  Run: `git diff --check`

  Commit: `git add gdapi/addon/routes/runtime/node/get.gd tests/e2e/m3/test_runtime_nodes.py tests/e2e/m3/conftest.py tests/fixture_project/tests/test_runtime_route.gd; git commit -m "feat(m3): route node get through runtime broker"`

  Stop if the vertical slice passes only through direct HTTP/direct GDScript or if the typed value is not from `/root/RuntimeMain`.

### Task 8: Build the session-scoped editor harness and diagnostics

**Files:**
- Modify: `tests/e2e/m3/conftest.py`
- Modify: `tests/e2e/m3/test_runtime_status.py`
- Modify: `tests/e2e/m3/test_m3_contract.py`
- Modify: `tests/e2e/conftest.py`
- Modify: `pyproject.toml` to declare `pytest-timeout>=2.3`

**Interfaces:**
- Produces: session-scoped `m3_editor`, one lifecycle scenario fixture covering run/stop twice, `m3_running` with explicit cleanup, `exec_ok`/`exec_error` diagnostics containing command, exit code, stdout/stderr, runtime status and Godot log tail.

- [ ] **Step 1: Add RED timing/fixture assertions.** Add a test that records editor process identity and build/install counters, asserts all status/contract tests use one editor, and asserts failed CLI output includes the six diagnostic fields. Keep the existing correctness assertions.

- [ ] **Step 2: Run RED.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_status.py tests/e2e/m3/test_m3_contract.py -v --durations=20`

  Expected: current function-scoped fixtures rebuild/copy/install/start repeatedly and failure helpers lack full diagnostics.

- [ ] **Step 3: Implement session ownership.** Build/copy/install once in a session fixture, start one editor, yield a session object, and stop it in finalizer. Make lifecycle assertions one scenario; use condition polling instead of fixed one-second sleeps. Keep game restarts for tests that still need isolation until Task 10.

- [ ] **Step 4: Implement failure recovery.** On reset/readiness failure capture diagnostics, preserve the original assertion, restart at most the permitted game count, and report recovery explicitly.

- [ ] **Step 5: Add the hang guard.** Add `pytest-timeout>=2.3` to `pyproject.toml`, refresh `uv.lock` with the repository's normal `uv lock` command, and apply the suite timeout only as a deadlock guard; operation-specific assertions remain responsible for normal timeout behavior.

- [ ] **Step 6: Run GREEN and measure.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_status.py tests/e2e/m3/test_m3_contract.py -v --durations=20`

  Expected: one editor start, lifecycle state/generation/pending checks pass, and setup time is materially below the previous 28.89 s status baseline.

- [ ] **Step 7: Check and commit.**

  Run: `git diff --check`

  Commit: `git add tests/e2e/m3/conftest.py tests/e2e/m3/test_runtime_status.py tests/e2e/m3/test_m3_contract.py tests/e2e/conftest.py pyproject.toml uv.lock; git commit -m "test(m3): reuse editor session and collect diagnostics"`

  Stop if fixture scope hides a failed lifecycle assertion, diagnostics omit original failure details, or more than one editor is started.

### Task 9: Migrate the scene/node route family

**Files:**
- Modify: `gdapi/addon/routes/runtime/scene/tree.gd`
- Modify: `gdapi/addon/routes/runtime/node/info.gd`
- Modify: `gdapi/addon/routes/runtime/node/set.gd`
- Modify: `gdapi/addon/routes/runtime/node/call.gd`
- Modify: `gdapi/addon/routes/runtime/node/find.gd`
- Modify: `gdapi/addon/routes/runtime/node/remove.gd`
- Modify: `gdapi/addon/routes/runtime/node/reparent.gd`
- Create: `gdapi/addon/routes/runtime/node/create.gd`
- Create: `gdapi/addon/routes/runtime/node/duplicate.gd`
- Create: `gdapi/addon/routes/runtime/node/rename.gd`
- Modify: `gdapi/addon/runtime/runtime_node_ops.gd`
- Modify: `tests/e2e/m3/test_runtime_nodes.py`
- Modify: `tests/e2e/m3/test_m3_contract.py`
- Modify: `tests/e2e/m3/conftest.py`
- Modify: `tests/fixture_project/tests/test_runtime_route.gd`

**Interfaces:**
- Consumes: adapter dispatch with fixed ops `runtime/scene/tree`, `runtime/node/info`, `get`, `set`, `call`, `find`, `remove`, `reparent`, `create`, `duplicate`, and `rename`.
- Produces: all scene/node operations executed by `runtime_probe.gd` in game process, including mutation envelope and allowlist errors; the runtime manifest grows from 32 to exactly 35 routes.

- [ ] **Step 1: Add RED source and behavior checks.** Add one test per existing route family behavior plus `runtime/node/create`, `runtime/node/duplicate`, and `runtime/node/rename`. Assert create returns a dedicated runtime node path, duplicate returns a distinct node with copied allowlisted properties, rename changes only the dedicated fixture node name, all three return `undoable:false`, invalid paths/duplicate names are rejected without mutation, and no route contains a runtime ops `load()`.

- [ ] **Step 2: Run RED.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_nodes.py -v`

  Expected: the current editor-local handlers cannot resolve `/root/RuntimeMain/...`, the reparent cycle is not rejected before mutation, and the three new route files/manifest entries are absent.

- [ ] **Step 3: Migrate existing handlers and add the three new handlers.** Each handler extends `runtime_route.gd`, invokes its exact op, and retains `doc()`. Set/call/remove/reparent/create/duplicate/rename pass `mutation=true`; tree/info/get/find use false. Preserve route-specific docs and error payloads through the adapter. `create` accepts only an allowlisted node type and dedicated parent, `duplicate` accepts only a dedicated fixture source, and `rename` rejects empty, path-separator, protected, and colliding names.

- [ ] **Step 4: Add game-side node mutation validation.** In `runtime_node_ops.gd`, reject node==parent, descendant parent, root/current scene root/probe nodes, invalid path and cross-generation target before mutation; implement `create`, `duplicate`, and `rename` with fixture allowlists and rollback-on-validation-failure; return stable `invalid_param`, `permission_denied`, `not_found`, or `conflict` codes.

- [ ] **Step 5: Run GREEN.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_nodes.py -v`

  Expected: tree root is `RuntimeMain`, typed get/set/call/info/find work, create/duplicate/rename work only on dedicated fixture nodes, allowlist denial is 403/permission_denied, and all destructive operations are isolated and auditable.

- [ ] **Step 6: Check and commit.**

  Run: `git diff --check`

  Commit: `git add gdapi/addon/routes/runtime/scene/tree.gd gdapi/addon/routes/runtime/node/info.gd gdapi/addon/routes/runtime/node/get.gd gdapi/addon/routes/runtime/node/set.gd gdapi/addon/routes/runtime/node/call.gd gdapi/addon/routes/runtime/node/find.gd gdapi/addon/routes/runtime/node/remove.gd gdapi/addon/routes/runtime/node/reparent.gd gdapi/addon/routes/runtime/node/create.gd gdapi/addon/routes/runtime/node/duplicate.gd gdapi/addon/routes/runtime/node/rename.gd gdapi/addon/runtime/runtime_node_ops.gd tests/e2e/m3/test_runtime_nodes.py tests/e2e/m3/test_m3_contract.py tests/e2e/m3/conftest.py tests/fixture_project/tests/test_runtime_route.gd; git commit -m "feat(m3): complete runtime node route family"`

  Stop if any node route still reads editor SceneTree or if a failed reparent mutates the tree.

### Task 10: Add fixture reset and enable one shared data-plane game

**Files:**
- Modify: `tests/fixtures/m3_project/scripts/runtime_main.gd`
- Modify: `tests/fixtures/m3_project/scripts/probe_target.gd`
- Modify: `tests/fixtures/m3_project/scripts/probe_input.gd`
- Modify: `tests/fixtures/m3_project/scripts/probe_input_action.gd`
- Modify: `tests/fixtures/m3_project/scripts/probe_finished_signal.gd`
- Modify: `gdapi/addon/runtime/runtime_probe.gd`
- Modify: `tests/e2e/m3/conftest.py`
- Modify: `tests/e2e/m3/test_runtime_nodes.py`
- Modify: `tests/e2e/m3/test_runtime_observability.py`
- Modify: `tests/e2e/m3/test_runtime_input.py`

**Interfaces:**
- Produces: allowlisted `runtime/fixture/reset` internal operation or fixture-only reset hook returning `{ok:true, changed:true, undoable:false}`, plus `reset_fixture(env)` that restores properties, counters, dedicated nodes, signal connections, timers and ring logs.
- Consumes: successful `runtime/node/call` vertical slice and game-side probe dispatch.

- [ ] **Step 1: Add RED shared-state test.** Mutate counter/input/log/node state in one test, call `reset_fixture()`, and assert all baseline values and no stale timer/signal connection remain in the next test.

- [ ] **Step 2: Run RED.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_nodes.py tests/e2e/m3/test_runtime_input.py tests/e2e/m3/test_runtime_observability.py -v`

  Expected: no reset contract exists and shared game state leaks or requires a restart.

- [ ] **Step 3: Implement reset only in the fixture allowlist.** Add a probe-dispatched reset operation that targets known fixture nodes and does not expose arbitrary reset/eval. Stop/clear timers and temporary connections, restore `spawn_position`, `counter`, input counts, action edge state, dedicated reparent nodes, and ring buffer.

- [ ] **Step 4: Switch harness scope.** Start one data-plane game after lifecycle scenario; before every test call reset and, on reset failure, preserve failure diagnostics and restart the game with an explicit recovery marker.

- [ ] **Step 5: Run GREEN and count processes.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_nodes.py tests/e2e/m3/test_runtime_input.py tests/e2e/m3/test_runtime_observability.py -v --durations=20`

  Expected: scene/node/input/observability tests share one game after reset, with no silent recovery and game starts at or below the three-process budget.

- [ ] **Step 6: Check and commit.**

  Run: `git diff --check`

  Commit: `git add tests/fixtures/m3_project/scripts/runtime_main.gd tests/fixtures/m3_project/scripts/probe_target.gd tests/fixtures/m3_project/scripts/probe_input.gd tests/fixtures/m3_project/scripts/probe_input_action.gd tests/fixtures/m3_project/scripts/probe_finished_signal.gd gdapi/addon/runtime/runtime_probe.gd tests/e2e/m3/conftest.py tests/e2e/m3/test_runtime_nodes.py tests/e2e/m3/test_runtime_observability.py tests/e2e/m3/test_runtime_input.py; git commit -m "test(m3): reset and reuse the data-plane fixture"`

  Stop if reset can touch arbitrary nodes, if recovery hides the original assertion, or if shared execution depends on test order.

### Task 11: Migrate and validate the input route family

**Files:**
- Modify: `gdapi/addon/routes/runtime/input/key.gd`
- Modify: `gdapi/addon/routes/runtime/input/mouse.gd`
- Modify: `gdapi/addon/routes/runtime/input/gamepad.gd`
- Modify: `gdapi/addon/routes/runtime/input/touch.gd`
- Modify: `gdapi/addon/routes/runtime/input/action.gd`
- Modify: `gdapi/addon/routes/runtime/input/sequence.gd`
- Modify: `gdapi/addon/runtime/runtime_input_ops.gd`
- Modify: `tests/fixtures/m3_project/scripts/probe_input_action.gd`
- Modify: `tests/e2e/m3/test_runtime_input.py`

**Interfaces:**
- Produces: six adapter-backed input routes; `_process()` edge polling that increments action count once per false→true transition and permits the next press after release.

- [ ] **Step 1: Add RED behavior/bounds assertions.** Assert all counters increment in game process, invalid key/mouse/action/sequence params map correctly, 101 events and >10s total duration reject, and repeated polling does not double-count one press.

- [ ] **Step 2: Run RED.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_input.py -v`

  Expected: data routes use editor-local ops and action fixture relies on `_input()` behavior that synthetic `Input.action_press()` does not reliably emit.

- [ ] **Step 3: Migrate handlers and fix observation.** Extend the adapter in all six files, mark all as mutation, retain validation in game-side `runtime_input_ops.gd`, and implement action edge polling with a stored previous state.

- [ ] **Step 4: Run GREEN.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_input.py -v`

  Expected: counters and action counts are deterministic, bounds reject without mutation, and audit entries contain redacted summaries.

- [ ] **Step 5: Check and commit.**

  Run: `git diff --check`

  Commit: `git add gdapi/addon/routes/runtime/input/key.gd gdapi/addon/routes/runtime/input/mouse.gd gdapi/addon/routes/runtime/input/gamepad.gd gdapi/addon/routes/runtime/input/touch.gd gdapi/addon/routes/runtime/input/action.gd gdapi/addon/routes/runtime/input/sequence.gd gdapi/addon/runtime/runtime_input_ops.gd tests/fixtures/m3_project/scripts/probe_input_action.gd tests/e2e/m3/test_runtime_input.py; git commit -m "feat(m3): route input simulation through runtime probe"`

  Stop if a single pressed action increments twice, sequence bounds are enforced only in the editor, or an invalid event is audited as successful.

### Task 12: Migrate the capture route family and enforce image/frame bounds

**Files:**
- Modify: `gdapi/addon/routes/runtime/screenshot/viewport.gd`
- Modify: `gdapi/addon/routes/runtime/screenshot/camera.gd`
- Modify: `gdapi/addon/routes/runtime/screenshot/frames.gd`
- Modify: `gdapi/addon/runtime/runtime_capture_ops.gd`
- Modify: `tests/e2e/m3/test_runtime_capture.py`
- Modify: `tests/fixture_project/tests/test_runtime_route.gd`

**Interfaces:**
- Produces: adapter-backed viewport/camera/frames routes; game-process PNG capture with width/height and SHA-256; max 1920×1080 enforced before CPU readback (oversized sources return `invalid_param`), 60 frames, 4 MiB encoded reply.

- [ ] **Step 1: Add RED tests.** Assert valid viewport PNG signature/hash, invalid camera node returns `invalid_param`, count 61 is rejected before capture, and frames waits/resumes through file transport.

- [ ] **Step 2: Run RED.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_capture.py -v`

  Expected: current routes cannot resolve game viewport/camera and async frames has no closed file-transport lifecycle.

- [ ] **Step 3: Migrate and bound.** Replace each local `load` with adapter dispatch; validate dimensions/count/interval in route and probe; summarize base64 in audit and return structured oversized-reply error rather than timeout.

- [ ] **Step 4: Run GREEN.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_capture.py -v`

  Expected: all capture assertions pass through game process and limit tests return stable 400/invalid_param.

- [ ] **Step 5: Check and commit.**

  Run: `git diff --check`

  Commit: `git add gdapi/addon/routes/runtime/screenshot/viewport.gd gdapi/addon/routes/runtime/screenshot/camera.gd gdapi/addon/routes/runtime/screenshot/frames.gd gdapi/addon/runtime/runtime_capture_ops.gd tests/e2e/m3/test_runtime_capture.py tests/fixture_project/tests/test_runtime_route.gd; git commit -m "feat(m3): route runtime captures through probe"`

  Stop if image limits are enforced after allocation only, async frames can timeout without a reply, or returned hash does not match bytes.

### Task 13: Migrate log/debug routes and close known-log/debug coverage

**Files:**
- Modify: `gdapi/addon/routes/runtime/log/read.gd`
- Modify: `gdapi/addon/routes/runtime/log/clear.gd`
- Modify: `gdapi/addon/routes/runtime/debug/performance.gd`
- Modify: `gdapi/addon/routes/runtime/debug/monitors.gd`
- Modify: `gdapi/addon/routes/runtime/debug/errors.gd`
- Modify: `gdapi/addon/routes/runtime/debug/breakpoints.gd`
- Modify: `gdapi/addon/runtime/runtime_probe.gd`
- Modify: `gdapi/addon/runtime/runtime_ring_buffer.gd`
- Modify: `tests/fixtures/m3_project/scripts/runtime_main.gd`
- Modify: `tests/e2e/m3/test_runtime_observability.py`
- Modify: `tests/fixture_project/tests/test_runtime_ring_buffer.gd`

**Interfaces:**
- Produces: game-side log read/clear, performance/monitor values, errors empty-list v1 behavior, breakpoints `not_supported`, and fixture `emit_known_logs()` calling `record_log("info", "known-info")` and `record_log("error", "known-error")`.

- [ ] **Step 1: Add RED tests.** Cover initial empty read, known-info/known-error incremental cursor, clear, no duplicate pages, monitor keys, errors empty list, breakpoints not_supported, ring-buffer empty/eviction/partial/clear behavior, and dropped formula `max(0, oldest - (after_cursor + 1))`.

- [ ] **Step 2: Run RED.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k runtime_ring_buffer -v; GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_observability.py -v`

  Expected: known logs are only printed, data routes read the wrong process, and empty/dropped cases expose the current ring-buffer defect.

- [ ] **Step 3: Implement.** Migrate six handlers through adapter, mark `log/clear` mutation, fix ring buffer without indexing empty `_items`, make known logs explicit `record_log`, and preserve v1 debug errors/breakpoints contracts.

- [ ] **Step 4: Run GREEN.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k runtime_ring_buffer -v; GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_observability.py -v`

  Expected: cursor pages have no duplicate, dropped is exact, known logs are returned from game process, and debug error/breakpoint tests pass.

- [ ] **Step 5: Check and commit.**

  Run: `git diff --check`

  Commit: `git add gdapi/addon/routes/runtime/log/read.gd gdapi/addon/routes/runtime/log/clear.gd gdapi/addon/routes/runtime/debug/performance.gd gdapi/addon/routes/runtime/debug/monitors.gd gdapi/addon/routes/runtime/debug/errors.gd gdapi/addon/routes/runtime/debug/breakpoints.gd gdapi/addon/runtime/runtime_probe.gd gdapi/addon/runtime/runtime_ring_buffer.gd tests/fixtures/m3_project/scripts/runtime_main.gd tests/e2e/m3/test_runtime_observability.py tests/fixture_project/tests/test_runtime_ring_buffer.gd; git commit -m "fix(m3): close runtime log and debug observability"`

  Stop if log clear can erase another generation, cursor reads duplicate entries, or debug stubs are reported as successful mutation.

### Task 14: Migrate assert/signal routes and verify async suspend/resume

**Files:**
- Modify: `gdapi/addon/routes/runtime/assert/condition.gd`
- Modify: `gdapi/addon/routes/runtime/assert/node_exists.gd`
- Modify: `gdapi/addon/routes/runtime/assert/property_equals.gd`
- Modify: `gdapi/addon/routes/runtime/assert/signal_received.gd`
- Modify: `gdapi/addon/routes/runtime/signal/connect.gd`
- Modify: `gdapi/addon/routes/runtime/signal/disconnect.gd`
- Modify: `gdapi/addon/routes/runtime/signal/emit.gd`
- Modify: `gdapi/addon/routes/runtime/signal/await.gd`
- Modify: `gdapi/addon/runtime/runtime_condition.gd`
- Modify: `gdapi/addon/runtime/runtime_node_ops.gd`
- Modify: `tests/fixtures/m3_project/scripts/probe_finished_signal.gd`
- Modify: `tests/e2e/m3/test_runtime_assert_signal.py`

**Interfaces:**
- Produces: adapter-backed async assert/signal routes; `condition` conflict→409, signal timeout→408, temporary signal connections/timers cleaned on success, timeout, disconnect and reset.

- [ ] **Step 1: Add RED async tests.** Start a condition/signal await, mutate/emit from a second real CLI process, assert success after suspension; assert timeout code/status, signal_received behavior, and disconnect during await completes exactly once with conflict.

- [ ] **Step 2: Run RED.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_assert_signal.py -v`

  Expected: current editor-side route cannot see the game node/signal and file scanner cannot await to completion reliably.

- [ ] **Step 3: Migrate handlers and clean async resources.** Extend adapter in all eight files; keep `assert` non-mutation and signal connect/disconnect/emit mutation; ensure `runtime_condition` and signal await use operation timeout and disconnect cleanup in `finally`-equivalent paths.

- [ ] **Step 4: Run GREEN.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_assert_signal.py -v`

  Expected: all async success/timeout/disconnect tests pass and no temporary signal/timer remains after reset.

- [ ] **Step 5: Check and commit.**

  Run: `git diff --check`

  Commit: `git add gdapi/addon/routes/runtime/assert/condition.gd gdapi/addon/routes/runtime/assert/node_exists.gd gdapi/addon/routes/runtime/assert/property_equals.gd gdapi/addon/routes/runtime/assert/signal_received.gd gdapi/addon/routes/runtime/signal/connect.gd gdapi/addon/routes/runtime/signal/disconnect.gd gdapi/addon/routes/runtime/signal/emit.gd gdapi/addon/routes/runtime/signal/await.gd gdapi/addon/runtime/runtime_condition.gd gdapi/addon/runtime/runtime_node_ops.gd tests/fixtures/m3_project/scripts/probe_finished_signal.gd tests/e2e/m3/test_runtime_assert_signal.py; git commit -m "feat(m3): route assertions and signals through probe"`

  Stop if timeout/disconnect can invoke a callback twice or leave a signal connection/timer in the shared game.

### Task 15: Close D2/D3/D4/D7 and route-wide safety contracts

**Files:**
- Modify: `gdapi/addon/runtime/runtime_ring_buffer.gd`
- Modify: `gdapi/addon/runtime/runtime_probe.gd`
- Modify: `gdapi/addon/runtime/runtime_node_ops.gd`
- Modify: `gdapi/addon/runtime/runtime_input_ops.gd`
- Modify: `tests/fixture_project/tests/test_runtime_ring_buffer.gd`
- Create: `tests/fixture_project/tests/test_runtime_reparent.gd`
- Modify: `tests/e2e/test_gdscript_units.py`
- Modify: `tests/fixtures/m3_project/scripts/runtime_main.gd`
- Modify: `tests/fixtures/m3_project/scripts/probe_input_action.gd`
- Modify: `tests/e2e/m3/test_runtime_nodes.py`
- Modify: `tests/e2e/m3/test_runtime_input.py`
- Modify: `tests/e2e/m3/test_runtime_observability.py`

**Interfaces:**
- Produces: closure-plan D2 dropped accounting, D3 known logs, D4 reparent cycle tests, D7 stable action observation; all are directly observable through unit or real CLI tests.

- [ ] **Step 1: Add RED closure assertions.** Add exact tests for cursor 0 eviction, partial eviction, empty read, clear, two-page no-repeat; known log records; node==descendant/root protection; and one action increment per press edge.

- [ ] **Step 2: Run RED.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_ring_buffer" -v; GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_nodes.py tests/e2e/m3/test_runtime_input.py tests/e2e/m3/test_runtime_observability.py -v`

  Expected: at least one closure assertion fails on the pre-existing defect; if not, inspect that the new test actually forces eviction/edge transition before proceeding.

- [ ] **Step 3: Implement the four defects.** Correct the formula and empty read, call `record_log` for known logs, reject cycles before tree mutation, and use edge polling rather than relying on `_input()` synthetic propagation.

- [ ] **Step 4: Run GREEN.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_ring_buffer" -v; GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3/test_runtime_nodes.py tests/e2e/m3/test_runtime_input.py tests/e2e/m3/test_runtime_observability.py -v`

  Expected: every closure assertion passes and failed mutations leave the fixture unchanged.

- [ ] **Step 5: Check and commit.**

  Run: `git diff --check`

  Commit: `git add gdapi/addon/runtime/runtime_ring_buffer.gd gdapi/addon/runtime/runtime_probe.gd gdapi/addon/runtime/runtime_node_ops.gd gdapi/addon/runtime/runtime_input_ops.gd tests/fixture_project/tests/test_runtime_ring_buffer.gd tests/fixture_project/tests/test_runtime_reparent.gd tests/e2e/test_gdscript_units.py tests/fixtures/m3_project/scripts/runtime_main.gd tests/fixtures/m3_project/scripts/probe_input_action.gd tests/e2e/m3/test_runtime_nodes.py tests/e2e/m3/test_runtime_input.py tests/e2e/m3/test_runtime_observability.py; git commit -m "fix(m3): close runtime closure defects"`

  Stop if any safety test is green only because a route failed before reaching the game process.

### Task 16: Enforce audit/redaction/bounds/disconnect/exactly-once across all 34 routes

**Files:**
- Modify: `gdapi/addon/runtime/runtime_route.gd`
- Modify: `gdapi/addon/runtime/runtime_broker.gd`
- Modify: `gdapi/addon/runtime/runtime_protocol.gd`
- Modify: `gdapi/addon/runtime/runtime_probe.gd`
- Modify: `gdapi/addon/runtime/runtime_transport_file_editor.gd`
- Modify: `gdapi/addon/runtime/runtime_transport_file_probe.gd`
- Modify: `gdapi/addon/runtime/audit_log.gd`
- Modify: `tests/fixture_project/tests/test_runtime_route.gd`
- Modify: `tests/fixture_project/tests/test_runtime_broker.gd`
- Modify: `tests/e2e/m3/test_runtime_observability.py`
- Modify: `tests/e2e/m3/test_runtime_capture.py`
- Modify: `tests/e2e/m3/test_runtime_input.py`
- Modify: `tests/e2e/m3/test_runtime_assert_signal.py`
- Modify: `tests/e2e/m3/test_m3_contract.py`

**Interfaces:**
- Produces: route-wide audit events with redacted token/password/secret/authorization/cookie, summarized base64/large arrays/large Variant values, stable bound errors, exactly-once timeout/disconnect behavior, and zero pending after completion.

- [ ] **Step 1: Add RED cross-cutting tests.** Send oversized request/reply fixtures, operation timeout at 25s, sequence/frame bound violations, disconnect during call/sequence/await, duplicate replies, and secret-bearing mutation payloads. Query `gdapi/audit/list` and assert no forbidden key/value is present.

- [ ] **Step 2: Run RED.**

  Run: `uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_route or runtime_broker" -v; GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3 -v`

  Expected: oversized messages may timeout, mutation audit is incomplete/unredacted, and some late/disconnect paths can complete more than once.

- [ ] **Step 3: Implement the cross-cutting checks.** Apply bounds at route, broker and probe; apply HTTP code map centrally; snapshot-and-erase pending before callback on every completion path; redact recursively before audit; summarize binary/large values; reject generation mismatch before dispatch.

- [ ] **Step 4: Run GREEN.**

  Run: `GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe' uv run pytest tests/e2e/m3 -v`

  Expected: all cross-cutting tests pass and audit entries show success/rejection with no secrets or full binary payloads.

- [ ] **Step 5: Check and commit.**

  Run: `git diff --check`

  Commit: `git add gdapi/addon/runtime/runtime_route.gd gdapi/addon/runtime/runtime_broker.gd gdapi/addon/runtime/runtime_protocol.gd gdapi/addon/runtime/runtime_probe.gd gdapi/addon/runtime/runtime_transport_file_editor.gd gdapi/addon/runtime/runtime_transport_file_probe.gd gdapi/addon/runtime/audit_log.gd tests/fixture_project/tests/test_runtime_route.gd tests/fixture_project/tests/test_runtime_broker.gd tests/e2e/m3/test_runtime_observability.py tests/e2e/m3/test_runtime_capture.py tests/e2e/m3/test_runtime_input.py tests/e2e/m3/test_runtime_assert_signal.py tests/e2e/m3/test_m3_contract.py; git commit -m "fix(m3): enforce runtime safety and exactly-once semantics"`

  Stop if any oversized or stale message becomes a silent timeout, any secret appears in audit output, or pending is nonzero after suite cleanup.

### Task 17: Run full regression, collect durations, and close the milestone

**Files:**
- Modify: `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`
- Create: `docs/reports/2026-07-29-gdcli-m3-runtime-remediation-closure.md`
- Do not modify: handoff-owned user files listed in Global Constraints.

**Interfaces:**
- Produces: reproducible acceptance report with commands, exit codes, test counts, selected transport, editor/game process counts, `--durations=20`, final pending/stale-root checks, and roadmap M3 marked ✅ only after every criterion passes.

- [ ] **Step 1: Run the complete verification matrix.**

  Run exactly:

  ```text
  cargo fmt --check
  cargo clippy --workspace
  cargo test --workspace
  $env:GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe'; uv run pytest tests/e2e/test_gdscript_units.py -v
  $env:GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe'; uv run pytest tests/e2e/m3 -v --durations=20
  $env:GODOT_BIN='D:\\app\\devel\\Godot\\v4.7.1\\godot_console.exe'; uv run pytest tests/e2e/ -v
  git diff --check
  ```

- [ ] **Step 2: Verify acceptance criteria.** Confirm 35 routes exactly, 34 broker-dispatched data routes, valid behavior plus negative/mutation/async tests, EngineDebugger priority and file fallback, all bounds, audit/redaction, two lifecycle cycles, pending zero, no stale probe/game/timer/signal, all tool/test exits zero, local M3 warm-build ≤60 s and CI evidence ≤120 s.

- [ ] **Step 3: Write the closure report.** Record the exact date, commit range, commands and exit codes, test totals, transport (`file` in headless; EngineDebugger unit/priority evidence), process counts, durations, and any recovery count. Do not claim success for a test that was skipped or weakened.

- [ ] **Step 4: Update the roadmap.** Change only the M3 status text and evidence links from 🟡 to ✅ after the report proves all criteria. Keep M4 and unrelated roadmap statuses unchanged.

- [ ] **Step 5: Run final diff and commit.**

  Run: `git diff --check; git status --short`

  Commit: `git add docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md docs/reports/2026-07-29-gdcli-m3-runtime-remediation-closure.md tests/e2e/m3 tests/e2e/conftest.py; git commit -m "docs(m3): close runtime remediation milestone"`

  Stop and leave M3 🟡 if any acceptance criterion, performance budget, full-suite command, or cleanup check is not green.

## Plan Self-Review

- Coverage: Tasks 1–5 cover broker/file sync and async ownership, debugger registration/priority, generation and stale cleanup; Tasks 6–7 provide the adapter and vertical slice; Tasks 8–10 cover the harness and shared fixture; Tasks 11–14 migrate every route family; Tasks 15–16 cover D2/D3/D4/D7, bounds, audit, disconnect and exactly-once; Task 17 covers regression, performance and roadmap closure.
- Route count: after Task 9 the groups total 35 (`status` + `scene/tree` + 10 node + 6 input + 3 screenshot + 2 log + 4 assert + 4 signal + 4 debug); exactly 34 are broker-dispatched data-plane routes.
- Placeholder scan: no task depends on an unspecified file, route, command, or “similar” implementation; the only conditional file is explicitly constrained to the existing fixture layout and cannot be committed as dead code.
- Interface consistency: all migrated routes call `GdApiRuntimeRoute.dispatch`; broker remains the only owner of ids/pending/deadlines; file editor transport only calls `broker.receive`; probe owns async inflight; harness calls the fixture-only `reset_fixture` only after the node/call vertical slice is green.
- Scope: no task changes CLI behavior, protocol version, transport types, M4 systems, or the user-owned working-tree changes.
