# gdcli M6 High-Risk Capabilities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicitly gated eval, process, network, and bulk mutation capabilities with enforceable target/timeout/output limits and complete redacted audit evidence.

**Architecture:** A deny-by-default policy file under `.godot` is loaded independently of route bodies, so a caller cannot enable its own privileges. Every high-risk route passes through one policy gate before touching its domain service. The editor plugin owns a deferred-task registry: a route may retain its `GdApiResponse`, register one bounded task, and the plugin polls that task from `_process()` until it sends exactly one terminal response. Process execution is implemented in Rust for reliable argv-only spawning, output caps, timeout, and child termination; network requests run through an `HTTPRequest` node owned by that registry. File operations remain synchronous but use verified plans, reversible staging, and bounded work.

**Tech Stack:** Godot 4.7 Expression/HTTPRequest APIs, Rust std::process GDExtension runner, M1–M5 audit/path/runtime/export contracts, pytest/uv.

## Global Constraints

- Support only Godot 4.7.x and require completed M1–M5 plans.
- Policy path is `.godot/gdapi-policy.json`; it is never writable through gdapi routes.
- Missing, malformed, unknown-version, or over-permissive policy data fails closed.
- Capabilities are independently enabled: `editor_eval`, `runtime_eval`, `process`, `network`, `bulk_files`, and `bulk_deploy`.
- Route-body flags can only narrow policy; they cannot enable a capability or expand an allowlist.
- Every high-risk route requires `force:true`, including expressions intended to be read-only.
- Never invoke a shell. Process input is executable plus argv; metacharacters have no special meaning.
- Process timeout defaults to 5 seconds, policy maximum is at most 60 seconds, combined output maximum is at most 1 MiB, and killed children are reaped.
- Network has no implicit scheme or host access: the enabled policy explicitly lists allowed schemes, hosts, and ports; every redirect is revalidated. It rejects credentials in URLs and blocks loopback/link-local/private/multicast/unspecified destinations unless the enabled policy explicitly allows the resolved target. Response cap is at most 4 MiB.
- Eval source is at most 16 KiB, uses Godot `Expression`, exposes a fixed data dictionary, and never binds arbitrary Object instances.
- Bulk file operations require a dry-run plan hash; apply must present the same hash and fails if any source digest changed.
- Batch delete moves files to `.godot/gdapi-trash/<operation-id>` and returns a recovery manifest.
- Success, failure, timeout, policy denial, validation rejection, rollback, and recovery are audited without tokens, Authorization/Cookie headers, environment secrets, eval source, or raw process output.

## File Structure

| File | Responsibility after M6 |
|---|---|
| `gdapi/addon/runtime/capability_policy.gd` | Parse/cache strict project policy and authorize route requests |
| `gdapi/addon/runtime/deferred_task_registry.gd` | Plugin-owned polling/lifecycle for routes that respond after `handle()` returns |
| `gdapi/rust/src/process_runner.rs` | Shell-free bounded child process lifecycle |
| `gdapi/addon/runtime/services/eval_service.gd` | Restricted editor/runtime Expression execution |
| `gdapi/addon/runtime/services/network_service.gd` | URL/DNS/redirect validation and bounded HTTPRequest |
| `gdapi/addon/runtime/services/bulk_file_service.gd` | Dry-run hashes, atomic replace, trash manifests, rollback |
| `gdapi/addon/runtime/services/bulk_deploy_service.gd` | Confirmed multi-device deployment orchestration |
| `gdapi/addon/routes/{editor,runtime,process,network,filesystem,export}/**` | Public M6 routes |
| `tests/fixtures/m6_project/**` | Isolated fixture project plus controlled executable/network/file targets |
| `tests/e2e/m6/**` | Default-deny, sandbox-boundary, timeout, rollback, and audit acceptance |

---

### Task 1: Add Strict Capability Policy and Audit Redaction

**Files:**
- Create: `gdapi/addon/runtime/capability_policy.gd`
- Create: `gdapi/addon/runtime/deferred_task_registry.gd`
- Modify: `gdapi/addon/runtime/audit_log.gd`
- Modify: `gdapi/addon/plugin.gd`
- Create: `tests/fixtures/m6_project/project.godot`
- Create: `tests/fixtures/m6_project/bulk/{a,b}.txt`
- Create: `tests/e2e/m6/conftest.py`
- Create: `tests/fixture_project/tests/test_capability_policy.gd`
- Create: `tests/fixture_project/tests/test_deferred_task_registry.gd`
- Modify: `tests/e2e/test_gdscript_units.py`

**Interfaces:**
- Produces `authorize(capability:String,route:String,body:Dictionary) -> Dictionary`.
- Policy schema is `{version:1,capabilities:{name:{enabled:bool}}}` plus the exact capability-specific limit fields defined in Tasks 3–7.
- Extends the existing `GdApiAuditLog.summarize()` redaction contract; no parallel redactor is introduced.
- Produces `register(task)`, `tick(now_ms)`, and `cancel_all(reason)` for plugin-owned deferred tasks. A task owns its retained response and must emit one terminal response or be failed on timeout/plugin shutdown.
- Produces isolated pytest fixtures `m6_editor_denied`, `m6_editor_process`, `m6_editor_eval`, `m6_editor_network`, `m6_editor_bulk`, and `m6_editor_bulk_deploy`; each writes its policy directly to the copied project's `.godot/gdapi-policy.json` before addon startup.
- Produces `local_http_server` with `/ok`, `/large`, `/delay`, and controlled redirect endpoints bound to loopback; only the network-enabled test policy may allow that exact host and port.
- Produces test helpers `bulk_replace_plan`, `apply_bulk_replace`, `wait_for_audit`, `latest_audit`, and `contains_secret` used by later M6 tasks.
- Produces positional `command_doc(env,route)` for the final high-risk documentation contract.

- [ ] **Step 1: Write fail-closed and redaction tests**

```gdscript
func test_missing_policy_denies() -> void:
	var policy := CapabilityPolicy.new("res://missing-policy.json")
	assert_eq(policy.authorize("process", "process/run", {"force":true}).code, "permission_denied")

func test_force_and_capability_are_both_required() -> void:
	var policy := policy_from({"version":1,"capabilities":{"process":{"enabled":true}}})
	assert_eq(policy.authorize("process", "process/run", {}).code, "unsafe_operation")
	assert_true(policy.authorize("process", "process/run", {"force":true}).ok)

func test_audit_log_removes_nested_secrets() -> void:
	var clean := GdApiAuditLog.summarize({"Authorization":"Bearer secret","nested":{"token":"abc"},"safe":"value"})
	assert_eq(clean, {"Authorization":"[REDACTED]","nested":{"token":"[REDACTED]"},"safe":"value"})
```

- [ ] **Step 2: Run policy/redactor units**

Run: `uv run pytest tests/e2e/test_gdscript_units.py -v -k "capability_policy or deferred_task_registry"`

Expected: FAIL because the policy and task registry are absent.

- [ ] **Step 3: Implement strict schema, canonicalization, and redaction**

Reject unknown top-level keys, unknown capability names, non-boolean enabled values, negative limits, and policy files outside `.godot/gdapi-policy.json`. Cache by mtime but retain the last denial state on parse failure. Extend the existing audit summarizer only where necessary: it must redact `source`, `stdout`, `stderr`, environment fields, and nested header values without weakening its current token/cookie protection. The plugin creates the registry in `_enter_tree`, ticks it before polling new HTTP requests, and cancels every pending task in `_exit_tree`. Implement the pytest fixtures by copying `m6_project`, writing one exact least-privilege policy before Godot startup, and asserting teardown leaves no editor, child process, pending task, or temporary operation directory. Start the controlled HTTP server in a Python thread and shut it down in fixture finalization.

- [ ] **Step 4: Verify policy reload and audit path identity**

Run: `uv run pytest tests/e2e/test_gdscript_units.py -v -k "capability_policy or deferred_task_registry"`

Expected: PASS; changing policy mtime reloads it and malformed replacement denies all capabilities.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/capability_policy.gd gdapi/addon/runtime/deferred_task_registry.gd gdapi/addon/runtime/audit_log.gd gdapi/addon/plugin.gd tests/fixtures/m6_project tests/e2e/m6/conftest.py tests/fixture_project/tests tests/e2e/test_gdscript_units.py
git commit -m "feat: add high-risk capability policy"
```

---

### Task 2: Add a Shell-Free Rust Process Runner

**Files:**
- Create: `gdapi/rust/src/process_runner.rs`
- Modify: `gdapi/rust/src/lib.rs`
- Create: `gdapi/rust/tests/process_runner_test.rs`
- Create: `tests/fixtures/m6_project/tools/echo_args.py`
- Create: `tests/fixtures/m6_project/tools/sleep.py`
- Create: `tests/fixtures/m6_project/tools/emit_output.py`

**Interfaces:**
- Exposes Godot class `GdApiProcessRunner` with `start(executable:String,args:PackedStringArray,cwd:String,timeout_ms:int,max_output_bytes:int) -> int`, `poll(id:int) -> Dictionary`, and `cancel(id:int) -> bool`.
- Terminal poll result is `{done:true,exit_code,timed_out,cancelled,stdout,stderr,truncated}` and is returned once before job removal.

- [ ] **Step 1: Write Rust tests for argv fidelity, cap, timeout, and reaping**

```rust
#[test]
fn preserves_arguments_without_shell_expansion() {
    let result = run_fixture(&["literal;value", "$(not-run)", "space value"], 2_000, 65_536);
    assert_eq!(result.exit_code, Some(0));
    assert!(result.stdout.contains("literal;value"));
    assert!(result.stdout.contains("$(not-run)"));
}

#[test]
fn kills_and_reaps_after_timeout() {
    let result = run_sleep_fixture(50, 200);
    assert!(result.timed_out);
    assert!(result.elapsed_ms < 2_000);
}

#[test]
fn caps_combined_output() {
    let result = run_output_fixture(100_000, 1_024);
    assert!(result.truncated);
    assert!(result.stdout.len() + result.stderr.len() <= 1_024);
}
```

- [ ] **Step 2: Run focused Rust tests**

Run: `cargo test -p gdapi process_runner -- --nocapture`

Expected: FAIL because `process_runner` is absent.

- [ ] **Step 3: Implement process jobs with no shell**

Use `std::process::Command::new(executable).args(args).current_dir(cwd)`, piped stdout/stderr reader threads, a shared byte budget, `try_wait` polling, and `Child::kill` followed by `wait` on deadline/cancel. Store jobs behind `Arc<Mutex<HashMap<i64, Job>>>`; reject nonpositive limits before spawn and never inherit stdin.

- [ ] **Step 4: Verify Rust runner and workspace**

Run: `cargo test -p gdapi process_runner -- --nocapture && cargo test --workspace`

Expected: PASS with no child process remaining after tests.

- [ ] **Step 5: Commit**

```bash
git add gdapi/rust/src/process_runner.rs gdapi/rust/src/lib.rs gdapi/rust/tests/process_runner_test.rs tests/fixtures/m6_project/tools/echo_args.py
git commit -m "feat: add bounded shell-free process runner"
```

---

### Task 3: Add Policy-Gated Process Execution

**Files:**
- Create: `gdapi/addon/runtime/services/process_service.gd`
- Create: `gdapi/addon/routes/process/run.gd`
- Modify: `gdapi/addon/plugin.gd`
- Create: `tests/e2e/m6/test_process_run.py`

**Interfaces:**
- `process/run` consumes `{executable,args=[],cwd="res://",timeout_ms=5000,max_output_bytes=65536,force}`.
- Policy process block is `{enabled,executables:Array[String],cwd_roots:Array[String],max_timeout_ms,max_output_bytes}`.
- Returns `{ok,changed:true,undoable:false,exit_code,timed_out,stdout,stderr,truncated}`.

- [ ] **Step 1: Write default-deny, literal argv, allowlist, timeout, and cap tests**

```python
def test_process_is_denied_by_default(m6_editor_denied):
    error = exec_error(m6_editor_denied, "process/run", {
        "executable":"python", "args":["--version"], "force":True
    })
    assert error["code"] == "permission_denied"


def test_process_argv_is_literal(m6_editor_process):
    script = str(m6_editor_process["project"] / "tools" / "echo_args.py")
    result = exec_ok(m6_editor_process, "process/run", {
        "executable":sys.executable,
        "args":[script,"literal;value","$(not-run)","space value"],
        "cwd":"res://", "force":True
    })
    assert json.loads(result["stdout"]) == ["literal;value", "$(not-run)", "space value"]


def test_process_timeout_is_a_stable_error(m6_editor_process):
    script = str(m6_editor_process["project"] / "tools" / "sleep.py")
    error = exec_error(m6_editor_process, "process/run", {
        "executable":sys.executable,"args":[script,"10"],
        "timeout_ms":50,"force":True
    })
    assert error["code"] == "timeout"
```

- [ ] **Step 2: Run process E2E tests**

Run: `uv run pytest tests/e2e/m6/test_process_run.py -v`

Expected: default-deny passes after Task 1; enabled cases FAIL because route/service are absent.

- [ ] **Step 3: Implement policy intersection and asynchronous polling**

Canonicalize executable, require exact policy membership, normalize cwd through PathGuard/read, and require it under one configured root. Clamp requested limits downward to policy limits. Start the Rust runner and register a process task with the plugin-owned deferred-task registry; the registry polls it from the editor process loop and sends exactly one response. Map spawn failure to `godot_error`, timeout to `timeout`, policy/force failures to their standard codes, and nonzero process exit to a successful transport result with `ok:true` and the actual exit code. Plugin shutdown cancels the job and responds only if the HTTP connection remains live.

- [ ] **Step 4: Verify all process boundaries and audit redaction**

Run: `uv run pytest tests/e2e/m6/test_process_run.py -v`

Expected: PASS; executable prefix tricks, parent cwd, oversized limits, environment injection fields, and cancellation are rejected or bounded; audit contains no args marked secret and no output.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/process_service.gd gdapi/addon/routes/process/run.gd gdapi/addon/plugin.gd tests/e2e/m6/test_process_run.py
git commit -m "feat: add policy-gated process execution"
```

---

### Task 4: Add Restricted Editor and Runtime Eval

**Files:**
- Create: `gdapi/addon/runtime/services/eval_service.gd`
- Create: `gdapi/addon/routes/editor/eval.gd`
- Create: `gdapi/addon/routes/runtime/eval.gd`
- Modify: `tests/e2e/m2/test_m2_contract.py`
- Modify: `gdapi/addon/runtime/runtime_protocol.gd`
- Modify: `gdapi/addon/runtime/runtime_probe.gd`
- Create: `tests/fixture_project/tests/test_eval_service.gd`
- Create: `tests/e2e/m6/test_eval.py`

**Interfaces:**
- Both routes consume `{source,inputs={},force}` and return encoded `{value,type,elapsed_ms,undoable:false}`.
- Policy block is `{enabled,max_source_bytes,allowed_input_keys}`.
- Expression inputs contain only JSON primitives and VariantCodec values; no Node, Resource, Callable, RID, Script, or Object is exposed.

- [ ] **Step 1: Write denial, typed result, and object-escape tests**

```python
def test_editor_eval_typed_math(m6_editor_eval):
    result = exec_ok(m6_editor_eval, "editor/eval", {
        "source":"origin + delta",
        "inputs":{
            "origin":{"type":"Vector2","value":[1,2]},
            "delta":{"type":"Vector2","value":[3,4]}
        },
        "force":True,
    })
    assert result["value"] == {"type":"Vector2","value":[4.0,6.0]}


@pytest.mark.parametrize("source", [
    "Engine.get_main_loop()", "load('res://project.godot')", "OS.execute('x', [])",
    "while true: pass", "func(): return 1",
])
def test_eval_rejects_object_access_and_statements(m6_editor_eval, source):
    assert exec_error(m6_editor_eval, "editor/eval", {"source":source,"force":True})["code"] == "permission_denied"
```

- [ ] **Step 2: Run eval unit/E2E tests**

Run: `uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/m6/test_eval.py -v -k eval`

Expected: FAIL because eval service/routes are absent.

- [ ] **Step 3: Implement fixed-input Expression execution**

Token-scan and reject statement delimiters, assignment, object/global identifiers, preload/load, function/lambda syntax, and method calls; permit arithmetic, comparisons, boolean operators, literals, constructors supported by VariantCodec, and the provided input names. Parse with `Expression.parse(source,input_names)`, execute with input values and `base_instance=null`, and treat execution failure as `invalid_param`. Runtime eval delegates the same source/inputs to the M3 probe and uses the same evaluator. Because protocol v1 explicitly denies `eval`, first introduce protocol v2: preserve v1 message validation for existing operations, advertise the negotiated version in the broker/probe handshake, and allow only the new `eval` operation in v2.

Extend the M2 inventory test with `POST_M2_EDITOR_ROUTES = {"editor/eval"}` and assert the selected editor-prefixed route subset equals the existing M2 editor subset plus that set; do not relabel eval as an M2 capability. Do not replace the current global baseline/missing-route assertions with an exact all-route assertion, because M3–M6 legitimately add routes.

```python
POST_M2_EDITOR_ROUTES = {"editor/eval"}
# In a new editor-family subset assertion in test_m2_contract.py:
assert selected == M2_EDITOR_ROUTES | POST_M2_EDITOR_ROUTES
```

- [ ] **Step 4: Verify policy, force, typing, size, and audit**

Run: `uv run pytest tests/e2e/m6/test_eval.py -v`

Expected: PASS; source never appears in audit, and runtime disconnect returns `conflict` with no pending request.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/eval_service.gd gdapi/addon/routes/editor/eval.gd gdapi/addon/routes/runtime/eval.gd gdapi/addon/runtime/runtime_protocol.gd gdapi/addon/runtime/runtime_probe.gd tests/e2e/m2/test_m2_contract.py tests/fixture_project/tests/test_eval_service.gd tests/e2e/m6/test_eval.py
git commit -m "feat: add restricted editor and runtime eval"
```

---

### Task 5: Add Validated Network Requests

**Files:**
- Create: `gdapi/addon/runtime/services/network_service.gd`
- Create: `gdapi/addon/routes/network/http_request.gd`
- Modify: `gdapi/addon/plugin.gd`
- Create: `tests/e2e/m6/test_network_request.py`

**Interfaces:**
- Consumes `{url,method="GET",headers={},body="",timeout_ms=5000,max_response_bytes=1048576,force}`.
- Policy block is `{enabled,schemes,hosts,ports,allow_private,max_timeout_ms,max_response_bytes}`.
- Returns `{status,headers,body_base64,size,sha256,redirects,undoable:false}`.

- [ ] **Step 1: Write local controlled-server, redirect, DNS, cap, and redaction tests**

```python
def test_network_default_denial(m6_editor_denied, local_http_server):
    error = exec_error(m6_editor_denied, "network/http_request", {
        "url":local_http_server.url("/ok"),"force":True
    })
    assert error["code"] == "permission_denied"


def test_allowed_response_and_cap(m6_editor_network, local_http_server):
    result = exec_ok(m6_editor_network, "network/http_request", {
        "url":local_http_server.url("/ok"),"force":True,"max_response_bytes":1024
    })
    assert base64.b64decode(result["body_base64"]) == b"known-response"
    error = exec_error(m6_editor_network, "network/http_request", {
        "url":local_http_server.url("/large"),"force":True,"max_response_bytes":32
    })
    assert error["code"] == "unsafe_operation"
```

Add the exact network rejection matrix and audit check:

```python
@pytest.mark.parametrize("url,code", [
    ("http://user:pass@allowed.test/", "invalid_param"),
    ("http://allowed.test.evil.invalid/", "permission_denied"),
    ("http://allowed.test:6553/", "permission_denied"),
    ("http://10.0.0.1/", "permission_denied"),
])
def test_network_target_rejections(m6_editor_network, url, code):
    assert exec_error(m6_editor_network, "network/http_request", {"url":url,"force":True})["code"] == code


def test_redirect_timeout_method_and_redaction(m6_editor_network, local_http_server):
    assert exec_error(m6_editor_network, "network/http_request", {"url":local_http_server.url("/redirect-private"),"force":True})["code"] == "permission_denied"
    assert exec_error(m6_editor_network, "network/http_request", {"url":local_http_server.url("/redirect-loop"),"force":True})["code"] == "conflict"
    assert exec_error(m6_editor_network, "network/http_request", {"url":local_http_server.url("/delay"),"timeout_ms":25,"force":True})["code"] == "timeout"
    assert exec_error(m6_editor_network, "network/http_request", {"url":local_http_server.url("/ok"),"method":"TRACE","force":True})["code"] == "permission_denied"
    exec_error(m6_editor_network, "network/http_request", {"url":local_http_server.url("/delay"),"headers":{"Authorization":"Bearer secret","Cookie":"session=secret"},"timeout_ms":25,"force":True})
    assert not contains_secret(latest_audit(m6_editor_network))
```

- [ ] **Step 2: Run network E2E tests**

Run: `uv run pytest tests/e2e/m6/test_network_request.py -v`

Expected: default-deny passes; enabled cases FAIL because the network route is absent.

- [ ] **Step 3: Implement validation before every HTTPRequest**

Parse URL, reject userinfo/fragments, match exact host or `*.` suffix policy on label boundaries, resolve DNS, and classify every returned IPv4/IPv6 address. The network service creates an `HTTPRequest` node under the plugin, configures its timeout/body cap/TLS validation with redirects disabled, and registers the request with the deferred-task registry. Follow at most five redirects manually by resolving `Location` and repeating every policy/DNS check. Permit only GET/HEAD by default; other policy-allowed methods require force and bounded body. Strip hop-by-hop response headers and encode bytes. The task always frees its `HTTPRequest` node on completion, timeout, cancellation, or plugin exit.

- [ ] **Step 4: Verify SSRF, redirect, timeout, and output limits**

Run: `uv run pytest tests/e2e/m6/test_network_request.py -v`

Expected: PASS; all rejected requests leave the controlled server hit counter unchanged when rejection occurs before transport.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/network_service.gd gdapi/addon/routes/network/http_request.gd gdapi/addon/plugin.gd tests/e2e/m6/test_network_request.py
git commit -m "feat: add policy-gated network requests"
```

---

### Task 6: Add Dry-Run-Hashed Bulk Delete and Replace

**Files:**
- Create: `gdapi/addon/runtime/services/bulk_file_service.gd`
- Create: `gdapi/addon/routes/filesystem/batch/{delete,replace}.gd`
- Create: `gdapi/addon/routes/filesystem/batch/recover.gd`
- Modify: `tests/e2e/m2/test_m2_contract.py`
- Create: `tests/e2e/m6/test_bulk_files.py`

**Interfaces:**
- Dry run bodies set `dry_run:true`; response includes canonical ordered operations and SHA-256 `plan_hash`.
- Apply repeats the body with `dry_run:false`, `plan_hash`, and `force:true`.
- Delete returns `operation_id` and recovery manifest; replace supports literal or regex with explicit `regex:true` and maximum 1,000 files/10,000 replacements.

- [ ] **Step 1: Write plan-hash, race, rollback, and recovery tests**

```python
def test_bulk_delete_requires_unchanged_plan_and_is_recoverable(m6_editor_bulk):
    body = {"paths":["res://bulk/a.txt","res://bulk/b.txt"],"dry_run":True,"force":True}
    plan = exec_ok(m6_editor_bulk, "filesystem/batch/delete", body)
    applied = exec_ok(m6_editor_bulk, "filesystem/batch/delete", {
        **body,"dry_run":False,"plan_hash":plan["plan_hash"]
    })
    assert applied["deleted"] == 2
    assert not (m6_editor_bulk["project"] / "bulk" / "a.txt").exists()
    recovered = exec_ok(m6_editor_bulk, "filesystem/batch/recover", {
        "operation_id":applied["operation_id"],"force":True
    })
    assert recovered["restored"] == 2


def test_changed_source_invalidates_plan(m6_editor_bulk):
    plan = bulk_replace_plan(m6_editor_bulk, "old", "new")
    target = m6_editor_bulk["project"] / "bulk" / "a.txt"
    target.write_text("raced", encoding="utf-8")
    error = apply_bulk_replace(m6_editor_bulk, plan)
    assert error["code"] == "conflict"
    assert target.read_text(encoding="utf-8") == "raced"
```

- [ ] **Step 2: Run bulk file tests**

Run: `uv run pytest tests/e2e/m6/test_bulk_files.py -v`

Expected: FAIL because batch routes are absent.

- [ ] **Step 3: Implement canonical planning and rollback**

Normalize/sort paths, include each source digest and operation parameters in canonical JSON, and hash it. Recompute immediately before apply. Delete moves each file plus a sibling `.uid` when present to a unique trash directory and writes `manifest.json`; on any failure move completed entries back. Do not move Godot's derived `.godot/imported` cache. Replace writes sibling temporary files, closes them, then swaps sequentially while retaining originals in the operation directory; rollback every prior swap on failure. GDScript exposes no portable `fsync`, so the contract promises close-before-rename and recoverable rollback rather than durability across power loss. Recover rejects destination conflicts rather than overwriting.

Extend the M2 inventory test with `POST_M2_FILESYSTEM_ROUTES = {"filesystem/batch/delete","filesystem/batch/replace","filesystem/batch/recover"}` and assert the selected filesystem-prefixed route subset equals the existing M2 filesystem subset plus this set. Preserve the historical baseline/missing-route assertions rather than treating the entire repository route table as M2-only.

```python
POST_M2_FILESYSTEM_ROUTES = {
    "filesystem/batch/delete", "filesystem/batch/replace", "filesystem/batch/recover",
}
# Preserve POST_M2_EDITOR_ROUTES from Task 4 and compare only the selected family:
assert selected == M2_FILESYSTEM_ROUTES | POST_M2_FILESYSTEM_ROUTES
```

- [ ] **Step 4: Verify caps, rollback, recovery, and audit**

Run: `uv run pytest tests/e2e/m6/test_bulk_files.py -v`

Expected: PASS; traversal/protected paths, stale plan, excessive matches, invalid regex, injected failure, and recovery conflict have no unreported partial state.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/bulk_file_service.gd gdapi/addon/routes/filesystem/batch tests/e2e/m2/test_m2_contract.py tests/e2e/m6/test_bulk_files.py
git commit -m "feat: add recoverable bulk file operations"
```

---

### Task 7: Add Confirmed Multi-Device Deployment

**Files:**
- Create: `gdapi/addon/runtime/services/bulk_deploy_service.gd`
- Create: `gdapi/addon/routes/export/android/deploy_many.gd`
- Modify: `tests/e2e/m5/test_m5_smoke.py`
- Create: `tests/e2e/m6/test_bulk_deploy.py`

**Interfaces:**
- Dry run consumes `{serials,apk_path,package,activity,dry_run:true,force:true}` and returns `plan_hash` plus ordered devices/artifact digest.
- Apply requires unchanged `plan_hash`, `dry_run:false`, force, and `bulk_deploy` policy.
- Result contains one terminal entry per serial and never silently retries another device.

- [ ] **Step 1: Write policy, plan, partial-failure, and audit tests with fake bridge**

```python
def test_bulk_deploy_reports_each_selected_device(m6_editor_bulk_deploy):
    plan = exec_ok(m6_editor_bulk_deploy, "export/android/deploy_many", {
        "serials":["device-a","device-b"],"apk_path":"res://build/app.apk",
        "package":"org.gdcli.fixture","activity":"com.godot.game.GodotApp",
        "dry_run":True,"force":True
    })
    result = exec_ok(m6_editor_bulk_deploy, "export/android/deploy_many", {
        "serials":["device-a","device-b"],"apk_path":"res://build/app.apk",
        "package":"org.gdcli.fixture","activity":"com.godot.game.GodotApp",
        "dry_run":False,"plan_hash":plan["plan_hash"],"force":True
    })
    assert result["devices"] == [
        {"serial":"device-a","ok":True,"code":""},
        {"serial":"device-b","ok":False,"code":"godot_error"},
    ]
```

- [ ] **Step 2: Run fake-bridge deployment tests**

Run: `uv run pytest tests/e2e/m6/test_bulk_deploy.py -v`

Expected: FAIL because service/route are absent.

- [ ] **Step 3: Implement sequential confirmed deployment**

Extend the existing Android bridge with a narrowly scoped command-execution seam used only by tests; production keeps resolving the configured Android SDK ADB path. Require every serial currently online and unique, include APK digest in the plan hash, and deploy in sorted serial order. Continue after a device-specific failure so every selected device gets a terminal result, but return overall `changed` only when at least one install succeeded. Audit one parent operation plus one redacted child event per serial.

Extend `tests/e2e/m5/test_m5_smoke.py` with `POST_M5_EXPORT_ROUTES = {"export/android/deploy_many"}` and assert the selected export-prefixed route subset equals the existing M5 export subset plus that set. Preserve the existing M5 smoke/inclusion assertions for all other families.

```python
POST_M5_EXPORT_ROUTES = {"export/android/deploy_many"}
# In test_m5_route_families_are_registered:
assert selected == M5_EXPORT_ROUTES | POST_M5_EXPORT_ROUTES
```

- [ ] **Step 4: Verify stale artifact/device list and default denial**

Run: `uv run pytest tests/e2e/m6/test_bulk_deploy.py -v`

Expected: PASS; a changed APK, missing device, duplicate serial, or disabled policy prevents all installs.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/android_bridge.gd gdapi/addon/runtime/services/bulk_deploy_service.gd gdapi/addon/routes/export/android/deploy_many.gd tests/e2e/m5/test_m5_smoke.py tests/e2e/m6/test_bulk_deploy.py
git commit -m "feat: add confirmed bulk Android deployment"
```

---

### Task 8: Prove Default Denial, Redacted Audit, and Full Capability Closure

**Files:**
- Create: `tests/e2e/m6/test_m6_contract.py`
- Create: `docs/security/high-risk-capabilities.md`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`

**Interfaces:**
- M6 adds the following high-risk routes: `editor/eval`, `runtime/eval`, `process/run`, `network/http_request`, three filesystem batch routes, and `export/android/deploy_many`. The M6 contract asserts this selected set and does not reinterpret prior-milestone route inventories as a global exact set.
- Security documentation contains a minimal deny policy and separate least-privilege examples for each capability.

- [ ] **Step 1: Add a cross-capability default-deny/audit matrix**

```python
HIGH_RISK_CASES = [
    ("editor/eval", {"source":"1+1","force":True}),
    ("runtime/eval", {"source":"1+1","force":True}),
    ("process/run", {"executable":"python","args":[],"force":True}),
    ("network/http_request", {"url":"https://example.invalid","force":True}),
    ("filesystem/batch/delete", {"paths":["res://a"],"dry_run":True,"force":True}),
    ("filesystem/batch/replace", {"root":"res://","find":"a","replace":"b","dry_run":True,"force":True}),
    ("filesystem/batch/recover", {"operation_id":"none","force":True}),
    ("export/android/deploy_many", {"serials":[],"apk_path":"res://a.apk","dry_run":True,"force":True}),
]


@pytest.mark.parametrize("route,body", HIGH_RISK_CASES)
def test_every_high_risk_route_denied_and_audited(m6_editor_denied, route, body):
    before = exec_ok(m6_editor_denied, "gdapi/audit/list")["total"]
    error = exec_error(m6_editor_denied, route, body)
    assert error["code"] == "permission_denied"
    event = wait_for_audit(m6_editor_denied, before)
    assert event["route"] == route and event["ok"] is False
    assert not contains_secret(event)


def test_every_high_risk_route_has_complete_docs(m6_editor_denied):
    for route, _body in HIGH_RISK_CASES:
        doc = command_doc(m6_editor_denied, route)
        assert doc["summary"] and doc["params"] and doc["examples"]
        assert doc["returns"]["fields"]
```

- [ ] **Step 2: Run complete M6 security tests**

Run: `uv run pytest tests/e2e/m6 -v`

Expected: PASS with zero child processes, pending HTTP requests, temporary replacements, unreconciled rollback directories, or undeclared device actions.

- [ ] **Step 3: Write least-privilege policy and recovery documentation**

Document exact policy schema, reload behavior, each limit, route-to-capability mapping, argv-not-shell semantics, SSRF protections, eval grammar, bulk plan hash, trash recovery, deployment confirmation, and audit redaction. Include a warning that enabling a capability grants local project callers the configured scope.

- [ ] **Step 4: Run full repository and security verification**

Run:

```bash
cargo fmt --check
cargo clippy --workspace
cargo test --workspace
uv run pytest tests/e2e/ -v
git diff --check
```

Expected: all required commands exit 0 on Godot 4.7.x; only the M5 opt-in physical-device positive test may skip.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/m6 docs/security/high-risk-capabilities.md README.md docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md
git commit -m "docs: complete M6 high-risk capability milestone"
```
