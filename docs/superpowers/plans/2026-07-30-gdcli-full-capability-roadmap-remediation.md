# gdcli Full-Capability Roadmap Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the M3–M6 contract, safety, audit, data-integrity, acceptance-test, and documentation gaps identified by the 2026-07-30 full-capability implementation audit.

**Architecture:** Preserve the existing natural route namespace and M1–M5 public behavior. Route families are tracked by milestone-owned manifests; runtime eval uses a negotiated protocol-v2 broker/probe path; high-risk async work reports one terminal response and one terminal audit event; network and bulk-file services validate complete plans before side effects. M5 and M6 receive isolated fixtures that prove final state rather than only HTTP success.

**Tech Stack:** Godot 4.7.x GDScript, godot-rust 0.5.4 with `api-4-7`, Rust `std::process`, pytest/uv, gdtoolkit, existing gdcli HTTP/broker/file-transport infrastructure.

## Global Constraints

- Support only Godot 4.7.x; do not add Godot 4.3–4.6 compatibility branches or test matrices.
- Preserve `gdcli exec <route> --data ...` as the only generic gdapi entry point.
- Preserve existing public route paths and the natural domain naming scheme; do not add aliases.
- Keep Godot business logic in GDScript route/helper modules; Rust remains limited to bounded host primitives such as process lifecycle.
- Every route accepts only POST with a JSON object body and uses the 10 standard error codes.
- Current editor-state mutation uses UndoRedo; file/resource/runtime mutation returns `undoable:false`.
- Every high-risk route remains deny-by-default and requires both project policy enablement and `force:true`.
- Policy path remains `res://.godot/gdapi-policy.json` and cannot be selected or written through gdapi routes.
- Process execution never invokes a shell; timeout is at most 60 seconds and combined output is at most 1 MiB.
- Network response size is at most 4 MiB; every resolved address and redirect target must pass the same policy.
- Eval source is at most 16 KiB and cannot accept or return Object, Resource, Script, Callable, RID, or arbitrary engine singletons.
- Bulk operations validate every input before mutation and must either complete fully or restore the pre-operation state.
- Success, rejection, failure, timeout, cancellation, rollback, and recovery produce bounded, redacted audit records.
- Before any unit or E2E test after changing `.gd` files, run `python scripts/format-gd.py`, `python scripts/format-gd.py --check`, and `gdlint` on every changed `.gd` file. If `gdformat` or `gdlint` is unavailable, run `uv tool install gdtoolkit` first.
- Helper scripts added by this plan must be Python `.py` files; do not add `.sh` or `.ps1` scripts.
- No test may be weakened to hide a product defect; milestone manifests must distinguish original and post-milestone routes explicitly.

## Source and Test Layout

| Path | Responsibility after remediation |
|---|---|
| `tests/e2e/route_manifests.py` | Single source of truth for M1/M2/M3/M4/M5/M6 public route sets |
| `gdapi/addon/runtime/runtime_protocol.gd` | v1/v2 wire builders, validation, and negotiation helpers |
| `gdapi/addon/runtime/runtime_broker.gd` | Store negotiated protocol version and send/receive matching envelopes |
| `gdapi/addon/runtime/runtime_probe.gd` | Advertise v1/v2, execute runtime eval only for negotiated v2 |
| `gdapi/addon/runtime/runtime_route.gd` | Dispatch runtime operations using an explicit protocol version |
| `gdapi/addon/runtime/services/eval_service.gd` | Token-level restricted expression validation and object-free results |
| `gdapi/addon/runtime/services/network_target_guard.gd` | URL parsing, DNS/IP classification, redirect target authorization |
| `gdapi/addon/runtime/services/network_service.gd` | Bounded request lifecycle with manually validated redirects |
| `gdapi/addon/runtime/deferred_task_registry.gd` | Exactly-once terminal response, cancellation, and terminal callback |
| `gdapi/addon/runtime/services/bulk_file_service.gd` | Prevalidated stage/apply/rollback/recover transaction |
| `tests/fixtures/m5_project/**` | Exact diagnostics, project mutation, export, and Android parser fixture |
| `tests/fixtures/m6_project/**` | Isolated policy, eval, process, network, bulk file, and deploy fixture |
| `tests/e2e/m5/**` | M5 final-state acceptance |
| `tests/e2e/m6/**` | M6 safety and final-state acceptance |

---

### Task 1: Restore Milestone-Owned Route Contracts and Add the M6 Harness

**Files:**
- Create: `tests/e2e/route_manifests.py`
- Create: `tests/e2e/m6/__init__.py`
- Create: `tests/e2e/m6/conftest.py`
- Create: `tests/e2e/m6/test_m6_contract.py`
- Create: `tests/fixtures/m6_project/project.godot`
- Create: `tests/fixtures/m6_project/main.tscn`
- Create: `tests/fixtures/m6_project/bulk/a.txt`
- Create: `tests/fixtures/m6_project/bulk/b.txt`
- Modify: `tests/e2e/m2/test_m2_contract.py`
- Modify: `tests/e2e/m3/test_m3_contract.py`
- Modify: `tests/e2e/m4/test_m4_contract.py`
- Modify: `tests/e2e/m5/test_m5_smoke.py`

**Interfaces:**
- Produces immutable sets `M3_RUNTIME_ROUTES`, `M4_ROUTES`, `M5_ROUTES`, and `M6_ROUTES`.
- Produces `m6_editor(policy: dict | None)` as the base isolated editor fixture.
- Produces `m6_editor_denied` with no policy file.
- Produces `exec_ok`, `exec_error`, `command_doc`, and `latest_audit` fixtures/helpers for later tasks.
- Preserves the original 35-route M3 set while allowing the explicit post-M3 route `runtime/eval`.

- [ ] **Step 1: Add the shared route manifests and failing contract assertions**

```python
# tests/e2e/route_manifests.py
M3_RUNTIME_ROUTES = {
    "runtime/status", "runtime/scene/tree",
    *{f"runtime/node/{name}" for name in (
        "info", "get", "set", "call", "find", "remove", "reparent",
        "create", "duplicate", "rename",
    )},
    *{f"runtime/input/{name}" for name in (
        "key", "mouse", "gamepad", "touch", "action", "sequence",
    )},
    *{f"runtime/screenshot/{name}" for name in ("viewport", "camera", "frames")},
    *{f"runtime/log/{name}" for name in ("read", "clear")},
    *{f"runtime/assert/{name}" for name in (
        "condition", "node_exists", "property_equals", "signal_received",
    )},
    *{f"runtime/signal/{name}" for name in ("connect", "disconnect", "emit", "await")},
    *{f"runtime/debug/{name}" for name in (
        "performance", "monitors", "errors", "breakpoints",
    )},
}

M6_ROUTES = {
    "editor/eval", "runtime/eval", "process/run", "network/http_request",
    "filesystem/batch/delete", "filesystem/batch/replace",
    "filesystem/batch/recover", "export/android/deploy_many",
}
```

Update the M3 contract to compare explicit sets:

```python
runtime_routes = {route for route in routes if route.startswith("runtime/")}
assert M3_RUNTIME_ROUTES <= runtime_routes
assert runtime_routes - M3_RUNTIME_ROUTES == {"runtime/eval"}
assert len(M3_RUNTIME_ROUTES) == 35
```

Update the M4 bridge assertion:

```python
assert not {route for route in M4_ROUTES if route.startswith("runtime/")}
assert {route for route in routes if route.startswith("runtime/")} == (
    M3_RUNTIME_ROUTES | {"runtime/eval"}
)
```

- [ ] **Step 2: Run the current failing M3/M4 contracts**

Run:

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/m3/test_m3_contract.py tests/e2e/m4/test_m4_contract.py -v
```

Expected before updating the assertions: FAIL with runtime route count `36 != 35`.

- [ ] **Step 3: Add the isolated M6 project and default-deny fixture**

`tests/fixtures/m6_project/project.godot`:

```ini
[application]
config/name="gdcli M6 Fixture"
run/main_scene="res://main.tscn"

[display]
window/size/viewport_width=320
window/size/viewport_height=180

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
```

`tests/fixtures/m6_project/main.tscn`:

```ini
[gd_scene format=3]

[node name="Main" type="Node"]
```

In `m6_editor(policy)`, copy the fixture into `tmp_path`, write
`.godot/gdapi-policy.json` before editor startup only when `policy` is not `None`, install the addon,
start Godot 4.7, attach through the existing M3 editor helpers, and assert teardown leaves no
Godot/gdcli child process or `.godot/gdapi_runtime` directory.

- [ ] **Step 4: Add and run the M6 default-deny/doc contract**

```python
@pytest.mark.parametrize("route", sorted(M6_ROUTES))
def test_m6_route_is_denied_without_policy(m6_editor_denied, route):
    body = {"force": True}
    if route == "runtime/eval":
        body["source"] = "1 + 1"
    error = exec_error(m6_editor_denied, route, body)
    assert error["code"] == "permission_denied"


def test_m6_docs_are_complete(m6_editor_denied):
    for route in sorted(M6_ROUTES):
        doc = command_doc(m6_editor_denied, route)
        assert doc["summary"]
        assert doc["returns"]["fields"]
        assert doc["examples"]
```

Run:

```powershell
uv run pytest tests/e2e/m3/test_m3_contract.py tests/e2e/m4/test_m4_contract.py tests/e2e/m6/test_m6_contract.py -v
```

Expected: PASS; M3 remains exactly 35 milestone-owned routes, M4 owns no runtime route, and all
8 M6 routes are documented and denied by default.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/route_manifests.py tests/e2e/m2/test_m2_contract.py tests/e2e/m3/test_m3_contract.py tests/e2e/m4/test_m4_contract.py tests/e2e/m5/test_m5_smoke.py tests/e2e/m6 tests/fixtures/m6_project
git commit -m "test: isolate roadmap route contracts"
```

---

### Task 2: Route Runtime Eval Through a Negotiated Protocol-v2 Probe

**Files:**
- Modify: `gdapi/addon/runtime/runtime_protocol.gd`
- Modify: `gdapi/addon/runtime/runtime_broker.gd`
- Modify: `gdapi/addon/runtime/runtime_route.gd`
- Modify: `gdapi/addon/runtime/runtime_probe.gd`
- Modify: `gdapi/addon/runtime/runtime_debugger_plugin.gd`
- Modify: `gdapi/addon/runtime/runtime_transport_file_probe.gd`
- Modify: `gdapi/addon/runtime/runtime_transport_file_editor.gd`
- Modify: `gdapi/addon/routes/runtime/eval.gd`
- Modify: `tests/fixture_project/tests/test_runtime_protocol.gd`
- Modify: `tests/fixture_project/tests/test_runtime_broker.gd`
- Modify: `tests/fixture_project/tests/test_runtime_transport_integration.gd`
- Create: `tests/e2e/m6/test_runtime_eval.py`

**Interfaces:**
- Produces `Protocol.request_for_version(version, id, op, payload, generation)`.
- Produces `Protocol.reply_for_version(version, id, ok, result, error, code, generation)`.
- Broker stores `_negotiated_version: int`, reports it in `status()`, and exposes
  `request_versioned(op, payload, timeout_ms, version, callback) -> int`.
- Probe hello advertises `supported_versions: [1, 2]`.
- Transport selects the highest common version, preferring 2, and refuses unnegotiated envelopes.
- `runtime/eval` dispatches op `eval` with protocol v2 and never calls `EvalService` in the editor.

- [ ] **Step 1: Write protocol negotiation and disconnected-runtime tests**

```gdscript
func test_v1_still_rejects_eval_and_v2_accepts_it() -> void:
	var v1 := Protocol.request_for_version(1, 1, "eval", {"source": "1+1"})
	var v2 := Protocol.request_for_version(2, 2, "eval", {"source": "1+1"})
	assert_eq(Protocol.validate_message(v1).code, "permission_denied")
	assert_true(Protocol.validate_message(v2).ok)


func test_broker_rejects_reply_with_wrong_negotiated_version() -> void:
	broker.attach(func(_message): pass, "session", 2)
	var called := false
	var id := broker.request_versioned("eval", {}, 1000, 2, func(_reply): called = true)
	broker.receive(Protocol.reply_for_version(1, id, true, {}))
	assert_false(called)
```

```python
def test_runtime_eval_requires_running_probe(m6_editor_eval):
    error = exec_error(
        m6_editor_eval, "runtime/eval",
        {"source": "1 + 1", "force": True},
    )
    assert error["code"] == "conflict"
```

- [ ] **Step 2: Run the focused tests and verify the current editor-side implementation fails**

Run:

```powershell
uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/m6/test_runtime_eval.py -v -k "protocol or broker or transport or runtime_eval"
```

Expected: FAIL because the current broker/probe remains v1 and `runtime/eval` executes locally.

- [ ] **Step 3: Implement versioned builders and negotiation**

Implement builders that preserve existing v1 callers:

```gdscript
static func request_for_version(
	version: int, id: int, op: String, payload: Dictionary = {}, generation: String = ""
) -> Dictionary:
	var message := {
		"version": version,
		"id": id,
		"kind": "request",
		"op": op,
		"payload": payload,
	}
	if not generation.is_empty():
		message["generation"] = generation
	return message


static func request(
	id: int, op: String, payload: Variant = null, generation: String = ""
) -> Dictionary:
	return request_for_version(VERSION, id, op, payload if typeof(payload) == TYPE_DICTIONARY else {}, generation)
```

Hello messages must carry:

```gdscript
{
	"protocol_version": Protocol.VERSION,
	"supported_versions": Protocol.SUPPORTED_VERSIONS,
	"transport": transport_name,
}
```

The editor selects:

```gdscript
var common := probe_versions.filter(func(version): return Protocol.SUPPORTED_VERSIONS.has(version))
common.sort()
var negotiated := int(common.back()) if not common.is_empty() else 0
```

Reject the hello when `negotiated == 0`. Store the negotiated version in the broker and use it for
every request and reply in that session.

- [ ] **Step 4: Move runtime eval into the probe**

Make `runtime/eval.gd` inherit `runtime_route.gd`. After policy authorization, call:

```gdscript
dispatch_versioned(req, res, "eval", Protocol.VERSION_V2, false, ROUTE)
```

Add `dispatch_versioned()` to `runtime_route.gd`; it must require broker state `connected` and
negotiated version at least 2 before registering a request.

In `runtime_probe.gd`, add one exact op:

```gdscript
"eval":
	return EvalService.execute(
		String(payload.get("source", "")),
		payload.get("inputs", {}),
		_runtime_eval_policy()
	)
```

The probe reads a sanitized runtime-eval policy snapshot passed in the `project/run` launch
configuration. The snapshot contains only `max_source_bytes` and `allowed_input_keys`; it never
contains the full policy or unrelated capabilities.

- [ ] **Step 5: Verify editor/runtime process separation and cleanup**

Add E2E assertions:

```python
def test_runtime_eval_runs_only_in_game_process(m6_runtime_eval_running):
    result = exec_ok(
        m6_runtime_eval_running, "runtime/eval",
        {"source": "runtime_marker + 1", "inputs": {"runtime_marker": 41}, "force": True},
    )
    assert result["value"] == 42


def test_runtime_eval_disconnect_completes_once(m6_runtime_eval_running):
    pending = start_async_exec(m6_runtime_eval_running, "runtime/eval", {
        "source": "runtime_marker + 1",
        "inputs": {"runtime_marker": 41},
        "force": True,
    })
    stop_game(m6_runtime_eval_running)
    assert pending.result(timeout=5)["code"] == "conflict"
    assert exec_ok(m6_runtime_eval_running, "runtime/status")["pending"] == 0
```

Run:

```powershell
uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/m3 tests/e2e/m6/test_runtime_eval.py -v
```

Expected: PASS; all original M3 routes stay on v1-compatible behavior, runtime eval uses v2, and
disconnect leaves zero pending requests.

- [ ] **Step 6: Commit**

```bash
git add gdapi/addon/runtime/runtime_protocol.gd gdapi/addon/runtime/runtime_broker.gd gdapi/addon/runtime/runtime_route.gd gdapi/addon/runtime/runtime_probe.gd gdapi/addon/runtime/runtime_debugger_plugin.gd gdapi/addon/runtime/runtime_transport_file_probe.gd gdapi/addon/runtime/runtime_transport_file_editor.gd gdapi/addon/routes/runtime/eval.gd tests/fixture_project/tests tests/e2e/m6/test_runtime_eval.py
git commit -m "fix: execute runtime eval through protocol v2"
```

---

### Task 3: Replace Eval Substring Filtering with an Identifier Allowlist

**Files:**
- Modify: `gdapi/addon/runtime/services/eval_service.gd`
- Modify: `tests/fixture_project/tests/test_eval_service.gd`
- Create: `tests/e2e/m6/test_eval.py`

**Interfaces:**
- Produces `_tokenize_identifiers(source: String) -> Dictionary`.
- Produces `_validate_result(value: Variant) -> Dictionary`.
- Permits literals, arithmetic, `==`, `!=`, `<`, `<=`, `>`, `>=`, boolean operators, parentheses,
  policy-approved input names, and the existing Variant constructors.
- Rejects member access, method calls, assignment, statements, engine/global identifiers, and all
  Object-like input/result values.

- [ ] **Step 1: Add allow/deny and object-result tests**

```gdscript
func test_comparisons_and_vector_math_are_allowed() -> void:
	var policy := {"max_source_bytes": 16384, "allowed_input_keys": ["a", "b"]}
	assert_true(EvalService.execute("a <= b and a != 0", {"a": 1, "b": 2}, policy).ok)
	assert_true(
		EvalService.execute(
			"Vector2(a, b) + Vector2(1, 1)", {"a": 1, "b": 2}, policy
		).ok
	)


func test_unapproved_identifier_and_object_result_are_denied() -> void:
	var policy := {"max_source_bytes": 16384, "allowed_input_keys": []}
	assert_eq(EvalService.execute("instance_from_id(1)", {}, policy).code, "permission_denied")
	assert_eq(EvalService.execute("Engine", {}, policy).code, "permission_denied")
```

Python E2E must test both `editor/eval` and `runtime/eval` with the same allow/deny matrix.

- [ ] **Step 2: Run the eval tests and verify comparison/object cases fail**

Run:

```powershell
uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/m6/test_eval.py -v -k eval
```

Expected: FAIL because the current `source.contains("=")` rejects comparisons and the global
constructor loop does not enforce an allowlist.

- [ ] **Step 3: Implement lexical validation**

Scan UTF-8 source character by character. Emit identifiers matching `[A-Za-z_][A-Za-z0-9_]*`,
string/number literals, and operator tokens. Reject:

- `.`, `;`, newline, `{}`, `[]`, `:`, backslash escapes outside string literals.
- Single `=` while allowing `==`, `!=`, `<=`, `>=`.
- Any identifier not in `input_names`, `ALLOWED_GLOBALS`, or
  `{"true", "false", "null", "and", "or", "not"}`.
- Any `(` following an identifier unless that identifier is in `ALLOWED_GLOBALS`.

After `Expression.execute()`, call `_validate_result()` recursively and reject Object, Resource,
Script, Callable, RID, Signal, or nested containers containing those types.

- [ ] **Step 4: Verify limits, typing, and audit redaction**

```python
def test_eval_source_never_appears_in_audit(m6_editor_eval):
    secret = "41 + 1"
    exec_ok(m6_editor_eval, "editor/eval", {"source": secret, "force": True})
    event = latest_audit(m6_editor_eval, "editor/eval")
    assert secret not in json.dumps(event)
    assert event["ok"] is True
```

Run:

```powershell
uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/m6/test_eval.py tests/e2e/m6/test_runtime_eval.py -v
```

Expected: PASS with typed Vector/Color results, comparison support, stable denial codes, and no
source text in audit.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/eval_service.gd tests/fixture_project/tests/test_eval_service.gd tests/e2e/m6/test_eval.py
git commit -m "fix: enforce eval identifier allowlist"
```

---

### Task 4: Enforce DNS/IP and Redirect Safety for Network Requests

**Files:**
- Create: `gdapi/addon/runtime/services/network_target_guard.gd`
- Modify: `gdapi/addon/runtime/services/network_service.gd`
- Modify: `gdapi/addon/runtime/capability_policy.gd`
- Modify: `gdapi/addon/routes/network/http_request.gd`
- Create: `tests/fixture_project/tests/test_network_target_guard.gd`
- Modify: `tests/e2e/test_gdscript_units.py`
- Create: `tests/e2e/m6/test_network_request.py`
- Modify: `tests/e2e/m6/conftest.py`

**Interfaces:**
- Produces `NetworkTargetGuard.authorize(url, policy, resolver) -> Dictionary`.
- Authorized result contains normalized `url`, `scheme`, `host`, `port`, and sorted `addresses`.
- Network policy adds `max_redirects`, constrained to integer `0..5`.
- Produces `local_http_server` endpoints `/ok`, `/large`, `/delay`, `/redirect-ok`,
  `/redirect-private`, and `/redirect-loop`.
- Every redirect calls `NetworkTargetGuard.authorize()` again before a new request.

- [ ] **Step 1: Write address-classification and redirect tests**

```gdscript
func test_private_and_special_addresses_are_rejected() -> void:
	for address in [
		"127.0.0.2", "169.254.1.1", "10.0.0.1", "172.31.0.1",
		"192.168.1.1", "0.0.0.0", "224.0.0.1", "::", "::1", "fe80::1", "ff02::1",
		"::ffff:127.0.0.1"
	]:
		assert_false(NetworkTargetGuard.is_public_address(address), address)
```

```python
def test_dns_name_resolving_to_private_address_is_denied(m6_editor_network):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": "http://private.test/ok", "force": True,
    })
    assert error["code"] == "permission_denied"


def test_redirect_target_is_revalidated(m6_editor_network, local_http_server):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/redirect-private"), "force": True,
    })
    assert error["code"] == "permission_denied"
```

- [ ] **Step 2: Run the focused network tests**

Run:

```powershell
uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/m6/test_network_request.py -v -k network
```

Expected: FAIL because DNS resolution, complete address classification, and redirect following are
not implemented.

- [ ] **Step 3: Implement target authorization**

Parse URL with `String.uri_decode()` only after rejecting control characters, credentials,
fragments, empty host, invalid port, and non-HTTP(S) schemes. Resolve with:

```gdscript
var addresses := IP.resolve_hostname_addresses(host, IP.TYPE_ANY)
```

Normalize IPv4 and IPv6 strings, sort/deduplicate them, and require every resolved address to be
public unless `allow_private:true`. When private access is enabled, the exact normalized host and
port must still be present in policy; `allow_private` never broadens `hosts` or `ports`.

Reject these ranges:

- IPv4: `0.0.0.0/8`, `10/8`, `100.64/10`, `127/8`, `169.254/16`, `172.16/12`,
  `192.0.0.0/24`, `192.0.2/24`, `192.168/16`, `198.18/15`, `198.51.100/24`,
  `203.0.113/24`, `224/4`, `240/4`.
- IPv6: unspecified, loopback, IPv4-mapped blocked addresses, `fc00::/7`, `fe80::/10`,
  multicast `ff00::/8`, documentation `2001:db8::/32`.

- [ ] **Step 4: Implement manual redirect handling**

Keep `HTTPRequest.max_redirects = 0`. On 301, 302, 303, 307, or 308:

1. Read exactly one `Location` header.
2. Resolve relative location against the current URL.
3. Reject when redirect count equals policy `max_redirects`.
4. Call `NetworkTargetGuard.authorize()` for the new URL.
5. Start a new `HTTPRequest` only after authorization succeeds.

Reject redirect loops using a set of normalized URLs. Return the actual `redirects` count.

- [ ] **Step 5: Verify response cap, timeout, headers, redirects, and redaction**

Run:

```powershell
uv run pytest tests/e2e/m6/test_network_request.py -v
```

Expected: PASS for `/ok` and an allowed redirect; stable `invalid_param`, `permission_denied`,
`timeout`, or `godot_error` for malformed URL, blocked DNS result, redirect loop, cap overflow, and
timeout. Audit must not contain Authorization, Cookie, body, or response bytes.

- [ ] **Step 6: Commit**

```bash
git add gdapi/addon/runtime/services/network_target_guard.gd gdapi/addon/runtime/services/network_service.gd gdapi/addon/runtime/capability_policy.gd gdapi/addon/routes/network/http_request.gd tests/fixture_project/tests/test_network_target_guard.gd tests/e2e/test_gdscript_units.py tests/e2e/m6
git commit -m "fix: enforce network target safety"
```

---

### Task 5: Make Deferred Process and Network Audits Reflect the Terminal Result

**Files:**
- Modify: `gdapi/addon/runtime/deferred_task_registry.gd`
- Modify: `gdapi/addon/runtime/services/process_service.gd`
- Modify: `gdapi/addon/runtime/services/network_service.gd`
- Modify: `gdapi/addon/routes/process/run.gd`
- Modify: `gdapi/addon/routes/network/http_request.gd`
- Modify: `tests/fixture_project/tests/test_deferred_task_registry.gd`
- Create: `tests/e2e/m6/test_process_run.py`
- Modify: `tests/e2e/m6/test_network_request.py`

**Interfaces:**
- Deferred task adds required callable `finish(outcome: Dictionary) -> void`.
- Registry invokes `finish()` exactly once for success, failure, timeout, cancellation, or
  “completed without response”.
- Service terminal outcome is `{ok, code, summary}` and never contains raw stdout/stderr/body.
- Route records no success audit before task registration or process/network completion.

- [ ] **Step 1: Write exactly-once terminal callback tests**

```gdscript
func test_finish_is_called_once_for_timeout() -> void:
	var finishes: Array = []
	var task := fake_task(10)
	task["finish"] = func(outcome): finishes.append(outcome)
	assert_true(registry.register(task))
	registry.tick(10)
	registry.tick(20)
	assert_eq(finishes.size(), 1)
	assert_eq(finishes[0].code, "timeout")
```

```python
def test_process_timeout_has_one_failed_terminal_audit(m6_editor_process):
    error = exec_error(m6_editor_process, "process/run", timeout_process_body())
    assert error["code"] == "timeout"
    events = audit_for_route(m6_editor_process, "process/run")
    assert len(events) == 1
    assert events[0]["ok"] is False and events[0]["code"] == "timeout"
```

- [ ] **Step 2: Run the focused tests and verify premature/missing audit behavior**

Run:

```powershell
uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/m6/test_process_run.py tests/e2e/m6/test_network_request.py -v
```

Expected: FAIL because process currently records success on registration and network does not
record terminal success/failure.

- [ ] **Step 3: Implement the registry terminal outcome contract**

On normal completion, the task tick returns:

```gdscript
{"done": true, "outcome": {"ok": true, "code": "", "summary": {"exit_code": 0}}}
```

On timeout/cancel/registry error, the registry constructs the same shape with `ok:false`. Before
removing the task, call:

```gdscript
if not bool(task.get("_finished", false)):
	task["_finished"] = true
	task["finish"].call(outcome)
```

The task `finish` callback records the only terminal audit event. Policy and synchronous validation
rejections remain immediate audit events because no deferred task was registered.

- [ ] **Step 4: Add process route E2E**

Cover:

- Default denial and missing force.
- Exact executable allowlist and canonical cwd root.
- Literal argv containing `;`, `$()`, spaces, and quotes.
- Nonzero exit as `ok:true` with actual exit code.
- Timeout as `timeout`.
- Combined output cap and `truncated:true`.
- Plugin shutdown cancellation with no child process.
- Exactly one terminal audit with no argv secrets or output.

Run:

```powershell
uv run pytest tests/e2e/m6/test_process_run.py tests/e2e/m6/test_network_request.py -v
```

Expected: PASS and no process named by the M6 sleep fixture remains after teardown.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/deferred_task_registry.gd gdapi/addon/runtime/services/process_service.gd gdapi/addon/runtime/services/network_service.gd gdapi/addon/routes/process/run.gd gdapi/addon/routes/network/http_request.gd tests/fixture_project/tests/test_deferred_task_registry.gd tests/e2e/m6
git commit -m "fix: audit deferred operations at terminal state"
```

---

### Task 6: Make Bulk File Replace/Delete/Recover Transactional

**Files:**
- Modify: `gdapi/addon/runtime/services/bulk_file_service.gd`
- Modify: `gdapi/addon/routes/filesystem/batch/delete.gd`
- Modify: `gdapi/addon/routes/filesystem/batch/replace.gd`
- Modify: `gdapi/addon/routes/filesystem/batch/recover.gd`
- Create: `tests/fixture_project/tests/test_bulk_file_service.gd`
- Modify: `tests/e2e/test_gdscript_units.py`
- Create: `tests/e2e/m6/test_bulk_files.py`

**Interfaces:**
- Dry-run returns canonical `operations` and `plan_hash`.
- Replace supports literal mode only; remove the public `regex` parameter until a separately tested
  regex design exists.
- Apply stages every output under `res://.godot/gdapi-staging/<operation_id>/` before replacing any
  destination.
- Rollback restores every changed destination from staging backups.
- Delete manifest records primary and `.uid` companions.
- Recover restores both primary and `.uid`, then marks the manifest `recovered:true`.

- [ ] **Step 1: Add race, rollback, UID, and repeat-recovery tests**

```python
def test_replace_rolls_back_every_file_when_second_apply_fails(m6_editor_bulk):
    plan = replace_plan(m6_editor_bulk, root="res://bulk", find="old", replace="new")
    inject_apply_failure(m6_editor_bulk, fail_after=1)
    before = bulk_digest(m6_editor_bulk)
    error = apply_replace(m6_editor_bulk, plan)
    assert error["code"] == "godot_error"
    assert bulk_digest(m6_editor_bulk) == before


def test_delete_recover_restores_uid_and_is_not_repeatable(m6_editor_bulk):
    plan = delete_plan(m6_editor_bulk, ["res://bulk/resource.tres"])
    deleted = apply_delete(m6_editor_bulk, plan)
    assert not project_file(m6_editor_bulk, "bulk/resource.tres").exists()
    assert not project_file(m6_editor_bulk, "bulk/resource.tres.uid").exists()
    exec_ok(m6_editor_bulk, "filesystem/batch/recover", {
        "operation_id": deleted["operation_id"], "force": True,
    })
    assert project_file(m6_editor_bulk, "bulk/resource.tres").exists()
    assert project_file(m6_editor_bulk, "bulk/resource.tres.uid").exists()
    assert exec_error(m6_editor_bulk, "filesystem/batch/recover", {
        "operation_id": deleted["operation_id"], "force": True,
    })["code"] == "conflict"
```

- [ ] **Step 2: Run the bulk tests and verify partial-write/UID failures**

Run:

```powershell
uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/m6/test_bulk_files.py -v -k bulk
```

Expected: FAIL because replace does not roll back prior files and recover omits `.uid`.

- [ ] **Step 3: Implement canonical planning and full staging**

Each replace plan operation must contain:

```gdscript
{
	"path": "res://bulk/a.txt",
	"before_sha256": "...",
	"after_sha256": "...",
	"replacement_count": 2,
}
```

Before side effects:

1. Sort unique paths.
2. Reject protected directories and duplicate paths.
3. Re-read all source hashes.
4. Generate every staged output and verify its `after_sha256`.
5. Create backups for every destination.

Only after all five steps pass, replace destinations. On any rename/write failure, restore every
destination from its backup in reverse order and include
`details: {"rolled_back": true, "failed_path": path}`.

- [ ] **Step 4: Complete delete/recover lifecycle**

Delete manifest entry:

```gdscript
{
	"source": "res://bulk/resource.tres",
	"trash": "res://.godot/gdapi-trash/<id>/bulk/resource.tres",
	"uid_source": "res://bulk/resource.tres.uid",
	"uid_trash": "res://.godot/gdapi-trash/<id>/bulk/resource.tres.uid",
}
```

Recover validates all destinations before moving any file. If any destination exists, return
`conflict` with no mutation. After successful recovery, write `recovered:true` and
`recovered_at` into the manifest and remove empty trash subdirectories.

- [ ] **Step 5: Verify no partial state and bounded audit**

Run:

```powershell
uv run pytest tests/e2e/m6/test_bulk_files.py -v
```

Expected: PASS for plan/apply, stale source conflict, injected failure rollback, delete/recover,
UID recovery, traversal/protected path denial, caps, and terminal audit. Teardown must find no
`gdapi-staging` directory.

- [ ] **Step 6: Commit**

```bash
git add gdapi/addon/runtime/services/bulk_file_service.gd gdapi/addon/routes/filesystem/batch tests/fixture_project/tests/test_bulk_file_service.gd tests/e2e/test_gdscript_units.py tests/e2e/m6/test_bulk_files.py
git commit -m "fix: make bulk file operations transactional"
```

---

### Task 7: Complete Bulk Deploy Safety and M5 Acceptance Coverage

**Files:**
- Modify: `gdapi/addon/runtime/services/bulk_deploy_service.gd`
- Modify: `gdapi/addon/runtime/services/android_bridge.gd`
- Modify: `gdapi/addon/routes/export/android/deploy_many.gd`
- Create: `tests/fixture_project/tests/test_bulk_deploy_service.gd`
- Modify: `tests/e2e/test_gdscript_units.py`
- Create: `tests/e2e/m6/test_bulk_deploy.py`
- Create: `tests/e2e/m5/test_project_config_routes.py`
- Create: `tests/e2e/m5/test_classdb_routes.py`
- Create: `tests/e2e/m5/test_diagnostics_routes.py`
- Create: `tests/e2e/m5/test_uid_repair.py`
- Create: `tests/e2e/m5/test_export_android.py`
- Modify: `tests/e2e/m5/conftest.py`
- Modify: `tests/fixtures/m5_project/project.godot`

**Interfaces:**
- Bulk deploy dry-run returns `plan_hash`, `artifact_sha256`, and sorted device snapshot
  `{serial,state}`.
- Apply recomputes APK hash and device snapshot before any deploy.
- Android bridge accepts an injected runner for unit tests.
- M5 mutation fixture restores `project.godot`, generated `.uid`, export output, and Android fake
  state after every test.

- [ ] **Step 1: Write bulk-deploy stale-plan and partial-failure tests**

```gdscript
func test_artifact_or_device_change_invalidates_plan() -> void:
	var plan := service.plan(body, fake_bridge(["a", "b"]), fake_hash("v1"))
	assert_eq(
		service.apply(body_with_hash(plan.plan_hash), fake_bridge(["a"]), fake_hash("v1")).code,
		"conflict"
	)
	assert_eq(
		service.apply(body_with_hash(plan.plan_hash), fake_bridge(["a", "b"]), fake_hash("v2")).code,
		"conflict"
	)
```

```python
def test_partial_device_failure_returns_every_terminal_state(m6_editor_bulk_deploy):
    result = apply_deploy_many(m6_editor_bulk_deploy, serials=["ok", "offline", "fail"])
    assert [item["serial"] for item in result["devices"]] == ["fail", "offline", "ok"]
    assert {item["status"] for item in result["devices"]} == {
        "deployed", "offline", "failed",
    }
```

- [ ] **Step 2: Write M5 acceptance tests before changing M5 services**

Project mutation:

```python
def test_settings_input_map_and_autoload_round_trip(m5_editor):
    before = project_snapshot(m5_editor)
    exec_ok(m5_editor, "project/settings/set", {
        "key": "application/config/test_value", "value": 42,
    })
    exec_ok(m5_editor, "project/input_map/action/add", {"action": "audit_jump"})
    exec_ok(m5_editor, "project/autoload/add", {
        "name": "AuditAuto", "path": "res://fixtures/autoload.gd",
    })
    assert exec_ok(m5_editor, "project/settings/get", {
        "key": "application/config/test_value",
    })["value"] == 42
    restore_snapshot(m5_editor)
    assert_snapshot_restored(m5_editor, before)
```

Diagnostics:

```python
def test_diagnostics_match_exact_fixture_problems(m5_editor):
    assert item_paths(exec_ok(m5_editor, "diagnostics/unused_resources")) == {
        "res://fixtures/unused_resource.tres",
    }
    assert cycle_edges(exec_ok(m5_editor, "diagnostics/cycle_deps")) == {
        ("res://fixtures/cycle_a.tres", "res://fixtures/cycle_b.tres"),
        ("res://fixtures/cycle_b.tres", "res://fixtures/cycle_a.tres"),
    }
    assert error_paths(exec_ok(m5_editor, "diagnostics/script_errors")) == {
        "res://fixtures/broken.gd",
    }
```

- [ ] **Step 3: Run M5/M6 tests and record the unproven behavior**

Run:

```powershell
uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/m5 tests/e2e/m6/test_bulk_deploy.py -v
```

Expected: new tests FAIL on stale deploy plan, exact diagnostics, mutation round trips, UID
idempotence, export artifact, or Android no-device behavior.

- [ ] **Step 4: Implement bulk-deploy preflight and terminal states**

The plan hash includes:

```gdscript
{
	"serials": sorted_serials,
	"devices": sorted_device_snapshot,
	"apk_path": normalized_apk_path,
	"artifact_sha256": artifact_sha256,
	"package": package_name,
	"activity": activity_name,
}
```

Apply recomputes the entire structure and returns `conflict` before the first deploy when it differs.
Each requested serial returns one of `deployed`, `offline`, `missing`, or `failed`. Overall HTTP
transport succeeds with `ok:true` after a valid plan even when individual devices fail; `changed`
is true only when at least one device reaches `deployed`.

- [ ] **Step 5: Complete M5 final-state coverage**

Add assertions for:

- ClassDB filtering and pagination produce deterministic sorted results.
- UID repair dry-run reports changes, apply writes expected UID, and second apply has
  `changed:false`.
- `export/run` produces the fixture PCK and its SHA-256 matches the response.
- Missing export templates return `not_supported` without creating output.
- Android devices returns `[]` or parsed fake devices deterministically.
- Single-device deploy without `force:true` returns `unsafe_operation`.
- Invalid/offline serial returns stable `not_supported` or `not_found` with no deploy attempt.

Use only fake adb/process runners in automated tests; never deploy to a real connected device.

- [ ] **Step 6: Verify M5 and bulk deploy**

Run:

```powershell
uv run pytest tests/e2e/m5 tests/e2e/m6/test_bulk_deploy.py -v
```

Expected: PASS; every test restores its snapshot, checked-in fixtures retain their original digest,
and no export artifact remains outside the temporary project.

- [ ] **Step 7: Commit**

```bash
git add gdapi/addon/runtime/services/bulk_deploy_service.gd gdapi/addon/runtime/services/android_bridge.gd gdapi/addon/routes/export/android/deploy_many.gd tests/fixture_project/tests/test_bulk_deploy_service.gd tests/e2e/test_gdscript_units.py tests/e2e/m5 tests/e2e/m6/test_bulk_deploy.py tests/fixtures/m5_project
git commit -m "test: close M5 and bulk deploy acceptance"
```

---

### Task 8: Reduce E2E Runtime Without Weakening Isolation

**Files:**
- Modify: `tests/e2e/m2/conftest.py`
- Modify: `tests/e2e/m4/conftest.py`
- Modify: `tests/e2e/m2/test_fixture_isolation.py`
- Modify: `tests/e2e/m4/test_m4_contract.py`
- Create: `tests/e2e/test_full_suite_budget.py`

**Interfaces:**
- M2 and M4 use one editor process per module, not one per test.
- Produces `reset_project_state(env) -> None`, which restores fixture files, reloads the main scene,
  clears selection/audit/test-command files, and verifies no pending runtime/deferred task.
- A failed reset fails the current test module; it never silently restarts and hides state leakage.

- [ ] **Step 1: Add reset-isolation regression tests**

```python
def test_reset_restores_files_scene_and_runtime_state(m2_module_editor):
    before = tree_digest(m2_module_editor["project"])
    mutate_scene_file_and_selection(m2_module_editor)
    reset_project_state(m2_module_editor)
    assert tree_digest(m2_module_editor["project"]) == before
    assert exec_ok(m2_module_editor, "editor/selection/get")["nodes"] == []
    assert exec_ok(m2_module_editor, "runtime/status")["pending"] == 0
```

- [ ] **Step 2: Run M2/M4 with durations and capture the baseline**

Run:

```powershell
uv run pytest tests/e2e/m2 tests/e2e/m4 -v --durations=30
```

Expected current baseline: approximately 14 minutes combined because each test starts a fresh
editor.

- [ ] **Step 3: Implement module-scoped editors and deterministic reset**

Change the expensive editor fixture to `scope="module"`. Add an autouse function fixture:

```python
@pytest.fixture(autouse=True)
def isolated_test_state(module_editor):
    reset_project_state(module_editor)
    before = project_snapshot(module_editor)
    yield
    reset_project_state(module_editor)
    assert_project_snapshot(module_editor, before)
```

`reset_project_state()` must:

1. Stop a running game and wait for broker `state == "stopped"` and `pending == 0`.
2. Restore mutable files from the checked-in source fixture.
3. Remove only allowlisted generated paths under the temporary project.
4. Reimport changed resources.
5. Reopen the fixture main scene.
6. Clear editor selection and audit log.
7. Assert the deferred registry exposes zero pending tasks through a fixture-only test hook.

- [ ] **Step 4: Verify isolation and budget**

Run:

```powershell
uv run pytest tests/e2e/m2 tests/e2e/m4 -v --durations=30
```

Expected: all tests pass, source fixture digests remain unchanged, no reset-triggered editor restart
occurs, and combined local warm-build time is at most 6 minutes.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/m2 tests/e2e/m4 tests/e2e/test_full_suite_budget.py
git commit -m "test: reuse isolated milestone editors"
```

---

### Task 9: Run Full Closure and Align All Public Documentation

**Files:**
- Modify: `gdapi/rust/src/http.rs`
- Modify: `gdapi/rust/src/queue.rs`
- Modify: `cli/src/format/clap_style.rs`
- Modify: `README.md`
- Modify: `docs/security/high-risk-capabilities.md`
- Modify: `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`
- Modify: `docs/reports/2026-07-29-gdcli-roadmap-implementation-status.md`
- Modify: `docs/reports/2026-07-30-gdcli-full-capability-roadmap-implementation-audit.md`
- Create: `docs/reports/2026-07-30-gdcli-full-capability-roadmap-remediation-closure.md`

**Interfaces:**
- Clippy baseline has zero warnings under the repository's current default lint configuration.
- README states 35 M3 runtime routes plus the explicitly post-M3 `runtime/eval`.
- Security docs match the actual DNS/IP, redirect, eval, process, bulk, and audit behavior.
- Main roadmap marks M5/M6 complete only after every command below passes.
- Closure report records exact commit, Godot version, command, exit code, passed/failed/skipped count,
  duration, route counts, process cleanup, and fixture cleanup.

- [ ] **Step 1: Remove the three verified Clippy warnings**

Make these exact mechanical changes:

```rust
// gdapi/rust/src/http.rs
.map_err(|_| io::Error::other("response allocation failed"))?;

// gdapi/rust/src/queue.rs
pub fn is_empty(&self) -> bool {
    self.len() == 0
}
```

In `cli/src/format/clap_style.rs`, replace the nested string check with a guarded match arm:

```rust
Some(Value::String(s)) if !s.is_empty() => {
    output.push_str(&format!("\nReturns:\n  {}\n", s));
}
```

Run:

```powershell
cargo clippy --workspace
```

Expected: exit 0 with zero warnings.

- [ ] **Step 2: Run GDScript formatting and lint gates**

Run:

```powershell
if (-not (Get-Command gdformat -ErrorAction SilentlyContinue) -or
    -not (Get-Command gdlint -ErrorAction SilentlyContinue)) {
    uv tool install gdtoolkit
}
python scripts/format-gd.py
python scripts/format-gd.py --check
$gdFiles = @(git diff --name-only --diff-filter=ACMR | Where-Object { $_ -like '*.gd' })
if ($gdFiles.Count -gt 0) { gdlint $gdFiles }
```

Expected: formatter check and gdlint both exit 0. Do not start unit tests on failure.

- [ ] **Step 3: Run Rust and GDScript verification**

Run:

```powershell
cargo fmt --check
cargo clippy --workspace
cargo test --workspace
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/test_gdscript_units.py -v
```

Expected: all commands exit 0. Record clippy warning count separately; do not describe warnings as
errors or silently omit them.

- [ ] **Step 4: Run milestone suites**

Run:

```powershell
uv run pytest tests/e2e/m2 -v --durations=20
uv run pytest tests/e2e/m3 -v --durations=20
uv run pytest tests/e2e/m4 -v --durations=20
uv run pytest tests/e2e/m5 -v --durations=20
uv run pytest tests/e2e/m6 -v --durations=20
```

Expected: every suite exits 0 with zero skipped tests. M3 owns exactly 35 routes, M4 exactly 51,
M5 exactly 27, and M6 exactly 8.

- [ ] **Step 5: Run the complete E2E command once**

Run:

```powershell
$baselineTestIds = @(
    Get-CimInstance Win32_Process |
    Where-Object {
        $_.CommandLine -match 'pytest-of-|tests[\\/](fixture_project|fixtures)'
    } |
    ForEach-Object { $_.ProcessId }
)
uv run pytest tests/e2e/ -v --durations=30
```

Expected: exit 0, zero failed, zero skipped, no outer timeout, and no pytest output-flush exception.
After completion:

```powershell
$leftovers = @(Get-CimInstance Win32_Process |
    Where-Object {
        $_.ProcessId -notin $baselineTestIds -and
        $_.Name -match 'godot|gdcli|pytest' -and
        $_.CommandLine -match 'pytest-of-|tests[\\/](fixture_project|fixtures)'
    })
if ($leftovers.Count -ne 0) {
    throw "test process cleanup failed: $($leftovers | Select-Object ProcessId,Name | Out-String)"
}
```

- [ ] **Step 6: Update docs from verified behavior**

Document exact facts:

- Public total route count and milestone-owned route sets.
- Runtime protocol v1 compatibility and v2 runtime-eval negotiation.
- Network DNS/IP and redirect policy.
- Eval grammar and prohibited result types.
- Process argv/no-shell, timeout, cap, and terminal audit.
- Bulk plan hash, rollback, trash, `.uid` recovery, and repeat-recovery behavior.
- M5 export/Android environment behavior.
- Full test commands and fresh counts.

Replace the stale implementation-status report with a historical notice at its top that points to
the new audit and closure reports; preserve its old body as historical evidence.

- [ ] **Step 7: Self-check documentation and diff**

Run:

```powershell
rg -n 'M4.*未实现|M5.*未实现|M6.*未实现|runtime.*35.*全部|重新校验每个目标和重定向' README.md docs
git diff --check
git status --short
```

Expected: no stale capability claims and `git diff --check` exits 0. Read the closure report once
from top to bottom and reject any incomplete section before committing.

- [ ] **Step 8: Commit**

```bash
git add gdapi/rust/src/http.rs gdapi/rust/src/queue.rs cli/src/format/clap_style.rs README.md docs/security/high-risk-capabilities.md docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md docs/reports
git commit -m "docs: close full-capability roadmap remediation"
```

## Plan Self-Review

### Spec and Audit Coverage

| Audit finding | Remediation task |
|---|---|
| M3/M4 35-vs-36 route regression | Task 1 |
| Missing M6 fixture and contract suite | Task 1 |
| Runtime eval executes in editor | Task 2 |
| Protocol v2 not negotiated end to end | Task 2 |
| Eval comparison false positives and missing allowlist | Task 3 |
| DNS/IP/redirect SSRF gaps | Task 4 |
| Process/network terminal audit gaps | Task 5 |
| Bulk replace partial mutation | Task 6 |
| Delete/recover omits `.uid` lifecycle | Task 6 |
| Bulk deploy stale plan and partial-state gaps | Task 7 |
| M5 acceptance coverage is shallow | Task 7 |
| M2/M4 E2E duration prevents reliable full run | Task 8 |
| Three verified Clippy warnings remain | Task 9 |
| README/spec/security/status reports are stale | Task 9 |
| No fresh single-command closure | Task 9 |

### Type and Interface Consistency

- Protocol versions are integers throughout builder, broker, transport, and probe interfaces.
- Deferred terminal outcomes use the same `{ok, code, summary}` dictionary for every task.
- Route manifests are Python `set[str]` values imported by M2–M6 tests.
- Bulk plan operations use `before_sha256` and `after_sha256` consistently.
- M5/M6 fixtures expose the existing `exec_ok`, `exec_error`, and `command_doc` calling convention.

### Completion Gate

This plan is complete only after Task 9 records a fresh, single-command full E2E pass. Passing
individual suites is necessary but not sufficient.
