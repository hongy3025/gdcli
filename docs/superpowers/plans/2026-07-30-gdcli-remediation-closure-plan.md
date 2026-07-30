# gdcli Full-Capability Roadmap — Remediation Closure Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining gaps identified by the 2026-07-30 closure assessment: M3 contract regression, 5 missing M6 E2E files, M5 export/android defects, M2/M4 E2E duration budget, single-command full E2E pass, and final closure report.

**Architecture:** All code layers from Phase A–E of the original remediation are accepted as-is. This plan layers additive acceptance and operational fixes only. No new architecture; no spec-mutating decisions.

**Tech Stack:** Godot 4.7.x GDScript, godot-rust 0.5.4 `api-4-7`, Rust `std::process`, pytest/uv, gdtoolkit, existing gdcli HTTP/broker/file-transport infrastructure.

**Head before this plan:** `ed0b469 fix: resolve parse errors and add bulk deploy E2E tests`
**Pre-existing completion (per closure assessment 2026-07-30):** ~70%; see `docs/reports/2026-07-30-gdcli-full-capability-roadmap-remediation-completion-assessment.md`.
**Completion gate:** Closing this plan must produce (a) green `uv run pytest tests/e2e/ -v --durations=30` single-command run, (b) zero clippy warnings under default lint, and (c) the closure report committed. Passing individual suites is necessary but not sufficient.

## Global Constraints (inherited from upstream plan, restated for self-containment)

- Support only Godot 4.7.x.
- Preserve `gdcli exec <route> --data ...` as the only generic gdapi entry point.
- Preserve existing public route paths; do not add aliases.
- Keep Godot business logic in GDScript route/helper modules; Rust remains bounded host primitives.
- Every route accepts only POST JSON object body and uses the 10 standard error codes.
- Process execution never invokes a shell; timeout ≤ 60 s, combined output ≤ 1 MiB.
- Network response size ≤ 4 MiB; every resolved address and redirect target must pass the same policy.
- Before any unit or E2E test after changing `.gd` files, run `python scripts/format-gd.py`, `python scripts/format-gd.py --check`, and `gdlint` on every changed `.gd` file. Install with `uv tool install gdtoolkit` if missing.
- Helper scripts added by this plan must be Python `.py` files; do not add `.sh` or `.ps1` scripts.
- No test may be weakened to hide a product defect; milestone manifests must distinguish original and post-milestone routes explicitly.

## Phase Index

| Phase | Title | Closes |
|---|---|---|
| A | Contract and Fixture Closure | Task 1 finish line, M3 contract regression |
| B | M6 Safety and Audit Acceptance | Tasks 2/3/4/5/6 E2E files; deferred `finish` naming alignment |
| C | M5 Final-State Acceptance | Task 7 final-state failures |
| D | E2E Duration Budget | Task 8 module-scoped editors + reset state |
| E | Full Closure Run | Task 9 step 1–8 closure mechanics |

The remainder of this plan lists every checkbox, runnable command, and acceptance criterion grouped under its phase.

---

## Phase A — Contract and Fixture Closure

**Closes:** Task 1 finish line; `test_runtime_manifest_has_no_aliases` regression; missing M6 bulk fixture files.

**Source and Test Layout (Phase A only)**

| Path | Role |
|---|---|
| `tests/e2e/m3/test_m3_contract.py` | Update alias-assertion to recognise the post-M3 route |
| `tests/fixtures/m6_project/bulk/a.txt` | Minimal M6 bulk replace target |
| `tests/fixtures/m6_project/bulk/b.txt` | Minimal M6 bulk replace target |
| `tests/e2e/m2/test_m2_contract.py` | Reference `M3_RUNTIME_ROUTES` / `M6_ROUTES` from manifest |
| `tests/e2e/m5/test_m5_smoke.py` | Reference `M5_ROUTES` from manifest |

### Task A1 — Fix `test_runtime_manifest_has_no_aliases` to Accept the Post-M3 Route

**Files:**
- Modify: `tests/e2e/m3/test_m3_contract.py`

**Interface:** contract test must prove (a) no duplicates exist, (b) the runtime route set is exactly `M3_RUNTIME_ROUTES | {"runtime/eval"}`.

**Steps**

- [ ] **Step 1: Rewrite the assertions using the manifest**

```python
def test_runtime_manifest_has_no_aliases(m3_editor):
    runtime_routes = sorted(
        route for route in exec_ok(m3_editor, "gdapi/routes")["routes"]
        if route.startswith("runtime/")
    )
    # M3 owns exactly 35; the audit/closure flow adds `runtime/eval` from M6.
    assert runtime_routes == sorted(M3_RUNTIME_ROUTES | {"runtime/eval"})
```

The assertion no longer relies on the bare `36` count and instead compares the explicit set, satisfying the plan rule "milestone manifests must distinguish original and post-milestone routes explicitly".

- [ ] **Step 2: Run focused tests**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/m3/test_m3_contract.py -v
```

Expected: 4 passed (including the rewritten alias assertion).

- [ ] **Step 3: Commit**

```bash
git add tests/e2e/m3/test_m3_contract.py
git commit -m "test: accept post-M3 runtime/eval in alias assertion"
```

### Task A2 — Add M6 Bulk Fixture Files

**Files:**
- Create: `tests/fixtures/m6_project/bulk/a.txt`
- Create: `tests/fixtures/m6_project/bulk/b.txt`

**Steps**

- [ ] **Step 1: Add minimal replace targets**

`tests/fixtures/m6_project/bulk/a.txt`:

```
old-text-a
```

`tests/fixtures/m6_project/bulk/b.txt`:

```
old-text-b
```

Use ASCII (no UTF-8 BOM). Each file is non-empty so `bulk_file_service.gd::_validate_source` has a real diff to compute against.

- [ ] **Step 2: Run gdformat + gdlint gate (no `.gd` files were changed, skip gdlint on .gd)**

```powershell
python scripts/format-gd.py --check
```

Expected: exit 0 (only `.gd` files are formatted by this script).

- [ ] **Step 3: Commit**

```bash
git add tests/fixtures/m6_project/bulk
git commit -m "test: add M6 bulk replace fixture inputs"
```

### Task A3 — Reference Manifest Sets from M2 and M5 Smoke Contracts

**Files:**
- Modify: `tests/e2e/m2/test_m2_contract.py`
- Modify: `tests/e2e/m5/test_m5_smoke.py`

**Interface:** these suites must derive route sets from `tests/e2e/route_manifests.py` instead of hardcoded literals, so future post-milestone additions do not regress their `routes_match_current_public_surface`-style assertions.

**Steps**

- [ ] **Step 1: Search for hardcoded route lists in the two files**

```powershell
rg -n '^[^#]*"animation/"' tests/e2e/m2/test_m2_contract.py
rg -n '^[^#]*"project/settings/"' tests/e2e/m5/test_m5_smoke.py
```

Replace any literal set/sequence with the corresponding `M*_ROUTES` import from `e2e.route_manifests`.

- [ ] **Step 2: Update imports and assertions**

For M2:

```python
from e2e.route_manifests import M3_RUNTIME_ROUTES  # for negative-presence guard
M2_OWNED_ROUTES = <subset derivable from M3_RUNTIME_ROUTES>  # only if M2 needs explicit list
```

For M5:

```python
from e2e.route_manifests import M5_ROUTES
assert sorted(M5_OWNED) == sorted(M5_ROUTES)
```

Where `M5_OWNED` is derived from the live surface, not hardcoded.

- [ ] **Step 3: Run focused tests**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/m2/test_m2_contract.py tests/e2e/m5/test_m5_smoke.py -v
```

Expected: existing pass count unchanged; no new failures.

- [ ] **Step 4: Commit**

```bash
git add tests/e2e/m2/test_m2_contract.py tests/e2e/m5/test_m5_smoke.py
git commit -m "test: derive M2/M5 route contracts from manifest"
```

### Phase A Acceptance Gate

- `tests/e2e/m3/test_m3_contract.py`: 4 passed
- `tests/e2e/m5/test_m5_smoke.py`: unchanged (≥ original pass count)
- `tests/e2e/m2/test_m2_contract.py`: unchanged (≥ original pass count)
- `tests/fixtures/m6_project/bulk/{a,b}.txt` present in the working tree


---

## Phase B — M6 Safety and Audit Acceptance

**Closes:** Tasks 2/3/4/5/6 E2E files. The unit-level code changes already pass; this phase adds the missing E2E coverage and aligns the deferred registry `finish` callable name with the upstream plan interface.

**Source and Test Layout (Phase B only)**

| Path | Role |
|---|---|
| `tests/e2e/m6/conftest.py` | Extend with `m6_editor_eval`, `m6_editor_eval_policy`, `m6_editor_process`, `m6_editor_network`, `m6_editor_bulk` fixtures; `local_http_server` plugin; shared `start_async_exec` / `stop_game` / `apply_*` / `latest_audit` / `audit_for_route` helpers |
| `tests/e2e/m6/test_runtime_eval.py` | Task 2 E2E |
| `tests/e2e/m6/test_eval.py` | Task 3 E2E |
| `tests/e2e/m6/test_network_request.py` | Task 4 E2E |
| `tests/e2e/m6/test_process_run.py` | Task 5 E2E |
| `tests/e2e/m6/test_bulk_files.py` | Task 6 E2E |
| `gdapi/addon/runtime/deferred_task_registry.gd` | Rename task `terminal` callable to `finish` (interface alignment; downstream callers updated) |
| Every caller that uses `task["terminal"]` | Update to `task["finish"]` |

### Task B0 — Align Deferred Registry `finish` Interface

**Files:**
- Modify: `gdapi/addon/runtime/deferred_task_registry.gd`
- Modify: every site that registers a task with `"terminal": Callable` so the key becomes `"finish"`.

**Search for the existing key before editing:**

```powershell
rg -n '"terminal"\s*:' gdapi
```

Found sites in the current HEAD include `process_service.gd`, `network_service.gd`, `bulk_deploy_service.gd`, and other deferred callers. Each must use `"finish"` and accept `outcome: Dictionary -> void`.

**Steps**

- [ ] **Step 1: Add a deprecated-key fallback in the registry**

```gdscript
func _emit_terminal(task: Dictionary, outcome: Dictionary) -> void:
    if bool(task.get("terminal_written", false)):
        return
    task["terminal_written"] = true
    var callback: Variant = task.get("finish", task.get("terminal", null))
    if typeof(callback) == TYPE_CALLABLE and callback.is_valid():
        callback.call(outcome)
```

This lets old call sites (with `terminal`) keep working until Phase B is fully landed; new call sites use `finish`.

- [ ] **Step 2: Update all producers to set `"finish"`**

In each `*.gd` file that currently uses `"terminal"`, replace the key with `"finish"`. Every call receives the same `outcome: Dictionary` and ignores extra keys.

- [ ] **Step 3: Update every regression test for the registry**

`tests/fixture_project/tests/test_deferred_task_registry.gd` must construct tasks with `"finish"` (the existing unit covers the outcome shape; just rename the key inside the test fixtures).

- [ ] **Step 4: Run unit + gdscript suite**

```powershell
cargo test --workspace
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/test_gdscript_units.py -v
```

Expected: 22 passed, no regressions.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/deferred_task_registry.gd \
        tests/fixture_project/tests/test_deferred_task_registry.gd \
        $(rg -l '"terminal"\s*:' gdapi)
git commit -m "fix: align deferred registry finish callable"
```

### Task B1 — E2E for Protocol v2 Runtime Eval

**Files:**
- Modify: `tests/e2e/m6/conftest.py`
- Create: `tests/e2e/m6/test_runtime_eval.py`

**Interface:** produce `m6_editor_eval(policy)`, `m6_runtime_eval_running(env)` which spins up the running game via `project/run`; helpers `start_async_exec(env, route, body)` and `stop_game(env)`.

**Steps**

- [ ] **Step 1: Add fixtures that inject a runtime-eval-enabled policy and seed the running game fixture**

The fixture copies `tests/fixtures/m6_project` into `tmp_path`, writes `.godot/gdapi-policy.json`:

```json
{
  "runtime_eval": {
    "enabled": true,
    "max_source_bytes": 16384,
    "allowed_input_keys": ["runtime_marker"]
  },
  "process_run": {"enabled": true, "executables": ["sleep"], "cwd_roots": ["res://tools"], "max_timeout_ms": 5000, "max_output_bytes": 65536},
  "filesystem_batch": {"enabled": true, "roots": ["res://bulk"]},
  "network_http_request": {"enabled": true, "schemes": ["http"], "hosts": ["127.0.0.1", "localhost"], "ports": [80, 443], "max_timeout_ms": 5000, "max_response_bytes": 1048576, "max_redirects": 5, "allow_private": true},
  "export_android_deploy_many": {"enabled": true, "apk_root": "res://build", "package": "org.example"}
}
```

Then it attaches an editor and runs `project/run` against a `main.gd` that sets `runtime_marker = 41` and idles the scene tree.

- [ ] **Step 2: Write the disconnected-runtime and live-game assertions**

```python
def test_runtime_eval_requires_running_probe(m6_editor_eval):
    error = exec_error(
        m6_editor_eval, "runtime/eval",
        {"source": "1 + 1", "force": True},
    )
    assert error["code"] == "conflict"


def test_runtime_eval_runs_only_in_game_process(m6_runtime_eval_running):
    result = exec_ok(
        m6_runtime_eval_running, "runtime/eval",
        {"source": "runtime_marker + 1", "inputs": {"runtime_marker": 41}, "force": True},
    )
    assert result["value"] == 42
    # Editor-side eval must remain reachable with the same source.
    editor_result = exec_ok(
        m6_runtime_eval_running, "editor/eval",
        {"source": "runtime_marker + 1", "inputs": {"runtime_marker": 41}, "force": True},
    )
    assert editor_result["value"] == 42


def test_runtime_eval_disconnect_completes_once(m6_runtime_eval_running):
    pending = start_async_exec(
        m6_runtime_eval_running, "runtime/eval",
        {"source": "runtime_marker + 1", "inputs": {"runtime_marker": 41}, "force": True},
    )
    stop_game(m6_runtime_eval_running)
    assert pending.result(timeout=5)["code"] == "conflict"
    assert exec_ok(m6_runtime_eval_running, "runtime/status")["pending"] == 0
```

- [ ] **Step 3: Run focused tests**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/m6/test_runtime_eval.py -v
```

Expected: 3 passed; editor-side and game-side eval both yield 42; pending count returns to zero after disconnect.

- [ ] **Step 4: Commit**

```bash
git add tests/e2e/m6/conftest.py tests/e2e/m6/test_runtime_eval.py tests/fixtures/m6_project
git commit -m "test: cover runtime eval across v1/v2 boundaries"
```

### Task B2 — E2E for Eval Allow/Deny Matrix and Audit Redaction

**Files:**
- Modify: `tests/e2e/m6/conftest.py`
- Create: `tests/e2e/m6/test_eval.py`

**Steps**

- [ ] **Step 1: Add `latest_audit(env, route)` helper**

Reads `gdapi/audit/list` and returns the most recent event whose `route` matches; uses the same `exec_ok` helper.

- [ ] **Step 2: Add the matrix assertions**

```python
ALLOWED_EDITOR = [
    ("a + b", {"a": 1, "b": 2}, 3),
    ("a <= b and a != 0", {"a": 1, "b": 2}, True),
    ("Vector2(a, b) + Vector2(1, 1)", {"a": 1, "b": 2}, {"type": "Vector2", "value": [2.0, 3.0]}),
]

DENIED_EDITOR = [
    ("instance_from_id(1)", {}),
    ("Engine", {}),
    ("a = b", {"a": 1, "b": 2}),  # assignment
    ("a.b", {"a": 1}),  # member access
]


@pytest.mark.parametrize("source,inputs,expected", ALLOWED_EDITOR)
def test_editor_eval_allow(m6_editor_eval, source, inputs, expected):
    body = {"source": source, "inputs": inputs, "force": True}
    result = exec_ok(m6_editor_eval, "editor/eval", body)
    assert result["value"] == expected


@pytest.mark.parametrize("source,inputs", DENIED_EDITOR)
def test_editor_eval_deny(m6_editor_eval, source, inputs):
    body = {"source": source, "inputs": inputs, "force": True}
    error = exec_error(m6_editor_eval, "editor/eval", body)
    assert error["code"] == "permission_denied"


def test_eval_source_never_appears_in_audit(m6_editor_eval):
    secret = "41 + 1"
    exec_ok(m6_editor_eval, "editor/eval", {"source": secret, "force": True})
    event = latest_audit(m6_editor_eval, "editor/eval")
    assert secret not in json.dumps(event)
    assert event["ok"] is True
```

- [ ] **Step 3: Run focused tests**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/m6/test_eval.py -v
```

Expected: every parameterised case passes; audit redaction confirmed.

- [ ] **Step 4: Commit**

```bash
git add tests/e2e/m6/conftest.py tests/e2e/m6/test_eval.py
git commit -m "test: cover eval allow/deny matrix and audit redaction"
```

### Task B3 — E2E for Network Target Guard and Redirect Re-validation

**Files:**
- Modify: `tests/e2e/m6/conftest.py`
- Create: `tests/e2e/m6/test_network_request.py`

**Steps**

- [ ] **Step 1: Add a `local_http_server` fixture (Python `http.server`)**

Provide endpoints:

| Path | Behaviour |
|---|---|
| `/ok` | 200 with body `payload-ok` |
| `/large` | 200 with body ≤ 64 KiB |
| `/delay` | Sleeps 10 s before responding (for timeout test) |
| `/redirect-ok` | 302 to `/ok` |
| `/redirect-private` | 302 to `http://10.0.0.1/` |
| `/redirect-loop` | 302 to `/redirect-loop` |

Server binds to `127.0.0.1` on an ephemeral port.

- [ ] **Step 2: Add the assertions**

```python
def test_dns_name_resolving_to_private_address_is_denied(m6_editor_network):
    # Use a literal host on a denied range to avoid DNS flakiness.
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": "http://10.0.0.1/ok", "force": True,
    })
    assert error["code"] == "permission_denied"


def test_redirect_to_private_target_is_denied(m6_editor_network, local_http_server):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/redirect-private"), "force": True,
    })
    assert error["code"] == "permission_denied"


def test_redirect_loop_is_rejected(m6_editor_network, local_http_server):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/redirect-loop"), "force": True,
    })
    assert error["code"] in {"conflict", "permission_denied"}


def test_redirect_to_allowed_target_succeeds(m6_editor_network, local_http_server):
    result = exec_ok(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/redirect-ok"), "force": True,
    })
    assert result["status"] == 200
    assert result["redirects"] == 1


def test_timeout_returns_timeout_code(m6_editor_network, local_http_server):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/delay"), "timeout_ms": 500, "force": True,
    })
    assert error["code"] == "timeout"


def test_response_cap_truncates_or_errors(m6_editor_network, local_http_server):
    result = exec_ok(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/large"), "max_response_bytes": 1024, "force": True,
    })
    assert result["size"] <= 1024
    assert result["truncated"] is True


def test_audit_redacts_body_and_headers(m6_editor_network, local_http_server):
    exec_ok(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/ok"), "force": True,
    })
    event = latest_audit(m6_editor_network, "network/http_request")
    body = json.dumps(event)
    # local HTTP server is plain http://127.0.0.1, no Authorization/Cookie/secret expected.
    assert "Authorization" not in body and "Cookie" not in body
    assert "payload-ok" not in body  # response body must not leak into audit
```

- [ ] **Step 3: Run focused tests**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/m6/test_network_request.py -v
```

Expected: 7 passed; timeout / cap / redaction semantics confirmed.

- [ ] **Step 4: Commit**

```bash
git add tests/e2e/m6/conftest.py tests/e2e/m6/test_network_request.py
git commit -m "test: cover DNS/IP/redirect network safety"
```

### Task B4 — E2E for Process Run Terminal Audits

**Files:**
- Modify: `tests/e2e/m6/conftest.py`
- Create: `tests/e2e/m6/test_process_run.py`

**Steps**

- [ ] **Step 1: Add `audit_for_route(env, route)` helper that returns the full list**

- [ ] **Step 2: Add the assertions**

```python
def test_process_run_requires_force(m6_editor_process):
    error = exec_error(m6_editor_process, "process/run", {
        "executable": "sleep", "args": ["0"], "cwd": "res://tools",
    })
    assert error["code"] in {"invalid_param", "unsafe_operation"}


def test_process_run_no_shell_preserves_argv(m6_editor_process, exec_with_capture):
    result = exec_with_capture(["echo_args.py"])
    assert result["exit_code"] == 0
    # echo_args.py prints argv as JSON; ensure shell metacharacters survive literally.
    assert '"a;b"' in result["stdout"]
    assert '"$(whoami)"' in result["stdout"]


def test_process_run_timeout_has_one_failed_terminal_audit(m6_editor_process):
    error = exec_error(m6_editor_process, "process/run", {
        "executable": "sleep", "args": ["10"], "cwd": "res://tools",
        "timeout_ms": 200, "force": True,
    })
    assert error["code"] == "timeout"
    events = audit_for_route(m6_editor_process, "process/run")
    timeout_events = [e for e in events if e.get("code") == "timeout"]
    assert len(timeout_events) == 1


def test_process_run_plugin_shutdown_cancels_with_no_child(m6_editor_process):
    start_async = start_async_exec(m6_editor_process, "process/run", {
        "executable": "sleep", "args": ["30"], "cwd": "res://tools",
        "force": True,
    })
    detach_editor(m6_editor_process)
    response = start_async.result(timeout=5)
    assert response["code"] == "conflict"
```

- [ ] **Step 3: Run focused tests**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/m6/test_process_run.py -v
```

Expected: 4 passed; no child `sleep` process remains after teardown.

- [ ] **Step 4: Commit**

```bash
git add tests/e2e/m6/conftest.py tests/e2e/m6/test_process_run.py
git commit -m "test: cover process run terminal audit semantics"
```

### Task B5 — E2E for Bulk File Transactional Semantics

**Files:**
- Modify: `tests/e2e/m6/conftest.py`
- Create: `tests/e2e/m6/test_bulk_files.py`

**Steps**

- [ ] **Step 1: Add helpers**

`replace_plan(env, root, find, replace) -> dict`
`apply_replace(env, plan) -> dict | Error`
`inject_apply_failure(env, fail_after: int)` (sets a flag the test reads)
`bulk_digest(env) -> str`
`delete_plan(env, paths) -> dict`
`apply_delete(env, plan) -> dict`
`project_file(env, rel) -> Path`
`latest_audit(env, route) -> dict`

- [ ] **Step 2: Add the assertions**

```python
def test_replace_dry_run_then_apply(m6_editor_bulk):
    plan = replace_plan(m6_editor_bulk, root="res://bulk", find="old-text", replace="new-text")
    assert plan["ok"]
    digest = bulk_digest(m6_editor_bulk)
    result = apply_replace(m6_editor_bulk, plan)
    assert result["ok"]
    assert bulk_digest(m6_editor_bulk) != digest


def test_replace_rolls_back_when_second_apply_fails(m6_editor_bulk):
    plan = replace_plan(m6_editor_bulk, root="res://bulk", find="old-text", replace="new-text")
    inject_apply_failure(m6_editor_bulk, fail_after=1)
    before = bulk_digest(m6_editor_bulk)
    error = apply_replace(m6_editor_bulk, plan)
    assert error["code"] == "godot_error"
    assert bulk_digest(m6_editor_bulk) == before


def test_stale_plan_returns_conflict(m6_editor_bulk):
    plan = replace_plan(m6_editor_bulk, root="res://bulk", find="old-text", replace="new-text")
    project_file(m6_editor_bulk, "bulk/a.txt").write_text("external edit")
    error = apply_replace(m6_editor_bulk, plan)
    assert error["code"] == "conflict"


def test_delete_recover_restores_uid_and_is_not_repeatable(m6_editor_bulk):
    plan = delete_plan(m6_editor_bulk, ["res://bulk/a.txt"])
    deleted = apply_delete(m6_editor_bulk, plan)
    assert deleted["ok"]
    assert not project_file(m6_editor_bulk, "bulk/a.txt").exists()
    assert not project_file(m6_editor_bulk, "bulk/a.txt.uid").exists()
    exec_ok(m6_editor_bulk, "filesystem/batch/recover", {
        "operation_id": deleted["operation_id"], "force": True,
    })
    assert project_file(m6_editor_bulk, "bulk/a.txt").exists()
    assert project_file(m6_editor_bulk, "bulk/a.txt.uid").exists()
    error = exec_error(m6_editor_bulk, "filesystem/batch/recover", {
        "operation_id": deleted["operation_id"], "force": True,
    })
    assert error["code"] == "conflict"
```

- [ ] **Step 3: Run focused tests**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/m6/test_bulk_files.py -v
```

Expected: 4 passed; rollback, stale-plan, and repeat-recover all behave correctly.

- [ ] **Step 4: Commit**

```bash
git add tests/e2e/m6/conftest.py tests/e2e/m6/test_bulk_files.py
git commit -m "test: cover bulk file transactional semantics"
```

### Phase B Acceptance Gate

- `tests/e2e/m6/test_runtime_eval.py`: 3 passed
- `tests/e2e/m6/test_eval.py`: ≥ 8 passed (parametrised)
- `tests/e2e/m6/test_network_request.py`: 7 passed
- `tests/e2e/m6/test_process_run.py`: 4 passed
- `tests/e2e/m6/test_bulk_files.py`: 4 passed
- `tests/e2e/test_gdscript_units.py`: 22 passed (no regression from `finish` rename)
- Deferred registry contract: every task now uses `"finish"`; `"terminal"` fallback remains only for in-flight call sites and is removed in a later phase if used by none.


---

## Phase C — M5 Final-State Acceptance

**Closes:** Task 7 outstanding defects:
1. `tests/e2e/m5/test_export_android.py::test_export_run_returns_matching_artifact_digest` — gdcli times out 5 s on `export/run`.
2. `tests/e2e/m5/test_export_android.py::test_android_routes_are_deterministic_without_real_device` — returns `unknown` instead of `not_supported`.

**Source and Test Layout (Phase C only)**

| Path | Role |
|---|---|
| `gdapi/addon/routes/export/run.gd` | Inspect export timeout and headless handling |
| `gdapi/addon/runtime/services/export_service.gd` | Restore real PCK production in fixtures |
| `gdapi/addon/runtime/services/android_bridge.gd` | Replace `unknown` with `not_supported` for `parse_failed` and missing-platform branches |
| `tests/fixtures/m5_project/export_presets.cfg` | Confirm Windows-trusted preset |
| `tests/e2e/m5/test_export_android.py` | Adjust test to call `export/run` after `gdcli install` plus correct fixture setup |

### Task C1 — Make `export/run` Complete Inside the Headless Fixture

The current test produces a 5-second `Network Error: timed out reading response` because `gdcli exec` cancels before Godot finishes writing the PCK. Root causes (in priority order):

1. The fixture preset may require a `linux/` export template that is missing.
2. The fixture may not request headless export mode, so the editor stalls waiting for UI.
3. The test may not install the addon into the fixture project or fails to pick up the `gdapi.json`.

**Files:**
- Modify: `tests/fixtures/m5_project/export_presets.cfg`
- Modify: `gdapi/addon/routes/export/run.gd` and `gdapi/addon/runtime/services/export_service.gd` if needed
- Modify: `tests/e2e/m5/test_export_android.py` if needed

**Steps**

- [ ] **Step 1: Reproduce the timeout with extra logging**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
$env:RUST_LOG=debug
uv run pytest tests/e2e/m5/test_export_android.py::test_export_run_returns_matching_artifact_digest -v -s
```

Inspect the captured `godot_log_tail` to find the export stage that stalls.

- [ ] **Step 2: Choose a remediation path**

Pick exactly one of the following paths based on what Step 1 reveals. Do **not** invent new options.

- **Path A — fix the preset**: rewrite `export_presets.cfg` to a platform whose template the host has installed (e.g. `windows` or skip export entirely and assert `not_supported`); update the test to expect `not_supported`.
- **Path B — fix the route**: make `export/run` honour `--export-debug --headless` flags that the fixture already passes via `force + preset`, or fall back to a PCK-only mode and write the PCK even when no runtime template is present, returning `{ok: true, sha256: ..., bytes: ...}` with `truncated:true` and a stable `code:"godot_error"` otherwise.
- **Path C — fix the test**: if the route works but the fixture is misconfigured, the test must adjust the fixture inputs (preset name, output path, force flag) and re-run; document the input in the fixture doc comment.

- [ ] **Step 3: Apply the chosen fix**

Whichever path was selected, the change must:

- Never weaken the route by returning success without producing a verifiable artefact.
- Keep the audit log single-shot.
- Document the chosen path in the route's `doc()` so the user contract stays accurate.

- [ ] **Step 4: Re-run and confirm green**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/m5/test_export_android.py::test_export_run_returns_matching_artifact_digest -v
```

Expected: PASS, and the artefact file matches the response `sha256`.

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/m5_project/export_presets.cfg \
        gdapi/addon/routes/export/run.gd \
        gdapi/addon/runtime/services/export_service.gd \
        tests/e2e/m5/test_export_android.py
git commit -m "fix: close M5 export_run headless timeout"
```

### Task C2 — Map Android `unknown` to `not_supported`

The `unknown` literal leaks from `_status_from_text` when `adb devices` returns an empty or unexpected stderr. Standard routes must use the 10 stable error codes only.

**Files:**
- Modify: `gdapi/addon/runtime/services/android_bridge.gd`
- Modify: `tests/fixture_project/tests/test_android_bridge.gd`

**Steps**

- [ ] **Step 1: Locate every literal `"unknown"` in the bridge**

```powershell
rg -n 'unknown' gdapi/addon/runtime/services/android_bridge.gd
```

- [ ] **Step 2: Replace each `"unknown"` with the appropriate stable code**

Use the table below:

| Previous value | Replacement |
|---|---|
| `status: "unknown"` for missing adb | `status: "missing"`, code stays `not_supported` |
| `status: "unknown"` for parse error | `status: "parse_failed"`, code stays `not_supported` |
| `status: "unknown"` for offline device | `status: "offline"`, code stays `not_found` |

The "stable code" stays under the existing error code path; only the `status` field changes.

- [ ] **Step 3: Update the unit test fixtures**

`tests/fixture_project/tests/test_android_bridge.gd` asserts status strings; update those assertions to match the new vocabulary. Do not weaken: test the same 3 cases (missing adb, parse error, offline device) more strictly.

- [ ] **Step 4: Run unit + focused M5 tests**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/m5/test_export_android.py -v
```

Expected: 1 unit suite unchanged in count; M5 export_android tests pass.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/android_bridge.gd \
        tests/fixture_project/tests/test_android_bridge.gd
git commit -m "fix: replace unknown with stable android statuses"
```

### Task C3 — Run Full M5 Suite

**Steps**

- [ ] **Step 1: Run the full M5 directory**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/m5 -v --durations=20
```

Expected: ≥ 10 passed; 0 failed. The two previously failing tests must be green; no new failures from C1/C2 fallout.

- [ ] **Step 2: Commit only if any incidental fixup is required**

```bash
git add tests/e2e/m5 tests/fixtures/m5_project gdapi/addon/routes/export/run.gd
git commit -m "test: close M5 final-state acceptance"
```

### Phase C Acceptance Gate

- `tests/e2e/m5/`: ≥ 10 passed, 0 failed
- `export/run` produces a verifiable artefact OR returns stable `not_supported`
- `android_bridge.gd` uses no `"unknown"` literal; unit test asserts the new statuses


---

## Phase D — E2E Duration Budget

**Closes:** Task 8 module-scoped editors and reset state. Current observed baseline:

| Suite | Time |
|---|---:|
| `tests/e2e/m2` | 527 s |
| `tests/e2e/m4` | 311 s |

Target after Phase D: combined local warm-build time ≤ 6 minutes (360 s). Acceptable allocation: M2 ≤ 240 s, M4 ≤ 180 s.

**Source and Test Layout (Phase D only)**

| Path | Role |
|---|---|
| `tests/e2e/m2/conftest.py` | Convert `m2_editor` to `scope="module"`; add `reset_project_state` autouse |
| `tests/e2e/m4/conftest.py` | Same for M4 |
| `tests/e2e/m2/test_fixture_isolation.py` | Add reset-isolation regression tests |
| `tests/e2e/m4/test_m4_contract.py` | Update fixture isolation helpers |
| `tests/e2e/test_full_suite_budget.py` | Assert total duration ≤ 6 minutes on warm runs |

### Task D1 — Module-Scoped Editor + Reset State in M2

**Files:**
- Modify: `tests/e2e/m2/conftest.py`
- Modify: `tests/e2e/m2/test_fixture_isolation.py`

**Steps**

- [ ] **Step 1: Capture the current baseline**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/m2 tests/e2e/m4 -v --durations=30
```

Record the M2/M4 totals; they become the upper bound for "before". Commit the durations in the commit message body.

- [ ] **Step 2: Add `reset_project_state(env)`**

```python
def reset_project_state(env: dict[str, Any]) -> None:
    project = Path(env["project"])
    fixture_root = repo_root() / "tests" / "fixtures" / "m2_project"
    # 1) Restore mutable files from the source fixture.
    shutil.copytree(fixture_root, project, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns(".godot"))
    # 2) Stop the running game if any.
    subprocess.run(
        [str(env["gdcli"]), "--json", "exec", "project/stop", "--project", str(project)],
        capture_output=True, check=False,
    )
    # 3) Reopen the fixture main scene.
    subprocess.run(
        [str(env["gdcli"]), "--json", "exec", "scene/open",
         "--project", str(project),
         "--data", json.dumps({"scene_path": "res://main.tscn"})],
        capture_output=True, check=False,
    )
    # 4) Clear selection + audit log.
    subprocess.run(
        [str(env["gdcli"]), "--json", "exec", "editor/selection/set",
         "--project", str(project), "--data", json.dumps({"nodes": []})],
        capture_output=True, check=False,
    )
    subprocess.run(
        [str(env["gdcli"]), "--json", "exec", "gdapi/audit/clear",
         "--project", str(project), "--data", json.dumps({"force": True})],
        capture_output=True, check=False,
    )
    # 5) Reinstall addon + reimport.
    subprocess.run(
        [str(env["gdcli"]), "install", "--project", str(project), "--force"],
        capture_output=True, check=False,
    )
```

- [ ] **Step 3: Convert fixtures**

Change `@pytest.fixture` to `@pytest.fixture(scope="module")` for `m2_editor` and add the autouse:

```python
@pytest.fixture(autouse=True)
def isolated_test_state(m2_editor):
    reset_project_state(m2_editor)
    before = project_snapshot(m2_editor)
    yield
    reset_project_state(m2_editor)
    assert_project_snapshot(m2_editor, before)
```

- [ ] **Step 4: Add a regression test**

```python
def test_reset_restores_files_scene_and_selection(m2_editor):
    mutate_scene_file_and_selection(m2_editor)
    reset_project_state(m2_editor)
    assert tree_digest(m2_editor["project"]) == before_tree_digest(m2_editor["project"])
    assert exec_ok(m2_editor, "editor/selection/get")["nodes"] == []
```

- [ ] **Step 5: Run M2 with durations**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/m2 -v --durations=20
```

Expected: combined warm-build M2 ≤ 240 s, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add tests/e2e/m2/conftest.py tests/e2e/m2/test_fixture_isolation.py
git commit -m "test: reuse isolated module-scoped M2 editor"
```

### Task D2 — Module-Scoped Editor + Reset State in M4

**Files:**
- Modify: `tests/e2e/m4/conftest.py`
- Modify: `tests/e2e/m4/test_m4_contract.py` if it owns isolation helpers

**Steps**

- [ ] **Step 1: Mirror Task D1 changes**

Apply the same `scope="module"` change and add `isolated_test_state` autouse, scoped to `m4_editor`. Adjust `reset_project_state` to the M4 fixture root when present, otherwise reuse the M2 reset helper.

- [ ] **Step 2: Run M4 with durations**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/m4 -v --durations=20
```

Expected: combined warm-build M4 ≤ 180 s, 0 failed.

- [ ] **Step 3: Commit**

```bash
git add tests/e2e/m4/conftest.py tests/e2e/m4/test_m4_contract.py
git commit -m "test: reuse isolated module-scoped M4 editor"
```

### Task D3 — Add `tests/e2e/test_full_suite_budget.py`

**Files:**
- Create: `tests/e2e/test_full_suite_budget.py`

**Interface:** a single coarse-grained test that times the full-suite run and asserts it under the budget using pytest hooks. Alternative: a `pytest.ini`-friendly `--budget=` command-line option. Choose the coarse-grained test (simpler) unless the project already uses a `--budget` option.

**Steps**

- [ ] **Step 1: Write the budget assertion**

```python
import json
import subprocess
import sys
from pathlib import Path
import pytest

BUDGET_SECONDS = 6 * 60


def test_full_suite_under_budget():
    root = Path(__file__).resolve().parents[2]
    cmd = [sys.executable, "-m", "pytest", "tests/e2e/", "-q", "--durations=20", "-x"]
    result = subprocess.run(cmd, cwd=root, capture_output=True, text=True, timeout=BUDGET_SECONDS + 30)
    assert result.returncode == 0, result.stdout + result.stderr
    durations = [line for line in result.stdout.splitlines() if "slowest" in line or "=" in line]
    # Parse pytest --durations output for the total elapsed at end of summary.
    tail = result.stdout.splitlines()[-10:]
    elapsed = next((float(t.split()[2]) for t in tail if t.startswith("=====")), None)
    assert elapsed is not None
    assert elapsed <= BUDGET_SECONDS, f"full suite took {elapsed:.1f}s, budget is {BUDGET_SECONDS}s"
```

- [ ] **Step 2: Run the budget test**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/test_full_suite_budget.py -v
```

Expected: 1 passed within budget; or skip with explicit "exceeds budget" message if the cold-cache budget cannot be met.

- [ ] **Step 3: Commit**

```bash
git add tests/e2e/test_full_suite_budget.py
git commit -m "test: assert full-suite duration budget"
```

### Phase D Acceptance Gate

- `tests/e2e/m2` warm run ≤ 240 s
- `tests/e2e/m4` warm run ≤ 180 s
- `tests/e2e/test_full_suite_budget.py` passes
- Combined M2+M4 ≤ 360 s on a clean .pytest_cache


---

## Phase E — Full Closure Run

**Closes:** Task 9 step 1–8 closure mechanics: residual clippy warning, GDScript format/lint gates, milestone suite green, single-command full E2E pass, README/spec/security/status updates, closure report commit.

### Task E1 — Remove the Remaining `assertions_on_constants` Clippy Warning

**Files:**
- Modify: `gdapi/rust/src/http.rs`

**Steps**

- [ ] **Step 1: Locate the warning**

```powershell
cargo clippy --workspace --all-targets
```

The lint names the offending assertion (around `gdapi/rust/src/http.rs:261`):

```rust
assert!(MAX_HEADER_BYTES < MAX_BODY);
```

- [ ] **Step 2: Move the assertion into a const block**

```rust
const _: () = assert!(MAX_HEADER_BYTES < MAX_BODY);
```

`MAX_HEADER_BYTES` and `MAX_BODY` stay at module scope; only the assertion site changes.

- [ ] **Step 3: Re-run clippy**

```powershell
cargo clippy --workspace --all-targets
```

Expected: zero warnings under default lint.

- [ ] **Step 4: Commit**

```bash
git add gdapi/rust/src/http.rs
git commit -m "fix: silence http constants assertion clippy warning"
```

### Task E2 — GDScript Format + Lint Gates

**Steps**

- [ ] **Step 1: Install gdtoolkit if needed**

```powershell
if (-not (Get-Command gdformat -ErrorAction SilentlyContinue) -or
    -not (Get-Command gdlint -ErrorAction SilentlyContinue)) {
    uv tool install gdtoolkit
}
```

- [ ] **Step 2: Run format + check**

```powershell
python scripts/format-gd.py
python scripts/format-gd.py --check
```

Expected: both exit 0.

- [ ] **Step 3: Lint changed `.gd` files**

```powershell
$gdFiles = @(git diff --name-only --diff-filter=ACMR | Where-Object { $_ -like '*.gd' })
if ($gdFiles.Count -gt 0) { gdlint $gdFiles }
```

Expected: zero errors.

- [ ] **Step 4: Commit (only if format/lint made changes)**

```bash
git add $(git diff --name-only --diff-filter=ACMR | Where-Object { $_ -like '*.gd' })
git commit -m "style: format and lint gd sources"
```

### Task E3 — Rust + GDScript Unit Verification

**Steps**

- [ ] **Step 1: Verify Rust surface**

```powershell
cargo fmt --check
cargo clippy --workspace --all-targets
cargo test --workspace
```

Expected: all exit 0; 0 clippy warnings; 202+ passed.

- [ ] **Step 2: Verify GDScript unit suite**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/test_gdscript_units.py -v
```

Expected: ≥ 22 passed.

- [ ] **Step 3: Commit (only incidental fixes)**

```bash
git add <incidental>
git commit -m "fix: incidental closure verification"
```

### Task E4 — Milestone Suite Green

**Steps**

- [ ] **Step 1: Run each milestone suite sequentially**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/m2 tests/e2e/m3 tests/e2e/m4 tests/e2e/m5 tests/e2e/m6 -v --durations=20
```

Expected: every milestone suite exits 0 with zero skipped tests. Route counts prove:

- M3 owns exactly 35 routes
- M4 owns exactly 51 routes
- M5 owns exactly 27 routes
- M6 owns exactly 8 routes

### Task E5 — Single-Command Full E2E Pass

**Steps**

- [ ] **Step 1: Capture process baseline**

```powershell
$baselineTestIds = @(
    Get-CimInstance Win32_Process |
    Where-Object {
        $_.CommandLine -match 'pytest-of-|tests[\\/](fixture_project|fixtures)'
    } |
    ForEach-Object { $_.ProcessId }
)
```

- [ ] **Step 2: Run the full E2E suite once**

```powershell
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/ -v --durations=30
```

Expected: exit 0, zero failed, zero skipped, no outer timeout, no output-flush exception.

- [ ] **Step 3: Verify process cleanup**

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

Expected: 0 leftover processes.

### Task E6 — Documentation Updates

**Files:**
- Modify: `README.md`
- Modify: `docs/security/high-risk-capabilities.md`
- Modify: `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`
- Modify: `docs/reports/2026-07-29-gdcli-roadmap-implementation-status.md`
- Create: `docs/reports/2026-07-30-gdcli-full-capability-roadmap-remediation-closure.md`

**Steps**

- [ ] **Step 1: Update README.md**

Find the "M3 增补 35 个 runtime 路由" paragraph (around line 391). Replace the implicit "35 routes, no later additions" claim with:

```
M3 增补 35 个 runtime 路由（`runtime/...`）；M6 引入 `runtime/eval` 作为 v2
协议下运行进程内执行的能力，必须在 broker 协商 v2 后才能路由。
```

- [ ] **Step 2: Refresh security doc**

`docs/security/high-risk-capabilities.md` already mentions DNS / redirect re-validation. Replace the existing summary of "M6 未实现" with a one-paragraph summary that mirrors the freshly-verified behaviour in `network_target_guard.gd`, `deferred_task_registry.gd`, and `bulk_file_service.gd`. Cite the new closure report at the bottom.

- [ ] **Step 3: Update spec to mark M6 ✅**

In `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`, after the `### M6：高风险能力` heading, replace the bare "内容：" block with:

```
### M6：高风险能力 ✅ 已完成

（实际验收见 `docs/reports/2026-07-30-gdcli-full-capability-roadmap-remediation-closure.md`）
```

Add the same status note to `### M5：项目、诊断与发布` and `### M4：游戏系统域` if they lack the ✅ marker and are now backed by fresh E2E numbers.

- [ ] **Step 4: Replace the stale status report**

`docs/reports/2026-07-29-gdcli-roadmap-implementation-status.md` was correct on 2026-07-29 but is now stale. Replace its top with a `> 历史快照：2026-07-29 状态；自 2026-07-30 起被本目录中最新报告替代。` and add a "最新报告" pointer to the closure report. Keep the body as historical evidence.

- [ ] **Step 5: Write the closure report**

`docs/reports/2026-07-30-gdcli-full-capability-roadmap-remediation-closure.md` must include:

- HEAD commit, branch, Godot version, single-command test command used.
- Passed / failed / skipped counts, total duration, route counts per milestone.
- Per-task completion summary (Phase A–E of this plan).
- Any deferred item explicitly excluded from this closure (with rationale).
- Clippy warning count (= 0).
- Process cleanup confirmation (no leftover godot/gdcli/pytest processes).
- Link to upstream audit and remediation plan.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/security/high-risk-capabilities.md \
        docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md \
        docs/reports/2026-07-29-gdcli-roadmap-implementation-status.md \
        docs/reports/2026-07-30-gdcli-full-capability-roadmap-remediation-closure.md
git commit -m "docs: close full-capability remediation"
```

### Phase E Acceptance Gate

- `cargo clippy --workspace --all-targets`: 0 warnings
- `cargo test --workspace`: 202+ passed
- `tests/e2e/test_gdscript_units.py`: ≥ 22 passed
- `tests/e2e/m{2,3,4,5,6}/`: all exit 0
- Full single-command run (`uv run pytest tests/e2e/ -v --durations=30`): exit 0, 0 failed, 0 skipped
- Process cleanup: 0 leftover godot/gdcli/pytest processes
- Documentation updates merged with closure report
- No stale "M4/M5/M6 未实现" phrase remains in `README.md` or `docs/`

## Plan Self-Review

### Spec and Completion Coverage

| Closure-assessment gap | Plan task |
|---|---|
| `test_runtime_manifest_has_no_aliases` regression | A1 |
| Missing M6 bulk fixture files | A2 |
| M2 / M5 smoke contract using hardcoded lists | A3 |
| 5 missing M6 E2E files (Tasks 2/3/4/5/6) | B1–B5 |
| Deferred registry `finish` callable alignment | B0 |
| `export/run` headless timeout | C1 |
| Android `unknown` → stable status vocabulary | C2 |
| M5 full suite green | C3 |
| M2/M4 module-scoped editors + reset | D1, D2 |
| Full-suite duration budget assertion | D3 |
| Residual clippy warning | E1 |
| GDScript format/lint gates | E2 |
| Rust + GDScript unit verification | E3 |
| Milestone suite green | E4 |
| Single-command full E2E pass | E5 |
| README / security / spec / status updates + closure report | E6 |

### Type and Interface Consistency

- Deferred terminal outcomes: still `{ok: bool, code: String, summary: String}`; only the producer-side callback name changes from `terminal` to `finish`.
- Route manifests: Python `set[str]` sourced from `tests/e2e/route_manifests.py`; M2/M5 tests import instead of hardcoding.
- Bulk plan operations: `before_sha256` / `after_sha256` / `plan_hash` already standardised in upstream plan.
- M5/M6 fixtures: reuse the `exec_ok` / `exec_error` / `command_doc` calling convention introduced in Phase 1.

### Completion Gate

This plan is complete only after Phase E step 5 ("Single-Command Full E2E Pass") exits 0 with zero leftover processes and Phase E step 6 commits the closure report. Passing individual phase gates is necessary but not sufficient.
