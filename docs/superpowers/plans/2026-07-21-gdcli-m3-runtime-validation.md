# gdcli M3 Runtime Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deterministic editor-to-game probe that lets gdcli inspect, stimulate, capture, and assert the running fixture without exposing arbitrary evaluation.

**Architecture:** A transport-neutral editor broker owns request IDs, connection state, deadlines, and pending callbacks. Its first transport is Godot's native `EditorDebuggerPlugin`/`EngineDebugger` message channel; a runtime autoload dispatches allowlisted operations and returns structured replies. HTTP route handlers remain asynchronous response adapters and never depend directly on debugger session APIs.

**Tech Stack:** Godot 4.7 `EditorDebuggerPlugin`, `EditorDebuggerSession`, `EngineDebugger`, GDScript autoload, M1 response/audit contracts, pytest/uv.

## Global Constraints

- Support only Godot 4.7.x and require completed M1 and M2 plans.
- Keep `project/run` and `project/stop` as the public game lifecycle controls.
- Runtime transport and protocol are separate: public routes call `GdApiRuntimeBroker`, never `EditorDebuggerSession` directly.
- Runtime mutations are never UndoRedo-capable and return `undoable:false`.
- Every request has an integer ID, deadline, bounded payload, and exactly one completion.
- Disconnect, game stop, timeout, and editor shutdown fail every pending request and clear retained callbacks.
- No arbitrary expression execution belongs in M3; conditions use a fixed JSON predicate grammar.
- Cap one response at 4 MiB, screenshots at 1920x1080, frame capture at 60 frames, and default timeout at 5,000 ms.
- Runtime log/error reads are cursor-based and return no duplicate records.
- Input and runtime mutations are audited with secrets removed.

## File Structure

| File | Responsibility after M3 |
|---|---|
| `gdapi/addon/runtime/runtime_protocol.gd` | Protocol version, operation names, validation, and reply constructors |
| `gdapi/addon/runtime/runtime_broker.gd` | Connection state, request IDs, pending callbacks, timeout/disconnect cleanup |
| `gdapi/addon/runtime/runtime_debugger_plugin.gd` | Native editor debugger transport adapter |
| `gdapi/addon/runtime/runtime_probe.gd` | Game autoload and allowlisted operation dispatcher |
| `gdapi/addon/runtime/runtime_condition.gd` | Safe condition grammar evaluator |
| `gdapi/addon/runtime/runtime_ring_buffer.gd` | Cursor-based bounded log/error/event storage |
| `gdapi/addon/plugin.gd` | Register debugger plugin and runtime autoload |
| `gdapi/addon/routes/runtime/**/*.gd` | Public runtime route adapters |
| `tests/fixtures/m3_project/**` | Observable running-game fixture |
| `tests/e2e/m3/**` | Runtime lifecycle and operation acceptance tests |

---

### Task 1: Define and Unit-Test the Runtime Protocol

**Files:**
- Create: `gdapi/addon/runtime/runtime_protocol.gd`
- Create: `tests/fixture_project/tests/test_runtime_protocol.gd`
- Modify: `tests/e2e/test_gdscript_units.py`

**Interfaces:**
- Produces `GdApiRuntimeProtocol.VERSION = 1`.
- Produces `request(id:int, op:String, payload:Dictionary) -> Dictionary` and `validate_message(message:Dictionary) -> Dictionary`.
- Message shapes are request `{version,id,kind:"request",op,payload}` and reply `{version,id,kind:"reply",ok,result?,error?,code?}`.

- [ ] **Step 1: Write protocol validation tests**

```gdscript
func _init() -> void:
	var request := Protocol.request(7, "runtime/status", {})
	assert_eq(request, {"version":1,"id":7,"kind":"request","op":"runtime/status","payload":{}})
	assert_true(Protocol.validate_message(request).ok, "valid request")
	assert_eq(Protocol.validate_message({"version":2}).code, "not_supported")
	assert_eq(Protocol.validate_message({"version":1,"id":"7"}).code, "invalid_param")
	assert_eq(Protocol.validate_message({"version":1,"id":7,"kind":"request","op":"eval","payload":{}}).code, "permission_denied")
	quit(1 if failed else 0)
```

- [ ] **Step 2: Run the GDScript unit**

Run: `uv run pytest tests/e2e/test_gdscript_units.py -v -k runtime_protocol`

Expected: FAIL because `runtime_protocol.gd` does not exist.

- [ ] **Step 3: Implement exact protocol validation**

```gdscript
@tool
class_name GdApiRuntimeProtocol
extends RefCounted

const VERSION := 1
const MAX_MESSAGE_BYTES := 4 * 1024 * 1024

static func request(id: int, op: String, payload: Dictionary) -> Dictionary:
	return {"version": VERSION, "id": id, "kind": "request", "op": op, "payload": payload}

static func validate_message(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return _error("invalid_param", "runtime message must be an object")
	if value.get("version") != VERSION:
		return _error("not_supported", "runtime protocol version is unsupported")
	if typeof(value.get("id")) != TYPE_INT or int(value.id) < 1:
		return _error("invalid_param", "runtime message id must be a positive integer")
	if value.get("kind") not in ["request", "reply", "event"]:
		return _error("invalid_param", "runtime message kind is invalid")
	if value.kind == "request" and (typeof(value.get("op")) != TYPE_STRING or value.op.is_empty()):
		return _error("invalid_param", "runtime request op is required")
	if value.get("op") in ["eval", "process/run", "network/http_request"]:
		return _error("permission_denied", "operation is unavailable in runtime protocol v1")
	if JSON.stringify(value).to_utf8_buffer().size() > MAX_MESSAGE_BYTES:
		return _error("invalid_param", "runtime message exceeds 4 MiB")
	return {"ok": true}

static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
```

- [ ] **Step 4: Verify protocol units**

Run: `uv run pytest tests/e2e/test_gdscript_units.py -v -k runtime_protocol`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/runtime_protocol.gd tests/fixture_project/tests/test_runtime_protocol.gd tests/e2e/test_gdscript_units.py
git commit -m "feat: define runtime probe protocol"
```

---

### Task 2: Implement Broker Lifecycle and Native Debugger Transport

**Files:**
- Create: `gdapi/addon/runtime/runtime_broker.gd`
- Create: `gdapi/addon/runtime/runtime_debugger_plugin.gd`
- Create: `gdapi/addon/runtime/runtime_probe.gd`
- Modify: `gdapi/addon/plugin.gd`
- Modify: `gdapi/addon/routes/project/run.gd`
- Modify: `gdapi/addon/routes/project/stop.gd`
- Create: `tests/fixtures/m3_project/project.godot`
- Create: `tests/e2e/m3/conftest.py`
- Create: `tests/fixture_project/tests/test_runtime_broker.gd`
- Create: `tests/e2e/m3/test_runtime_status.py`

**Interfaces:**
- Produces `request(op:String,payload:Dictionary,timeout_ms:int,on_complete:Callable) -> int`.
- Produces `GdApiRuntimeBroker.instance() -> GdApiRuntimeBroker`, resolved from Engine metadata or `null` before plugin initialization.
- Produces states `stopped`, `connecting`, `connected`; `status() -> {state,protocol_version,session_id,pending}`.
- Transport calls `broker.attach(session_id, send:Callable)`, `broker.receive(message)`, and `broker.detach(reason)`.
- Produces pytest fixtures `m3_editor`, `m3_running`, `wait_for(predicate,timeout)`, `wait_connected(env)`, `wait_stopped(env)`, `runtime_counter(env,name)`, `start_exec(env,route,data) -> Future`, and positional `command_doc(env,route)`.

- [ ] **Step 1: Write broker cleanup and public status tests**

```gdscript
func test_disconnect_completes_pending() -> void:
	var replies: Array = []
	broker.attach(3, func(_message): pass)
	broker.request("runtime/status", {}, 5000, func(reply): replies.append(reply))
	broker.detach("game stopped")
	assert_eq(replies.size(), 1)
	assert_eq(replies[0].code, "conflict")
	assert_eq(broker.status().pending, 0)
```

```python
def test_runtime_status_transitions(m3_editor):
    assert exec_ok(m3_editor, "runtime/status")["state"] == "stopped"
    exec_ok(m3_editor, "project/run")
    wait_for(lambda: exec_ok(m3_editor, "runtime/status")["state"] == "connecting", timeout=2)
    wait_for(lambda: exec_ok(m3_editor, "runtime/status")["state"] == "connected", timeout=15)
    assert exec_ok(m3_editor, "runtime/status")["protocol_version"] == 1
    exec_ok(m3_editor, "project/stop")
    wait_for(lambda: exec_ok(m3_editor, "runtime/status")["state"] == "stopped", timeout=10)
```

- [ ] **Step 2: Run unit and E2E tests**

Run: `uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/m3/test_runtime_status.py -v -k "runtime_broker or runtime_status"`

Expected: FAIL because broker, transport, and status route are absent.

- [ ] **Step 3: Implement callback broker and debugger adapter**

Pending entries use `{deadline_msec, callback, op}`. `_process()` removes expired entries before invoking callbacks with `{ok:false,code:"timeout",error:"runtime request timed out"}`. `detach()` moves all callbacks to a local array, clears the dictionary, then invokes them so reentrant callbacks cannot observe stale pending requests.

Expose the plugin-owned broker without a second singleton:

```gdscript
static func instance():
	if Engine.has_meta("gdapi_runtime_broker"):
		return Engine.get_meta("gdapi_runtime_broker")
	return null
```

The debugger adapter extends `EditorDebuggerPlugin`, returns `true` from `_has_capture("gdapi")`, receives `gdapi:reply`/`gdapi:event` in `_capture`, and sends arrays containing one protocol dictionary through the active `EditorDebuggerSession.send_message("gdapi:request", [message])`. The runtime autoload registers `EngineDebugger.register_message_capture("gdapi", _capture)` and sends `gdapi:hello` at `_ready()`.

Register both in `plugin.gd`:

```gdscript
_runtime_broker = RuntimeBroker.new()
_runtime_debugger = RuntimeDebuggerPlugin.new(_runtime_broker)
add_debugger_plugin(_runtime_debugger)
add_autoload_singleton("GdApiRuntimeProbe", "res://addons/gdapi/runtime/runtime_probe.gd")
Engine.set_meta("gdapi_runtime_broker", _runtime_broker)
```

Remove the debugger plugin, autoload, and Engine metadata in reverse order on plugin exit.

Before `project/run` starts the game, call `broker.begin_connect()` so status becomes `connecting`; if editor play fails, call `detach("game failed to start")`. After `project/stop` stops play, call `detach("game stopped")` even if the debugger session has already emitted its stop callback. `detach` is idempotent.

Build `m3_editor` by copying `tests/fixtures/m3_project`, installing gdapi, starting the Godot 4.7 headless editor, and yielding the same route helpers as M2. Set fixture-only project setting `gdapi/runtime_probe_hello_delay_ms=250`; the probe waits that many milliseconds before hello so the E2E can deterministically observe `connecting`, while production projects default to zero. `m3_running` calls `project/run`, waits for `connected`, yields, then calls `project/stop` and asserts `pending == 0`. `runtime_counter` delegates to `runtime/node/get` on `/root/RuntimeMain/InputState`.

- [ ] **Step 4: Verify connect/stop/reconnect and pending cleanup**

Run: `uv run pytest tests/e2e/m3/test_runtime_status.py tests/e2e/test_gdscript_units.py -v -k runtime`

Expected: PASS for two consecutive run/stop cycles with pending count returning to zero.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/runtime_broker.gd gdapi/addon/runtime/runtime_debugger_plugin.gd gdapi/addon/runtime/runtime_probe.gd gdapi/addon/plugin.gd gdapi/addon/routes/runtime/status.gd gdapi/addon/routes/project/run.gd gdapi/addon/routes/project/stop.gd tests/fixtures/m3_project tests/e2e/m3 tests/fixture_project/tests/test_runtime_broker.gd
git commit -m "feat: connect runtime probe over EngineDebugger"
```

---

### Task 3: Add Runtime Scene and Node Operations

**Files:**
- Create: `gdapi/addon/runtime/runtime_node_ops.gd`
- Create: `gdapi/addon/routes/runtime/scene/tree.gd`
- Create: `gdapi/addon/routes/runtime/node/{info,get,set,call,find,remove,reparent}.gd`
- Create: `tests/fixtures/m3_project/scenes/runtime_main.tscn`
- Create: `tests/fixtures/m3_project/scripts/runtime_main.gd`
- Create: `tests/e2e/m3/test_runtime_nodes.py`

**Interfaces:**
- Routes delegate with operation strings equal to their public paths.
- Node selectors accept an absolute runtime `node_path`; `find` accepts `{name?,type?,group?,limit?}`.
- Calls require an allowlisted method published by fixture metadata `gdapi_callable_methods`.

- [ ] **Step 1: Write exact tree, typed property, call, and safety tests**

```python
def test_runtime_tree_get_set_call(m3_running):
    tree = exec_ok(m3_running, "runtime/scene/tree", {"max_depth": 3})
    assert tree["root"]["name"] == "RuntimeMain"
    path = "/root/RuntimeMain/ProbeTarget"
    assert exec_ok(m3_running, "runtime/node/get", {
        "node_path": path, "property": "position"
    })["value"] == {"type": "Vector2", "value": [10.0, 20.0]}
    changed = exec_ok(m3_running, "runtime/node/set", {
        "node_path": path, "property": "position",
        "value": {"type": "Vector2", "value": [30, 40]}
    })
    assert changed["undoable"] is False
    assert exec_ok(m3_running, "runtime/node/call", {
        "node_path": path, "method": "increment", "args": [2]
    })["result"] == 2


def test_runtime_call_allowlist(m3_running):
    error = exec_error(m3_running, "runtime/node/call", {
        "node_path": "/root/RuntimeMain/ProbeTarget", "method": "queue_free"
    })
    assert error["code"] == "permission_denied"
```

- [ ] **Step 2: Run tests and verify operation-not-found replies**

Run: `uv run pytest tests/e2e/m3/test_runtime_nodes.py -v`

Expected: FAIL with `not_supported` from the probe dispatcher.

- [ ] **Step 3: Implement allowlisted runtime node dispatcher**

Resolve with `get_tree().root.get_node_or_null(NodePath(path))`. Reject properties absent from `get_property_list()` and decode values before set. Encode all result values. `remove` rejects `/root`, current scene root, and probe autoload. `reparent` rejects cycles. `call` permits only methods listed by the target's `get_meta("gdapi_callable_methods", PackedStringArray())`.

Every adapter uses:

```gdscript
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	GdApiRuntimeBroker.instance().request(
		"runtime/node/get", req.body, int(req.get_body("timeout_ms", 5000)),
		func(reply: Dictionary): GdApiRuntimeRoute.reply(res, reply)
	)
```

- [ ] **Step 4: Verify all node operations and disconnect during call**

Run: `uv run pytest tests/e2e/m3/test_runtime_nodes.py -v`

Expected: PASS; stopping during a delayed call returns `conflict` and pending becomes zero.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/runtime_node_ops.gd gdapi/addon/routes/runtime/scene gdapi/addon/routes/runtime/node tests/fixtures/m3_project tests/e2e/m3/test_runtime_nodes.py
git commit -m "feat: add runtime scene and node inspection"
```

---

### Task 4: Add Bounded Runtime Input Simulation

**Files:**
- Create: `gdapi/addon/runtime/runtime_input_ops.gd`
- Create: `gdapi/addon/routes/runtime/input/{key,mouse,gamepad,touch,action,sequence}.gd`
- Create: `tests/e2e/m3/test_runtime_input.py`

**Interfaces:**
- Produces routes `runtime/input/key`, `runtime/input/mouse`, `runtime/input/gamepad`, `runtime/input/touch`, `runtime/input/action`, and `runtime/input/sequence`.
- Single input routes return `{ok,changed:true,undoable:false,event_type}`.
- Sequence consumes `{events:Array[{after_ms,route,data}],timeout_ms?}` with at most 100 events and total duration at most 10,000 ms.
- Key codes use Godot 4.7 integer keycodes; mouse coordinates are viewport-local Vector2 arrays.

- [ ] **Step 1: Write observable-state tests for every input family**

```python
@pytest.mark.parametrize("route,data,counter", [
    ("runtime/input/key", {"keycode": 32, "pressed": True}, "keys"),
    ("runtime/input/mouse", {"kind": "button", "button": 1, "pressed": True, "position": [8, 9]}, "mouse"),
    ("runtime/input/gamepad", {"device": 0, "button": 0, "pressed": True}, "gamepad"),
    ("runtime/input/touch", {"index": 0, "pressed": True, "position": [12, 14]}, "touch"),
    ("runtime/input/action", {"action": "ui_accept", "pressed": True}, "actions"),
])
def test_input_changes_fixture_state(m3_running, route, data, counter):
    before = runtime_counter(m3_running, counter)
    exec_ok(m3_running, route, data)
    wait_for(lambda: runtime_counter(m3_running, counter) == before + 1)
```

Add the exact rejection matrix plus disconnect case:

```python
@pytest.mark.parametrize("route,data", [
    ("runtime/input/action", {"action":"missing","pressed":True}),
    ("runtime/input/mouse", {"kind":"button","button":99,"pressed":True,"position":[0,0]}),
    ("runtime/input/sequence", {"events":[{"after_ms":0,"route":"runtime/input/action","data":{"action":"ui_accept","pressed":True}}] * 101}),
    ("runtime/input/sequence", {"events":[{"after_ms":-1,"route":"runtime/input/action","data":{"action":"ui_accept","pressed":True}}]}),
])
def test_input_rejections(m3_running, route, data):
    assert exec_error(m3_running, route, data)["code"] == "invalid_param"


def test_sequence_disconnect_completes(m3_running):
    pending = start_exec(m3_running, "runtime/input/sequence", {
        "events":[{"after_ms":5000,"route":"runtime/input/action","data":{"action":"ui_accept","pressed":True}}]
    })
    exec_ok(m3_running, "project/stop")
    assert pending.result(timeout=2)["code"] == "conflict"
```

- [ ] **Step 2: Run the input suite**

Run: `uv run pytest tests/e2e/m3/test_runtime_input.py -v`

Expected: FAIL with `not_supported`.

- [ ] **Step 3: Construct and inject exact Godot input events**

Create the matching `InputEventKey`, `InputEventMouseButton`/`InputEventMouseMotion`, `InputEventJoypadButton`/`InputEventJoypadMotion`, and `InputEventScreenTouch`/`InputEventScreenDrag`; call `Input.parse_input_event(event)`. For actions use `Input.action_press`/`action_release`. Execute sequences through a SceneTreeTimer chain, not blocking sleeps, and complete the broker reply once.

- [ ] **Step 4: Verify input state and audit**

Run: `uv run pytest tests/e2e/m3/test_runtime_input.py -v`

Expected: PASS; every accepted/rejected input mutation has a redacted audit event.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/runtime_input_ops.gd gdapi/addon/routes/runtime/input tests/e2e/m3/test_runtime_input.py
git commit -m "feat: add runtime input simulation"
```

---

### Task 5: Add Screenshot and Frame Capture

**Files:**
- Create: `gdapi/addon/runtime/runtime_capture_ops.gd`
- Create: `gdapi/addon/routes/runtime/screenshot/{viewport,camera,frames}.gd`
- Create: `tests/e2e/m3/test_runtime_capture.py`

**Interfaces:**
- Viewport/camera responses contain `{mime:"image/png",width,height,sha256,data_base64}`.
- Frames consumes `{count:int,interval_ms:int,camera_path?}` and returns metadata plus `frames:Array`.
- Dimensions are capped at 1920x1080 and encoded response at 4 MiB.

- [ ] **Step 1: Write PNG signature and bounds tests**

```python
def test_viewport_capture_is_valid_png(m3_running):
    capture = exec_ok(m3_running, "runtime/screenshot/viewport")
    data = base64.b64decode(capture["data_base64"])
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    assert capture["width"] == 320 and capture["height"] == 180
    assert hashlib.sha256(data).hexdigest() == capture["sha256"]


def test_frame_limits(m3_running):
    error = exec_error(m3_running, "runtime/screenshot/frames", {"count": 61, "interval_ms": 1})
    assert error["code"] == "invalid_param"
```

- [ ] **Step 2: Run and see unsupported operation failures**

Run: `uv run pytest tests/e2e/m3/test_runtime_capture.py -v`

Expected: FAIL with `not_supported`.

- [ ] **Step 3: Implement capture after rendered frames**

Await `RenderingServer.frame_post_draw`, obtain `viewport.get_texture().get_image()`, resize only when above limits, and call `save_png_to_buffer()`. Camera capture resolves a `Camera2D` or `Camera3D` and its viewport; other node types return `invalid_param`. Frame capture schedules each image and aborts if projected encoded size exceeds 4 MiB.

- [ ] **Step 4: Verify deterministic metadata and cleanup**

Run: `uv run pytest tests/e2e/m3/test_runtime_capture.py -v`

Expected: PASS; failed capture leaves no pending timers or broker request.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/runtime_capture_ops.gd gdapi/addon/routes/runtime/screenshot tests/e2e/m3/test_runtime_capture.py
git commit -m "feat: capture runtime screenshots and frames"
```

---

### Task 6: Add Cursor-Based Runtime Logs, Errors, and Debug Metrics

**Files:**
- Create: `gdapi/addon/runtime/runtime_ring_buffer.gd`
- Create: `gdapi/addon/routes/runtime/log/{read,clear}.gd`
- Create: `gdapi/addon/routes/runtime/debug/{performance,monitors,errors,breakpoints}.gd`
- Create: `tests/fixture_project/tests/test_runtime_ring_buffer.gd`
- Create: `tests/e2e/m3/test_runtime_observability.py`

**Interfaces:**
- Produces routes `runtime/log/read`, `runtime/log/clear`, `runtime/debug/performance`, `runtime/debug/monitors`, `runtime/debug/errors`, and `runtime/debug/breakpoints`.
- Buffer `append(level,message,details={}) -> int`, `read(after_cursor,limit) -> {items,next_cursor,dropped}` and `clear() -> {cleared,next_cursor}`.
- Read defaults to 100 and caps at 500; capacity is 2,000 records per running session.
- Debug metrics expose named `Performance` monitors; breakpoint mutation is explicitly `not_supported` in v1 unless the editor debugger session reports support.

- [ ] **Step 1: Write wraparound and incremental-read tests**

```gdscript
func test_cursor_does_not_repeat() -> void:
	var buffer := RingBuffer.new(3)
	for value in ["a", "b", "c", "d"]:
		buffer.append("info", value)
	var first := buffer.read(0, 2)
	assert_eq(first.items.map(func(item): return item.message), ["b", "c"])
	assert_eq(first.dropped, 1)
	var second := buffer.read(first.next_cursor, 2)
	assert_eq(second.items.map(func(item): return item.message), ["d"])
```

```python
def test_runtime_logs_are_incremental(m3_running):
    exec_ok(m3_running, "runtime/node/call", {
        "node_path": "/root/RuntimeMain", "method": "emit_known_logs", "args": []
    })
    first = exec_ok(m3_running, "runtime/log/read", {"after_cursor": 0})
    second = exec_ok(m3_running, "runtime/log/read", {"after_cursor": first["next_cursor"]})
    assert [item["message"] for item in first["items"]][-2:] == ["known-info", "known-error"]
    assert second["items"] == []
```

- [ ] **Step 2: Run unit and E2E observability tests**

Run: `uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/m3/test_runtime_observability.py -v -k "ring_buffer or runtime_logs"`

Expected: FAIL because the buffer/routes are absent.

- [ ] **Step 3: Implement bounded observability**

Assign each record a monotonically increasing cursor and timestamp. The probe exposes `record_log` and `record_error`, captures its own operation failures automatically, and emits records as events to the editor mirror buffer. Define an explicit name-to-`Performance.Monitor` enum map, query only those values with `Performance.get_monitor()`, and sort output keys.

- [ ] **Step 4: Verify cursor, clear, performance, and disconnect reset**

Run: `uv run pytest tests/e2e/m3/test_runtime_observability.py -v`

Expected: PASS; a new game session starts with an empty buffer and new session identity.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/runtime_ring_buffer.gd gdapi/addon/routes/runtime/log gdapi/addon/routes/runtime/debug tests
git commit -m "feat: add runtime observability buffers"
```

---

### Task 7: Add Safe Conditions, Assertions, and Signal Awaiting

**Files:**
- Create: `gdapi/addon/runtime/runtime_condition.gd`
- Create: `gdapi/addon/routes/runtime/assert/{condition,node_exists,property_equals,signal_received}.gd`
- Create: `gdapi/addon/routes/runtime/signal/{connect,disconnect,emit,await}.gd`
- Create: `tests/fixture_project/tests/test_runtime_condition.gd`
- Create: `tests/e2e/m3/test_runtime_assert_signal.py`

**Interfaces:**
- Produces assertion routes `runtime/assert/condition`, `runtime/assert/node_exists`, `runtime/assert/property_equals`, and `runtime/assert/signal_received`.
- Condition grammar nodes are `{op:"and|or|not",args}` or `{op:"eq|ne|lt|lte|gt|gte|contains",left,right}`; operands are literals or `{node_path,property}`.
- Assertion responses contain `{ok:true,passed:true,elapsed_ms}`; failed predicates return HTTP error code `conflict`; deadlines return `timeout`.
- Signal await consumes `{node_path,signal,timeout_ms}` and returns encoded arguments once.

- [ ] **Step 1: Write grammar, success, failure, timeout, and disconnect tests**

```python
def test_condition_waits_until_true(m3_running):
    condition = {
        "op": "gte",
        "left": {"node_path": "/root/RuntimeMain/ProbeTarget", "property": "counter"},
        "right": 2,
    }
    exec_ok(m3_running, "runtime/node/call", {
        "node_path": "/root/RuntimeMain/ProbeTarget", "method": "increment_later", "args": [2, 100]
    })
    result = exec_ok(m3_running, "runtime/assert/condition", {
        "condition": condition, "timeout_ms": 1000, "poll_ms": 20
    })
    assert result["passed"] is True


def test_signal_await_timeout(m3_running):
    error = exec_error(m3_running, "runtime/signal/await", {
        "node_path": "/root/RuntimeMain/ProbeTarget", "signal": "finished", "timeout_ms": 25
    })
    assert error["code"] == "timeout"
```

- [ ] **Step 2: Run focused unit and E2E tests**

Run: `uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/m3/test_runtime_assert_signal.py -v -k "condition or signal"`

Expected: FAIL because the evaluator and routes are absent.

- [ ] **Step 3: Implement a non-evaluating condition interpreter**

Use an explicit `match op` and recursively resolve operands; never call `Expression`, `str_to_var`, script compilation, or object methods. Poll via SceneTreeTimer and disconnect signal callables on every completion path. Runtime signal connect/disconnect requires an allowlisted target callable; emit validates the signal exists and VariantCodec-decodes arguments.

- [ ] **Step 4: Verify all completion paths**

Run: `uv run pytest tests/e2e/m3/test_runtime_assert_signal.py -v`

Expected: PASS; success, conflict, timeout, stop, and disconnect each leave zero waits and connections.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/runtime_condition.gd gdapi/addon/routes/runtime/assert gdapi/addon/routes/runtime/signal tests
git commit -m "feat: add runtime assertions and signal waits"
```

---

### Task 8: Lock M3 Contracts and Run the Full Runtime Matrix

**Files:**
- Create: `tests/e2e/m3/test_m3_contract.py`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`

**Interfaces:**
- The M3 manifest contains status, scene/tree, seven node, six input, three screenshot, two log, four assert, four signal, and four debug routes.
- Every async route documents timeout and disconnect errors.

- [ ] **Step 1: Add manifest and no-leak tests**

```python
EXPECTED_RUNTIME_ROUTES = {
    "runtime/status", "runtime/scene/tree",
    *{f"runtime/node/{name}" for name in ["info","get","set","call","find","remove","reparent"]},
    *{f"runtime/input/{name}" for name in ["key","mouse","gamepad","touch","action","sequence"]},
    *{f"runtime/screenshot/{name}" for name in ["viewport","camera","frames"]},
    *{f"runtime/log/{name}" for name in ["read","clear"]},
    *{f"runtime/assert/{name}" for name in ["condition","node_exists","property_equals","signal_received"]},
    *{f"runtime/signal/{name}" for name in ["connect","disconnect","emit","await"]},
    *{f"runtime/debug/{name}" for name in ["performance","monitors","errors","breakpoints"]},
}


def test_runtime_manifest_and_cleanup(m3_editor):
    routes = set(exec_ok(m3_editor, "gdapi/routes")["routes"])
    assert EXPECTED_RUNTIME_ROUTES <= routes
    for route in sorted(EXPECTED_RUNTIME_ROUTES):
        doc = command_doc(m3_editor, route)
        assert doc["summary"] and doc["returns"]["fields"]
        if doc["params"]:
            assert doc["examples"]
    for _ in range(2):
        exec_ok(m3_editor, "project/run")
        wait_connected(m3_editor)
        exec_ok(m3_editor, "project/stop")
        wait_stopped(m3_editor)
        assert exec_ok(m3_editor, "runtime/status")["pending"] == 0
```

- [ ] **Step 2: Run the complete M3 suite**

Run: `uv run pytest tests/e2e/m3 -v`

Expected: PASS with two lifecycle cycles and no duplicate logs, pending requests, signal connections, timers, or game processes.

- [ ] **Step 3: Document protocol and public route boundaries**

Document protocol version 1, EngineDebugger transport, message limits, condition grammar, call allowlists, input semantics, cursor behavior, and the exclusion of arbitrary eval until M6.

- [ ] **Step 4: Run repository verification**

Run:

```bash
cargo fmt --check
cargo clippy --workspace
cargo test --workspace
uv run pytest tests/e2e/ -v
git diff --check
```

Expected: all commands exit 0 on Godot 4.7.x.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/m3 README.md docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md
git commit -m "docs: complete M3 runtime validation milestone"
```
