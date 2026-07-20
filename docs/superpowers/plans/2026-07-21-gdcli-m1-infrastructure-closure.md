# gdcli M1 Infrastructure Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the existing gdapi infrastructure baseline on Godot 4.7 so later route families can reuse one verified router, request contract, path/variant/UndoRedo helper set, mutation safety model, audit model, and E2E harness.

**Architecture:** Keep `gdcli exec` and the Rust HTTP/GDScript business-logic boundary unchanged. Upgrade the GDExtension binding to Godot 4.7, make the router and request layer deterministic, then migrate the existing file-oriented routes onto shared safety contracts. Prove editor UndoRedo through a fixture-only editor test plugin; do not add a test-only production route.

**Tech Stack:** Rust 2021 workspace, godot-rust 0.5.4 with `api-4-7`, Godot 4.7.x GDExtension/GDScript, clap, pytest managed by uv, PowerShell-compatible Python development scripts.

## Global Constraints

- Support only Godot 4.7.x; do not preserve build, runtime, CI, or E2E compatibility for Godot 4.3–4.6.
- Use `godot = { version = "0.5.4", features = ["api-4-7"] }` and commit the resulting `Cargo.lock` update.
- Keep `gdcli exec <route> --data <JSON>` as the only generic gdapi user entry point.
- Keep the existing natural route names; do not restore canonical/legacy aliases.
- Keep Rust GDExtension free of Godot scene/resource business logic.
- Keep all auxiliary development scripts in Python; do not add `.sh` or `.ps1` files.
- Existing public route semantics must remain compatible; add validation and response fields without silently repurposing a route.
- Current edited-scene mutations use UndoRedo; file/resource/runtime mutations return `undoable:false`.
- Overwrite, deletion, batch replacement, and other dangerous mutations require `force:true` and audit both success and failure.
- Standard error codes are exactly: `missing_param`, `invalid_param`, `invalid_path`, `not_found`, `conflict`, `not_supported`, `permission_denied`, `unsafe_operation`, `timeout`, `godot_error`.
- Every task follows red-green-refactor and ends in a focused commit.

## File Structure

| File | Responsibility after M1 |
|---|---|
| `gdapi/rust/Cargo.toml` / `Cargo.lock` | Pin a godot-rust release that exposes Godot 4.7 API level |
| `gdapi/addon/gdapi.gdextension` | Declare Godot 4.7 as the minimum runtime |
| `gdapi/addon/runtime/request.gd` | Parse only valid JSON object bodies and expose parse errors |
| `gdapi/addon/runtime/router.gd` | Discover exactly the files on disk, reload changed scripts, remove deleted routes, dispatch four built-ins |
| `gdapi/addon/runtime/path_guard.gd` | Normalize and validate read/write/delete project paths |
| `gdapi/addon/runtime/variant_codec.gd` | Perform checked JSON-to-Variant conversion |
| `gdapi/addon/runtime/edit_action.gd` | Commit property changes through `EditorUndoRedoManager` |
| `gdapi/addon/runtime/audit_log.gd` | Record bounded, secret-free mutation events |
| `gdapi/addon/routes/**/*.gd` | Use shared validation/error/mutation contracts |
| `tests/fixture_project/tests/*.gd` | Headless GDScript unit tests for runtime helpers |
| `tests/fixture_project/addons/gdapi_test/*` | Fixture-only editor plugin that proves real editor UndoRedo |
| `tests/e2e/conftest.py` | Build/install/start lifecycle and strict Godot 4.7 preflight |
| `tests/e2e/test_m1_*.py` | Public-route, safety, audit, helper, and UndoRedo acceptance tests |

---

### Task 1: Move the Build and Test Baseline to Godot 4.7 Only

**Files:**
- Modify: `gdapi/rust/Cargo.toml:11-13`
- Modify: `Cargo.lock`
- Modify: `gdapi/addon/gdapi.gdextension:1-7`
- Modify: `tests/fixture_project/project.godot:12-17`
- Modify: `tests/e2e/conftest.py:1-95`
- Create: `tests/e2e/test_version_gate.py`
- Modify: `README.md:12-27`

**Interfaces:**
- Consumes: executable path from `GODOT_BIN`, defaulting to `godot`.
- Produces: `parse_godot_version(output: str) -> tuple[int, int, int]` and `require_godot_47(godot_bin: str) -> tuple[int, int, int]` in `tests/e2e/conftest.py`.
- Produces: a GDExtension compiled against `api-4-7` and rejected by runtimes older than 4.7.

- [ ] **Step 1: Add failing unit tests for the strict version parser and gate**

Create `tests/e2e/test_version_gate.py`:

```python
import subprocess

import pytest

import conftest


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("4.7.stable.official.123", (4, 7, 0)),
        ("4.7.1.stable.official.123", (4, 7, 1)),
        ("Godot Engine v4.7.2.stable", (4, 7, 2)),
    ],
)
def test_parse_godot_47_versions(text, expected):
    assert conftest.parse_godot_version(text) == expected


@pytest.mark.parametrize("text", ["4.6.3.stable", "3.6.2", "not-a-version"])
def test_require_godot_47_rejects_old_or_invalid(monkeypatch, text):
    completed = subprocess.CompletedProcess(["godot", "--version"], 0, text, "")
    monkeypatch.setattr(conftest.subprocess, "run", lambda *args, **kwargs: completed)
    with pytest.raises(RuntimeError, match="Godot 4.7.x is required"):
        conftest.require_godot_47("godot")
```

- [ ] **Step 2: Run the new tests and verify the missing functions fail**

Run:

```bash
uv run pytest tests/e2e/test_version_gate.py -v
```

Expected: FAIL because `parse_godot_version` and `require_godot_47` do not exist.

- [ ] **Step 3: Implement the strict Godot 4.7 preflight**

Add near the top of `tests/e2e/conftest.py`:

```python
import re


def parse_godot_version(output: str) -> tuple[int, int, int]:
    match = re.search(r"(?:v)?(\d+)\.(\d+)(?:\.(\d+))?", output)
    if match is None:
        raise RuntimeError(f"Godot 4.7.x is required; cannot parse version: {output!r}")
    return int(match.group(1)), int(match.group(2)), int(match.group(3) or 0)


def require_godot_47(godot_bin: str) -> tuple[int, int, int]:
    try:
        result = subprocess.run(
            [godot_bin, "--version"],
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"Godot 4.7.x is required: {exc}") from exc
    version = parse_godot_version(result.stdout or result.stderr)
    if version[:2] != (4, 7):
        raise RuntimeError(
            f"Godot 4.7.x is required; found {version[0]}.{version[1]}.{version[2]}"
        )
    return version
```

At the beginning of `godot_env`, immediately after resolving `godot_bin`, call:

```python
    try:
        godot_version = require_godot_47(godot_bin)
    except RuntimeError as exc:
        pytest.fail(str(exc), pytrace=False)
```

Include `"godot_version": godot_version` in the yielded environment and remove the old `FileNotFoundError` skip around `subprocess.Popen`; a missing executable has already failed preflight.

- [ ] **Step 4: Upgrade the binding and Godot project declarations**

Change `gdapi/rust/Cargo.toml` to:

```toml
godot = { version = "0.5.4", features = ["api-4-7"] }
```

Change `gdapi/addon/gdapi.gdextension` to:

```ini
compatibility_minimum = 4.7
```

Change `tests/fixture_project/project.godot` to:

```ini
config/features=PackedStringArray("4.7")
```

Update the lock file:

```bash
cargo update -p godot --precise 0.5.4
```

- [ ] **Step 5: Document the single supported engine line**

Add to README's prerequisites:

```markdown
gdcli 的 gdapi 插件仅支持 Godot 4.7.x。构建使用 godot-rust 0.5.4 的 `api-4-7` API level；Godot 4.3–4.6 不在兼容或测试范围内。
```

- [ ] **Step 6: Verify the version gate and Rust build**

Run:

```bash
uv run pytest tests/e2e/test_version_gate.py -v
cargo tree -e features -p gdapi | rg "godot feature \"api-4-7\""
cargo tree -p gdapi | rg "godot v0\.5\.4"
cargo build --workspace
```

Expected: version-gate tests PASS, dependency tree contains `godot v0.5.4`, and the workspace builds. Do not run the full Godot E2E with a 4.6 executable; it must fail preflight until `GODOT_BIN` points to 4.7.x.

- [ ] **Step 7: Commit the Godot 4.7 baseline**

```bash
git add Cargo.lock gdapi/rust/Cargo.toml gdapi/addon/gdapi.gdextension tests/fixture_project/project.godot tests/e2e/conftest.py tests/e2e/test_version_gate.py README.md
git commit -m "build: require Godot 4.7"
```

---

### Task 2: Repair Public Route Vocabulary and Lock the 20-Route Baseline

**Files:**
- Modify: `tests/e2e/test_m1_smoke.py:48-88`
- Modify: `cli/tests/exec_integration.rs:515-539`
- Modify: `cli/src/exec.rs:25-203`
- Modify: `cli/src/main.rs:128-139`
- Modify: `gdapi/addon/runtime/builtin_routes.gd`
- Modify: `gdapi/addon/runtime/builtin_commands.gd`
- Modify: `gdapi/addon/runtime/builtin_command_help.gd`
- Modify: `gdapi/addon/runtime/route_handler.gd`
- Modify: `gdapi/addon/runtime/route_doc.gd`
- Modify: `gdapi/addon/runtime/param_doc.gd`
- Modify: `README.md:209-240`
- Modify: `docs/superpowers/specs/2026-06-27-gdcli-basic-editing-design.md:1-8`

**Interfaces:**
- Consumes: current router paths.
- Produces: the exact public set `EXPECTED_ROUTES` below; no alias paths.

- [ ] **Step 1: Replace the stale route-discovery tests with an exact inventory assertion**

In `tests/e2e/test_m1_smoke.py`, define:

```python
EXPECTED_ROUTES = {
    "command/doc",
    "command/list",
    "console/output",
    "gdapi/audit/clear",
    "gdapi/audit/list",
    "gdapi/health/pathcheck",
    "gdapi/health/ping",
    "gdapi/loglevel",
    "gdapi/routes",
    "godot/version",
    "project/info",
    "project/run",
    "project/stop",
    "scene/add_node",
    "scene/create",
    "scene/export_mesh_library",
    "scene/load_sprite",
    "scene/save",
    "uid/get",
    "uid/update_all",
}
```

Replace `TestRouteNamespace` with:

```python
class TestRouteNamespace:
    def test_routes_match_current_public_surface(self, godot_env):
        resp = _exec(godot_env, "gdapi/routes")
        assert resp["ok"] is True
        assert resp["routes"] == sorted(EXPECTED_ROUTES)

    def test_removed_aliases_are_not_exposed(self, godot_env):
        for removed in ("routes", "commands", "help", "command-help"):
            _exec_fail(godot_env, removed)
```

Change `TestCommandsMetadata` to call `command/list` and assert its returned path set equals `EXPECTED_ROUTES`.

- [ ] **Step 2: Fix the stale Rust integration mock and run the red tests**

In `exec_command_help_nonexistent_path_returns_exit_code_2`, change:

```rust
when.method(POST).path("/command/doc");
```

Run:

```bash
cargo test -p gdcli --test exec_integration exec_command_help_nonexistent_path_returns_exit_code_2
uv run pytest tests/e2e/test_m1_smoke.py -v
```

Expected before the Python route replacements are complete: the real-Godot suite exposes the old `routes`/`commands` failures. Expected after the replacements: the complete M1 smoke file passes on Godot 4.7.x.

- [ ] **Step 3: Correct live source comments and README examples**

Use these names consistently in live source and README:

```text
gdapi/health/ping
gdapi/routes
command/list
command/doc <route>
```

Replace comment-only uses of `command-help`, `/commands`, `/command-help`, `/routes`, and `/help` in the listed runtime/CLI files. Do not rewrite historical plans or research papers. Add this notice at the top of `gdcli-basic-editing-design.md`:

```markdown
> **已被取代：** 本文保留为历史设计记录。当前 route 命名、Godot 4.7 基线和里程碑以 [gdcli 全功能能力路线图设计](2026-06-27-gdcli-full-capability-roadmap-design.md) 为准，不得据此生成新的 implementation plan。
```

- [ ] **Step 4: Verify no stale vocabulary remains in live files**

Run:

```bash
rg -n "gdcli exec (ping|routes|commands|help)|/command-help|/commands|/help|/routes|command-help 使用" README.md cli/src cli/tests gdapi/addon/runtime tests/e2e
```

Expected: no stale public command examples. Matches inside formatter function names such as `render_command_help` are internal identifiers and may remain.

- [ ] **Step 5: Commit the route baseline repair**

```bash
git add README.md cli/src/exec.rs cli/src/main.rs cli/tests/exec_integration.rs gdapi/addon/runtime tests/e2e/test_m1_smoke.py docs/superpowers/specs/2026-06-27-gdcli-basic-editing-design.md
git commit -m "test: lock current gdapi route surface"
```

---

### Task 3: Run GDScript Unit Tests from Pytest and Reject Invalid Request Bodies

**Files:**
- Modify: `tests/e2e/conftest.py`
- Create: `tests/e2e/test_gdscript_units.py`
- Modify: `tests/fixture_project/tests/test_request.gd`
- Modify: `tests/fixture_project/tests/test_route_doc.gd`
- Modify: `gdapi/addon/runtime/request.gd`
- Modify: `gdapi/addon/runtime/router.gd`

**Interfaces:**
- Produces: `run_godot_script(env: dict, script: str, *, editor: bool = false, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess`.
- Produces: `GdApiRequest.body_error: String`; empty means the body is a valid JSON object.
- Router returns HTTP 400 with `invalid_param` before invoking a handler when `body_error` is non-empty.

- [ ] **Step 1: Add a reusable Godot script runner and parameterized pytest entry**

Add to `tests/e2e/conftest.py`:

```python
def run_godot_script(
    env: dict,
    script: str,
    *,
    editor: bool = False,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess:
    command = [env["godot_bin"], "--headless", "--path", str(env["fixture"])]
    if editor:
        command.append("--editor")
    command += ["--script", script]
    process_env = os.environ.copy()
    process_env.update(extra_env or {})
    return subprocess.run(
        command,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        env=process_env,
        timeout=45,
    )
```

Create `tests/e2e/test_gdscript_units.py`:

```python
import pytest

from conftest import run_godot_script


@pytest.mark.parametrize(
    "script",
    [
        "res://tests/test_request.gd",
        "res://tests/test_route_doc.gd",
    ],
)
def test_gdscript_unit_suite(godot_env, script):
    result = run_godot_script(godot_env, script)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "0 failed" in result.stdout
```

- [ ] **Step 2: Run the existing scripts through pytest**

Run:

```bash
uv run pytest tests/e2e/test_gdscript_units.py -v
```

Expected: both existing scripts PASS on Godot 4.7.x, proving they are now part of automation.

- [ ] **Step 3: Change request tests to demand explicit parse errors**

In `test_request.gd`, change the invalid JSON and JSON array assertions to:

```gdscript
	assert_eq(req.body.size(), 0, "invalid body stays empty")
	assert_eq(req.body_error, "request body must be valid JSON", "invalid json error")
```

and:

```gdscript
	assert_eq(req.body.size(), 0, "array body stays empty")
	assert_eq(req.body_error, "request body must be a JSON object", "array body error")
```

Add a test for a non-empty non-JSON content type:

```gdscript
func test_non_json_content_type_rejected() -> void:
	var req = GdApiRequest.new({
		"method": "POST",
		"path": "/test",
		"headers": {"content-type": "text/plain"},
		"body": '{}'.to_utf8_buffer(),
	})
	assert_eq(req.body_error, "content-type must be application/json", "content type error")
```

Call it from `_init()`.

- [ ] **Step 4: Run the request script and verify the new assertions fail**

Run:

```bash
uv run pytest tests/e2e/test_gdscript_units.py -v -k test_request
```

Expected: FAIL because `body_error` does not exist.

- [ ] **Step 5: Implement checked JSON object parsing**

In `request.gd`, initialize:

```gdscript
var body: Dictionary = {}
var body_error: String = ""
```

Replace the current body parsing block with:

```gdscript
if raw_body.size() > 0:
	if not is_json():
		body_error = "content-type must be application/json"
		return
	var text := raw_body.get_string_from_utf8()
	var parser := JSON.new()
	if parser.parse(text) != OK:
		body_error = "request body must be valid JSON"
		return
	if typeof(parser.data) != TYPE_DICTIONARY:
		body_error = "request body must be a JSON object"
		return
	body = parser.data
```

In `router.gd`, preload `error_codes.gd`, create one request and response immediately after deriving `key`, then reject invalid bodies:

```gdscript
var req := GdApiRequest.new(req_dict)
var res := GdApiResponse.new(server, id)
if not req.body_error.is_empty():
	res.error(req.body_error, ErrorCodes.INVALID_PARAM, 400)
	return
```

Reuse these `req` and `res` variables for all three built-in branches and the file route branch; remove duplicate constructors.

- [ ] **Step 6: Verify unit and real-route behavior**

Run:

```bash
uv run pytest tests/e2e/test_gdscript_units.py -v
uv run pytest tests/e2e/test_m1_smoke.py -v
```

Expected: both suites PASS on Godot 4.7.x.

- [ ] **Step 7: Commit request validation and the GDScript runner**

```bash
git add gdapi/addon/runtime/request.gd gdapi/addon/runtime/router.gd tests/e2e/conftest.py tests/e2e/test_gdscript_units.py tests/fixture_project/tests/test_request.gd tests/fixture_project/tests/test_route_doc.gd
git commit -m "test: run gdapi GDScript unit suites"
```

---

### Task 4: Make Router Hot Reload Handle Add, Change, and Delete

**Files:**
- Modify: `gdapi/addon/runtime/router.gd`
- Delete: `gdapi/addon/runtime/builtin_help.gd`
- Delete: `gdapi/addon/runtime/builtin_help.gd.uid`
- Create: `tests/fixture_project/tests/test_router.gd`
- Modify: `tests/e2e/test_gdscript_units.py`

**Interfaces:**
- Router stores `_file_signatures: Dictionary[String, String]` and `_file_routes: Dictionary[String, String]`.
- A non-forced `scan(root_dir)` replaces changed scripts with `ResourceLoader.CACHE_MODE_REPLACE` and removes routes whose files disappeared.
- Public route count remains 20; `builtin_help.gd` is not replaced by another route.

- [ ] **Step 1: Write an isolated add/change/delete router test**

Create `tests/fixture_project/tests/test_router.gd`:

```gdscript
@tool
extends SceneTree

const Router := preload("res://addons/gdapi/runtime/router.gd")
const TEST_ROOT := "user://gdapi_router_test"
const HANDLER_TEMPLATE := """@tool
extends \"res://addons/gdapi/runtime/route_handler.gd\"
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
    res.json({\"ok\": true})
func doc() -> GdApiRouteDoc:
    return GdApiRouteDoc.make(\"%s\")
"""

var passed := 0
var failed := 0

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	_cleanup()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_ROOT))
	var router := Router.new()
	_write_handler("v1")
	router.scan(TEST_ROOT, true)
	assert_eq(router._routes["sample"].new().doc().summary, "v1", "route added")
	_write_handler("v2")
	router.scan(TEST_ROOT)
	assert_eq(router._routes["sample"].new().doc().summary, "v2", "route replaced")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_ROOT + "/sample.gd"))
	router.scan(TEST_ROOT)
	assert_eq(router._routes.has("sample"), false, "route deleted")
	_cleanup()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)

func _write_handler(summary: String) -> void:
	var file := FileAccess.open(TEST_ROOT + "/sample.gd", FileAccess.WRITE)
	file.store_string(HANDLER_TEMPLATE % summary)
	file.close()

func _cleanup() -> void:
	var file_path := ProjectSettings.globalize_path(TEST_ROOT + "/sample.gd")
	if FileAccess.file_exists(file_path):
		DirAccess.remove_absolute(file_path)
	var dir_path := ProjectSettings.globalize_path(TEST_ROOT)
	if DirAccess.dir_exists_absolute(dir_path):
		DirAccess.remove_absolute(dir_path)

func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
```

Add the script to the pytest parameter list.

- [ ] **Step 2: Run the router test and verify change/delete fail**

Run:

```bash
uv run pytest tests/e2e/test_gdscript_units.py -v -k test_router
```

Expected: FAIL because the cached script remains after change and the deleted route remains registered.

- [ ] **Step 3: Replace mtime-only state with signatures and file-to-route mapping**

In `router.gd`, replace `_file_mtimes` with:

```gdscript
var _file_signatures: Dictionary = {}
var _file_routes: Dictionary = {}
```

At scan start, create `seen_files`, pass it through recursion, and remove missing files after traversal:

```gdscript
var seen_files: Dictionary = {}
_scan_dir(root_dir, "", seen_files)
for file_path in _file_routes.keys().duplicate():
	if not seen_files.has(file_path):
		_routes.erase(_file_routes[file_path])
		_file_routes.erase(file_path)
		_file_signatures.erase(file_path)
		_needs_update = true
```

Inside the recursive scanner, record and compare an MD5 signature, then replace the resource cache:

```gdscript
seen_files[full] = true
var signature := FileAccess.get_md5(full)
if signature != _file_signatures.get(full, ""):
	var script := ResourceLoader.load(full, "", ResourceLoader.CACHE_MODE_REPLACE) as Script
	if script != null:
		_routes[key] = script
		_file_routes[full] = key
		_file_signatures[full] = signature
		_needs_update = true
```

On forced scan clear both dictionaries. Rename `_scan_dir_with_mtime` to `_scan_dir` and update comments to describe content signatures and deletion.

- [ ] **Step 4: Remove the dead built-in help implementation**

Delete `builtin_help.gd` and its UID. Remove `BuiltinHelp`, `_builtin_help_handler`, and its construction/injection from `router.gd`. Keep only `gdapi/routes`, `command/list`, and `command/doc` as extra built-ins; `gdapi/health/ping` remains in `_routes`.

- [ ] **Step 5: Verify router behavior and public inventory**

Run:

```bash
uv run pytest tests/e2e/test_gdscript_units.py -v -k test_router
uv run pytest tests/e2e/test_m1_smoke.py -v -k RouteNamespace
cargo test -p gdcli --test addon_deploy_test
```

Expected: add/change/delete assertions PASS, public route list remains the exact 20-route set, and addon packaging tests PASS.

- [ ] **Step 6: Commit deterministic hot reload**

```bash
git add gdapi/addon/runtime/router.gd tests/fixture_project/tests/test_router.gd tests/e2e/test_gdscript_units.py
git add -u gdapi/addon/runtime/builtin_help.gd gdapi/addon/runtime/builtin_help.gd.uid
git commit -m "fix(router): remove deleted routes during hot reload"
```

---

### Task 5: Strengthen PathGuard and Apply It to Project and UID Routes

**Files:**
- Modify: `gdapi/addon/runtime/path_guard.gd`
- Create: `tests/fixture_project/tests/test_path_guard.gd`
- Modify: `tests/e2e/test_gdscript_units.py`
- Modify: `gdapi/addon/routes/gdapi/health/pathcheck.gd`
- Modify: `gdapi/addon/routes/project/run.gd`
- Modify: `gdapi/addon/routes/uid/get.gd`
- Modify: `gdapi/addon/routes/uid/update_all.gd`

**Interfaces:**
- `GdApiPathGuard.validate(path: String, mode: String = "read") -> Dictionary` accepts only `read`, `write`, or `delete`.
- Success is `{ok:true, path:String}`; failure is `{ok:false,error:String,code:String,status:int}`.
- `uid/update_all` requires `force:true`, records audit as `uid/update_all`, and returns `undoable:false`.

- [ ] **Step 1: Add focused PathGuard unit cases**

Create `test_path_guard.gd`:

```gdscript
@tool
extends SceneTree

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

var passed := 0
var failed := 0

func _init() -> void:
	assert_eq(PathGuard.validate("scenes/a.tscn", "read").path, "res://scenes/a.tscn", "relative path")
	assert_true(PathGuard.validate("user://cache.json", "write").ok, "user write")
	assert_eq(PathGuard.validate("res://foo..bar.txt", "read").ok, true, "double dot filename")
	assert_eq(PathGuard.validate("res://a/../b", "read").code, ErrorCodes.INVALID_PATH, "parent segment")
	assert_eq(PathGuard.validate("C:/temp/a.txt", "read").code, ErrorCodes.INVALID_PATH, "windows absolute")
	assert_eq(PathGuard.validate("/tmp/a.txt", "read").code, ErrorCodes.INVALID_PATH, "posix absolute")
	assert_eq(PathGuard.validate("res://addons/gdapi/plugin.gd", "write").code, ErrorCodes.PERMISSION_DENIED, "addon protected")
	assert_eq(PathGuard.validate("res://.godot/gdapi.json", "delete").code, ErrorCodes.PERMISSION_DENIED, "metadata protected")
	assert_eq(PathGuard.validate("res://a.txt", "execute").code, ErrorCodes.INVALID_PARAM, "unknown mode")
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)

func assert_true(value: bool, context: String) -> void:
	assert_eq(value, true, context)

func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
```

Add the script to `test_gdscript_units.py`.

- [ ] **Step 2: Run the unit test and verify current mode/traversal behavior fails**

Run:

```bash
uv run pytest tests/e2e/test_gdscript_units.py -v -k test_path_guard
```

Expected: FAIL for unknown mode and the valid `foo..bar.txt` filename.

- [ ] **Step 3: Implement segment-aware validation**

At the start of `validate`, add:

```gdscript
if mode not in ["read", "write", "delete"]:
	return _err("invalid path mode: " + mode, ErrorCodes.INVALID_PARAM)
```

Replace `normalized.contains("..")` with:

```gdscript
var path_without_scheme := normalized.trim_prefix("res://").trim_prefix("user://")
for segment in path_without_scheme.split("/", false):
	if segment == "..":
		return _err("path traversal is not allowed", ErrorCodes.INVALID_PATH)
```

- [ ] **Step 4: Migrate project/run and uid/get to checked paths**

Preload PathGuard in each route. In `project/run.gd`, replace manual prefixing with:

```gdscript
var checked := PathGuard.validate(scene_path, "read")
if not checked.ok:
	res.error(checked.error, checked.code, checked.status)
	return
scene_path = checked.path
```

For `project/run`, only run this block when `scene_path` is non-empty. In `uid/get.gd`, use the same block with `file_path` and assign `file_path = checked.path`. Retain all existing response fields, including `absolute_path`; M1 may add validation but must not remove a published field.

- [ ] **Step 5: Protect and audit uid/update_all**

Preload `PathGuard`, `ErrorCodes`, and `AuditLog`. Require `force:true` before scanning, validate `project_path` in `write` mode, and use the public route name in every event:

```gdscript
var force := bool(req.get_body("force", false))
if not ErrorCodes.require_force(res, force, "uid/update_all"):
	AuditLog.record("uid/update_all", "dangerous", {"force": false}, false, ErrorCodes.UNSAFE_OPERATION)
	return
var checked := PathGuard.validate(req.get_body("project_path", "res://"), "write")
if not checked.ok:
	AuditLog.record("uid/update_all", "dangerous", {"project_path": req.get_body("project_path", "")}, false, checked.code)
	res.error(checked.error, checked.code, checked.status)
	return
```

On success record counts and return `changed`, `undoable:false`, and the existing count fields. Add `force` to `doc()` and an example with a fixture subdirectory.

- [ ] **Step 6: Verify unit tests and route negative cases**

Add this helper and these E2E cases to `test_m1_smoke.py`:

```python
import json
import subprocess


def _exec_error(env: dict, route: str, data: dict) -> dict:
    result = subprocess.run(
        [
            str(env["gdcli"]), "--json", "exec", route,
            "--project", str(env["fixture"]),
            "--data", json.dumps(data),
        ],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    assert result.returncode != 0, result.stdout
    return json.loads(result.stderr.split(": ", 1)[1])


def test_pathcheck_rejects_unknown_mode(godot_env):
    error = _exec_error(
        godot_env,
        "gdapi/health/pathcheck",
        {"path": "res://test.tscn", "mode": "execute"},
    )
    assert error["code"] == "invalid_param"


def test_uid_update_requires_force(godot_env):
    error = _exec_error(godot_env, "uid/update_all", {"project_path": "res://tests"})
    assert error["code"] == "unsafe_operation"


def test_uid_update_cannot_touch_protected_metadata(godot_env):
    metadata = godot_env["fixture"] / ".godot" / "gdapi.json"
    before = metadata.read_bytes()
    error = _exec_error(
        godot_env,
        "uid/update_all",
        {"project_path": "res://.godot", "force": True},
    )
    assert error["code"] == "permission_denied"
    assert metadata.read_bytes() == before
```

Then run:

```bash
uv run pytest tests/e2e/test_gdscript_units.py -v -k test_path_guard
uv run pytest tests/e2e/test_m1_smoke.py -v -k "PathGuard or uid"
```

Expected: PASS on Godot 4.7.x.

- [ ] **Step 7: Commit project/UID path safety**

```bash
git add gdapi/addon/runtime/path_guard.gd gdapi/addon/routes/gdapi/health/pathcheck.gd gdapi/addon/routes/project/run.gd gdapi/addon/routes/uid/get.gd gdapi/addon/routes/uid/update_all.gd tests/fixture_project/tests/test_path_guard.gd tests/e2e/test_gdscript_units.py tests/e2e/test_m1_smoke.py
git commit -m "fix(gdapi): enforce project path policy"
```

---

### Task 6: Make File-Oriented Scene Mutations Safe, Typed, and Audited

**Files:**
- Modify: `gdapi/addon/runtime/variant_codec.gd`
- Create: `tests/fixture_project/tests/test_variant_codec.gd`
- Modify: `tests/e2e/test_gdscript_units.py`
- Modify: `gdapi/addon/routes/scene/create.gd`
- Modify: `gdapi/addon/routes/scene/add_node.gd`
- Modify: `gdapi/addon/routes/scene/save.gd`
- Modify: `gdapi/addon/routes/scene/load_sprite.gd`
- Modify: `gdapi/addon/routes/scene/export_mesh_library.gd`
- Create: `tests/e2e/test_m1_scene_safety.py`

**Interfaces:**
- Produces: `GdApiVariantCodec.decode(value: Variant) -> Dictionary` with `{ok:true,value:Variant}` or `{ok:false,error:String}`.
- Every scene mutation validates paths, uses standard error codes, reports `changed`, `saved`, `undoable:false`, and audits its exact public route.
- `scene/create` requires force only when the target exists; `scene/add_node` and `scene/load_sprite` always require force; `scene/save`/`scene/export_mesh_library` require force when their destination exists.

- [ ] **Step 1: Add checked codec tests**

Create `test_variant_codec.gd`:

```gdscript
@tool
extends SceneTree

const Codec := preload("res://addons/gdapi/runtime/variant_codec.gd")

var passed := 0
var failed := 0

func _init() -> void:
	assert_eq(Codec.decode({"type":"Vector2","value":[1,2]}).value, Vector2(1,2), "Vector2")
	assert_eq(Codec.decode({"type":"Vector3","value":[1,2,3]}).value, Vector3(1,2,3), "Vector3")
	assert_eq(Codec.decode({"type":"Color","value":[0.1,0.2,0.3,0.4]}).value, Color(0.1,0.2,0.3,0.4), "Color")
	assert_eq(Codec.decode({"type":"NodePath","value":"root/Child"}).value, NodePath("root/Child"), "NodePath")
	var transform := Codec.decode({"type":"Transform2D","value":[[1,0],[0,1],[5,6]]}).value
	assert_eq(transform, Transform2D(Vector2(1,0), Vector2(0,1), Vector2(5,6)), "Transform2D")
	var resource := Codec.decode({"type":"Resource","value":"res://test.tscn"})
	assert_true(resource.ok and resource.value is PackedScene, "Resource")
	assert_false(Codec.decode({"type":"Vector2","value":[1]}).ok, "short vector")
	assert_false(Codec.decode({"type":"PackedStringArray","value":["a"]}).ok, "packed array unsupported")
	assert_false(Codec.decode({"type":"Resource","value":"res://missing.tres"}).ok, "missing resource")
	assert_eq(Codec.decode({"plain": 1}).value, {"plain": 1}, "plain dictionary unchanged")
	assert_eq(Codec.from_variant(Vector2(8,9)), {"type":"Vector2","value":[8.0,9.0]}, "Vector2 encode")
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)

func assert_true(value: bool, context: String) -> void:
	assert_eq(value, true, context)

func assert_false(value: bool, context: String) -> void:
	assert_eq(value, false, context)

func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
```

Add the script to the pytest parameter list.

- [ ] **Step 2: Run the codec suite and verify `decode` is missing**

Run:

```bash
uv run pytest tests/e2e/test_gdscript_units.py -v -k test_variant_codec
```

Expected: FAIL because `decode` does not exist.

- [ ] **Step 3: Implement checked decoding and retain compatibility wrappers**

Refactor the current type match into `decode`. For every supported type validate array shape before construction; for `Resource`, require a non-empty existing `res://` or `user://` resource. Unknown explicit types return:

```gdscript
return {"ok": false, "error": "unsupported Variant type: " + type_name}
```

Keep `to_variant` as:

```gdscript
static func to_variant(value: Variant) -> Variant:
	var result := decode(value)
	return result.value if result.ok else value
```

Do not add PackedArray support in M1.

- [ ] **Step 4: Write E2E safety cases before changing scene routes**

Create `test_m1_scene_safety.py` with the complete harness and cases below. It uses a per-test directory and always removes it:

```python
import json
import shutil
import subprocess
import uuid

import pytest

from conftest import gdcli_json


@pytest.fixture
def scene_workspace(godot_env):
    relative = f".gdcli_e2e/{uuid.uuid4().hex}"
    absolute = godot_env["fixture"] / relative
    absolute.mkdir(parents=True)
    try:
        yield relative, absolute
    finally:
        shutil.rmtree(absolute, ignore_errors=True)


def _ok(env, route, body):
    return gdcli_json(
        env,
        "exec",
        route,
        "--project",
        str(env["fixture"]),
        "--data",
        json.dumps(body),
    )


def _error(env, route, body):
    result = subprocess.run(
        [
            str(env["gdcli"]), "--json", "exec", route,
            "--project", str(env["fixture"]),
            "--data", json.dumps(body),
        ],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    assert result.returncode != 0, result.stdout
    payload = result.stderr.split(": ", 1)[1]
    return json.loads(payload)


def _create_scene(env, path):
    return _ok(env, "scene/create", {"scene_path": path})


def test_scene_create_requires_force_only_for_existing_target(godot_env, scene_workspace):
    relative, _ = scene_workspace
    path = f"res://{relative}/created.tscn"
    first = _create_scene(godot_env, path)
    assert first["changed"] is True
    assert first["saved"] is True
    assert first["undoable"] is False
    assert _error(godot_env, "scene/create", {"scene_path": path})["code"] == "unsafe_operation"
    forced = _ok(godot_env, "scene/create", {"scene_path": path, "force": True})
    assert forced["saved"] is True


def test_scene_add_node_requires_force_and_decodes_vector2(godot_env, scene_workspace):
    relative, absolute = scene_workspace
    path = f"res://{relative}/typed.tscn"
    _create_scene(godot_env, path)
    body = {
        "scene_path": path,
        "node_type": "Node2D",
        "node_name": "Child",
        "properties": {"position": {"type": "Vector2", "value": [12, 34]}},
    }
    assert _error(godot_env, "scene/add_node", body)["code"] == "unsafe_operation"
    body["force"] = True
    response = _ok(godot_env, "scene/add_node", body)
    assert response["undoable"] is False
    assert "position = Vector2(12, 34)" in (absolute / "typed.tscn").read_text(encoding="utf-8")


def test_scene_save_rejects_unforced_existing_destination(godot_env, scene_workspace):
    relative, absolute = scene_workspace
    source = f"res://{relative}/source.tscn"
    destination = f"res://{relative}/destination.tscn"
    _create_scene(godot_env, source)
    (absolute / "destination.tscn").write_text("sentinel", encoding="utf-8")
    error = _error(
        godot_env,
        "scene/save",
        {"scene_path": source, "new_path": destination},
    )
    assert error["code"] == "unsafe_operation"
    assert (absolute / "destination.tscn").read_text(encoding="utf-8") == "sentinel"


def test_scene_load_sprite_requires_force(godot_env, scene_workspace):
    relative, _ = scene_workspace
    path = f"res://{relative}/sprite.tscn"
    _create_scene(godot_env, path)
    _ok(godot_env, "scene/add_node", {
        "scene_path": path,
        "node_type": "Sprite2D",
        "node_name": "Sprite",
        "force": True,
    })
    error = _error(godot_env, "scene/load_sprite", {
        "scene_path": path,
        "node_path": "root/Sprite",
        "texture_path": "res://missing.png",
    })
    assert error["code"] == "unsafe_operation"


def test_mesh_library_rejects_unforced_existing_destination(godot_env, scene_workspace):
    relative, absolute = scene_workspace
    output = f"res://{relative}/library.tres"
    (absolute / "library.tres").write_text("sentinel", encoding="utf-8")
    error = _error(godot_env, "scene/export_mesh_library", {
        "scene_path": "res://test.tscn",
        "output_path": output,
    })
    assert error["code"] == "unsafe_operation"
    assert (absolute / "library.tres").read_text(encoding="utf-8") == "sentinel"


def test_scene_mutation_success_and_rejection_are_audited(godot_env, scene_workspace):
    relative, _ = scene_workspace
    path = f"res://{relative}/audit.tscn"
    _ok(godot_env, "gdapi/audit/clear", {"force": True})
    _create_scene(godot_env, path)
    _error(godot_env, "scene/add_node", {
        "scene_path": path,
        "node_type": "Node2D",
        "node_name": "Rejected",
    })
    entries = _ok(godot_env, "gdapi/audit/list", {"since": 0, "limit": 20})["entries"]
    assert any(entry["route"] == "scene/create" and entry["ok"] for entry in entries)
    assert any(entry["route"] == "scene/add_node" and not entry["ok"] for entry in entries)
```

For the typed property case send:

```json
{"position":{"type":"Vector2","value":[12,34]}}
```

and assert the saved `.tscn` contains `position = Vector2(12, 34)`.

- [ ] **Step 5: Run the new E2E file and verify current unsafe behavior fails**

Run:

```bash
uv run pytest tests/e2e/test_m1_scene_safety.py -v
```

Expected: FAIL because current routes overwrite without force, do not use the codec, omit mutation fields, and do not audit.

- [ ] **Step 6: Apply one exact mutation contract to all five scene routes**

Each route must preload `PathGuard`, `ErrorCodes`, and `AuditLog`; `scene/add_node` also preloads `VariantCodec`. Apply these exact policies:

| Route | Read paths | Write destination | Force rule | Standardized failures |
|---|---|---|---|---|
| `scene/create` | none | `scene_path` | if destination exists | invalid class → `invalid_param`; pack/save → `godot_error` |
| `scene/add_node` | `scene_path` | same scene | always | missing parent → `not_found`; invalid class/property → `invalid_param`; load/pack/save → `godot_error` |
| `scene/save` | `scene_path` | `new_path` or source | if destination exists | missing source → `not_found`; load/save → `godot_error` |
| `scene/load_sprite` | scene and texture | scene | always | missing node/resource → `not_found`; wrong node type → `invalid_param`; pack/save → `godot_error` |
| `scene/export_mesh_library` | `scene_path` | `output_path` | if destination exists | no meshes → `not_found`; load/save → `godot_error` |

Before overwriting, use:

```gdscript
if FileAccess.file_exists(ProjectSettings.globalize_path(destination)):
	if not ErrorCodes.require_force(res, force, ROUTE):
		AuditLog.record(ROUTE, "dangerous", {"target": destination, "force": false}, false, ErrorCodes.UNSAFE_OPERATION)
		return
```

For every `scene/add_node` property:

```gdscript
var decoded := VariantCodec.decode(properties[prop])
if not decoded.ok:
	AuditLog.record(ROUTE, "dangerous", {"property": prop}, false, ErrorCodes.INVALID_PARAM)
	res.error(decoded.error, ErrorCodes.INVALID_PARAM, 400, {"property": prop})
	return
new_node.set(prop, decoded.value)
```

Every success response includes:

```gdscript
"changed": true,
"saved": true,
"undoable": false,
```

Every success and every failure after entering a mutation handler—including missing parameters, invalid paths, missing force, Godot errors, and save failures—records the exact `ROUTE` constant. Summaries contain only route-specific paths, node names, class names, force, and counts; never include request headers or token data.

- [ ] **Step 7: Update route docs with force and mutation fields**

Add `force: bool` where required, document conditional force on destination routes, and add these examples:

```text
scene/create: {"scene_path":"res://scenes/new.tscn","root_node_type":"Node2D"}
scene/add_node: {"scene_path":"res://scenes/new.tscn","node_type":"Node2D","node_name":"Child","force":true}
scene/save: {"scene_path":"res://scenes/a.tscn","new_path":"res://scenes/b.tscn"}
scene/load_sprite: {"scene_path":"res://scenes/a.tscn","node_path":"root/Sprite2D","texture_path":"res://icon.svg","force":true}
scene/export_mesh_library: {"scene_path":"res://mesh_source.tscn","output_path":"res://mesh_library.tres"}
```

- [ ] **Step 8: Verify codec, scene safety, and audit behavior**

Run:

```bash
uv run pytest tests/e2e/test_gdscript_units.py -v -k test_variant_codec
uv run pytest tests/e2e/test_m1_scene_safety.py -v
uv run pytest tests/e2e/test_m1_smoke.py -v -k AuditLog
```

Expected: all selected tests PASS on Godot 4.7.x.

- [ ] **Step 9: Commit scene mutation closure**

```bash
git add gdapi/addon/runtime/variant_codec.gd gdapi/addon/routes/scene tests/fixture_project/tests/test_variant_codec.gd tests/e2e/test_gdscript_units.py tests/e2e/test_m1_scene_safety.py
git commit -m "fix(scene): enforce safe file mutations"
```

---

### Task 7: Turn EditAction into a Real Editor UndoRedo Wrapper

**Files:**
- Modify: `gdapi/addon/runtime/edit_action.gd`
- Create: `tests/fixture_project/addons/gdapi_test/plugin.cfg`
- Create: `tests/fixture_project/addons/gdapi_test/plugin.gd`
- Modify: `tests/fixture_project/project.godot`
- Create: `tests/e2e/test_edit_action.py`

**Interfaces:**
- Produces: `GdApiEditAction.commit_property(target: Object, property: StringName, value: Variant, action_name: String) -> Dictionary`.
- Success result: `{ok:true, previous:Variant, history_id:int}`; failure: `{ok:false,error:String}`.
- Fixture-only plugin runs only when `GDAPI_RUN_EDITOR_TESTS=1`; otherwise it has no side effects.
- The pytest case copies the fixture to `tmp_path`, installs gdapi there, and starts a separate editor; it never shares `.godot/gdapi.json` with the session-scoped main E2E editor.

- [ ] **Step 1: Write the fixture-only editor plugin**

Create `plugin.cfg`:

```ini
[plugin]
name="gdapi_test"
description="Editor-only gdapi acceptance tests"
author="gdcli"
version="0.1.0"
script="plugin.gd"
```

Create `plugin.gd` with an `_enter_tree()` guard:

```gdscript
@tool
extends EditorPlugin

const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")

func _enter_tree() -> void:
	if OS.get_environment("GDAPI_RUN_EDITOR_TESTS") == "1":
		_run.call_deferred()

func _run() -> void:
	EditorInterface.open_scene_from_path("res://test.tscn")
	for _i in range(5):
		await get_tree().process_frame
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_fail("edited scene root is null")
		return
	var original := root.position
	var changed := Vector2(41, 73)
	var result := EditAction.commit_property(root, &"position", changed, "gdapi test position")
	if not result.ok or root.position != changed:
		_fail("commit_property did not apply value")
		return
	var manager := get_undo_redo()
	var history := manager.get_history_undo_redo(manager.get_object_history_id(root))
	if not history.undo() or root.position != original:
		_fail("undo did not restore value")
		return
	if not history.redo() or root.position != changed:
		_fail("redo did not restore changed value")
		return
	print("GDAPI_EDITOR_TEST_PASS")
	get_tree().quit(0)

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)
```

Append `res://addons/gdapi_test/plugin.cfg` to the fixture's enabled plugin array.

- [ ] **Step 2: Add an isolated pytest editor project and verify the wrapper is missing**

Create `tests/e2e/test_edit_action.py`:

```python
import os
import shutil
import subprocess
import sys
from pathlib import Path

from conftest import _gdcli_bin, _repo_root, require_godot_47


def _copy_native_library(root: Path, project: Path) -> None:
    if sys.platform == "win32":
        source = root / "target" / "debug" / "gdapi.dll"
        destination = project / "addons" / "gdapi" / "bin" / "windows" / "gdapi.dll"
    elif sys.platform == "darwin":
        source = root / "target" / "debug" / "libgdapi.dylib"
        destination = project / "addons" / "gdapi" / "bin" / "macos" / "libgdapi.dylib"
    else:
        source = root / "target" / "debug" / "libgdapi.so"
        destination = project / "addons" / "gdapi" / "bin" / "linux" / "libgdapi.so"
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def _isolated_project(tmp_path: Path) -> Path:
    root = _repo_root()
    build = subprocess.run(
        ["cargo", "build", "--workspace"],
        cwd=root,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    assert build.returncode == 0, build.stdout + build.stderr
    source = root / "tests" / "fixture_project"
    project = tmp_path / "fixture_project"
    shutil.copytree(
        source,
        project,
        ignore=shutil.ignore_patterns(".godot", "gdapi"),
    )
    install = subprocess.run(
        [str(_gdcli_bin()), "install", "--project", str(project), "--force"],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    assert install.returncode == 0, install.stdout + install.stderr
    _copy_native_library(root, project)
    return project


def test_real_editor_undo_redo(tmp_path):
    godot_bin = os.environ.get("GODOT_BIN", "godot")
    require_godot_47(godot_bin)
    project = _isolated_project(tmp_path)
    process_env = os.environ.copy()
    process_env["GDAPI_RUN_EDITOR_TESTS"] = "1"
    result = subprocess.run(
        [godot_bin, "--editor", "--headless", "--path", str(project)],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        env=process_env,
        timeout=45,
    )
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "GDAPI_EDITOR_TEST_PASS" in output
```

Run:

```bash
uv run pytest tests/e2e/test_edit_action.py -v
```

Expected: FAIL because `commit_property` does not exist.

- [ ] **Step 3: Implement the property action wrapper**

Add to `edit_action.gd`:

```gdscript
static func commit_property(
	target: Object,
	property: StringName,
	value: Variant,
	action_name: String
) -> Dictionary:
	if target == null or not is_instance_valid(target):
		return {"ok": false, "error": "target is invalid"}
	var manager = undo_redo()
	if manager == null:
		return {"ok": false, "error": "EditorUndoRedoManager is unavailable"}
	var previous = target.get(property)
	manager.create_action(action_name, UndoRedo.MERGE_DISABLE, target)
	manager.add_do_property(target, property, value)
	manager.add_undo_property(target, property, previous)
	manager.commit_action()
	return {
		"ok": true,
		"previous": previous,
		"history_id": manager.get_object_history_id(target),
	}
```

- [ ] **Step 4: Run the real editor test and normal E2E startup**

Run with no other editor using the temporary project:

```bash
uv run pytest tests/e2e/test_edit_action.py -v
uv run pytest tests/e2e/test_e2e_ping.py -v
```

Expected: the editor test prints `GDAPI_EDITOR_TEST_PASS`; regular plugin startup remains unaffected because the environment guard is absent.

- [ ] **Step 5: Commit the verified UndoRedo wrapper**

```bash
git add gdapi/addon/runtime/edit_action.gd tests/fixture_project/addons/gdapi_test tests/fixture_project/project.godot tests/e2e/test_edit_action.py
git commit -m "feat(gdapi): verify editor UndoRedo actions"
```

---

### Task 8: Standardize Remaining Errors, Command Docs, Audit Identity, and Final Verification

**Files:**
- Modify: `gdapi/addon/routes/gdapi/audit/clear.gd`
- Modify: `gdapi/addon/routes/gdapi/audit/list.gd`
- Modify: `gdapi/addon/routes/gdapi/loglevel.gd`
- Modify: `gdapi/addon/runtime/builtin_command_help.gd`
- Modify: `gdapi/addon/runtime/error_codes.gd`
- Modify: `gdapi/addon/routes/console/output.gd`
- Modify: `gdapi/addon/routes/gdapi/health/pathcheck.gd`
- Modify: `gdapi/addon/routes/project/run.gd`
- Modify: `gdapi/addon/routes/scene/create.gd`
- Modify: `gdapi/addon/routes/scene/add_node.gd`
- Modify: `gdapi/addon/routes/scene/save.gd`
- Modify: `gdapi/addon/routes/scene/load_sprite.gd`
- Modify: `gdapi/addon/routes/scene/export_mesh_library.gd`
- Modify: `gdapi/addon/routes/uid/get.gd`
- Modify: `gdapi/addon/routes/uid/update_all.gd`
- Create: `tests/e2e/test_m1_contracts.py`
- Modify: `README.md`

**Interfaces:**
- All route errors use only the ten standard codes.
- `gdapi/audit/clear` records its exact public path.
- Every parameterized public route has at least one JSON example; every public route has non-empty summary and return fields.

- [ ] **Step 1: Add contract tests before cleanup**

Create `tests/e2e/test_m1_contracts.py`:

```python
import re
import subprocess
from pathlib import Path

from conftest import gdcli_json


STANDARD_CODES = {
    "missing_param", "invalid_param", "invalid_path", "not_found", "conflict",
    "not_supported", "permission_denied", "unsafe_operation", "timeout", "godot_error",
}


def test_all_command_docs_are_complete(godot_env):
    listing = gdcli_json(
        godot_env, "exec", "command/list", "--project", str(godot_env["fixture"])
    )
    for command in listing["commands"]:
        assert command["summary"], command["path"]
        detail = gdcli_json(
            godot_env, "exec", "command/doc", command["path"],
            "--project", str(godot_env["fixture"]),
        )["doc"]
        assert detail["returns"]["fields"], command["path"]
        if detail["params"]:
            assert detail["examples"], command["path"]


def test_literal_route_error_codes_are_standard(godot_env):
    root = Path(godot_env["root"]) / "gdapi" / "addon"
    pattern = re.compile(r'res\.error\([^\n]*,\s*"([a-z_]+)"')
    found = set()
    for path in root.rglob("*.gd"):
        found.update(pattern.findall(path.read_text(encoding="utf-8")))
    assert found <= STANDARD_CODES, sorted(found - STANDARD_CODES)
```

Add this third test:

```python
def test_audit_clear_records_exact_public_route(godot_env):
    gdcli_json(
        godot_env, "exec", "gdapi/audit/clear",
        "--project", str(godot_env["fixture"]),
        "--data", '{"force":true}',
    )
    rejected = subprocess.run(
        [
            str(godot_env["gdcli"]), "--json", "exec", "gdapi/audit/clear",
            "--project", str(godot_env["fixture"]), "--data", "{}",
        ],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    assert rejected.returncode == 2
    entries = gdcli_json(
        godot_env, "exec", "gdapi/audit/list",
        "--project", str(godot_env["fixture"]),
        "--data", '{"since":0,"limit":10}',
    )["entries"]
    assert entries[-1]["route"] == "gdapi/audit/clear"
    assert entries[-1]["ok"] is False
```

- [ ] **Step 2: Run contract tests and record the expected failures**

Run:

```bash
uv run pytest tests/e2e/test_m1_contracts.py -v
```

Expected: FAIL for missing examples, private literal codes, and the stale `project/audit/clear` identity.

- [ ] **Step 3: Normalize remaining error codes**

Apply these exact replacements:

```text
invalid_request -> missing_param
plugin_not_ready -> godot_error
invalid_type -> invalid_param
load_failed -> godot_error
parent_not_found -> not_found
pack_failed -> godot_error
save_failed -> godot_error
node_not_found -> not_found
texture_not_found -> not_found
no_meshes -> not_found
```

Use constants from `error_codes.gd` in touched files. Put Godot error integers and the original operation name in `details`, not in new error codes.

- [ ] **Step 4: Correct audit identity and audit response contract**

In `gdapi/audit/clear.gd`, replace all three `project/audit/clear` strings with `gdapi/audit/clear`. Return:

```gdscript
res.json({"ok": true, "cleared": true, "changed": true, "undoable": false})
```

Add examples to audit list/clear and loglevel docs. Keep the audit buffer in memory and capped at 1000; persistence is outside M1.

- [ ] **Step 5: Add examples to every parameterized route doc**

Use valid fixture-safe bodies. At minimum include:

```text
console/output: {"offset":0,"limit":50}
gdapi/health/pathcheck: {"path":"res://test.tscn","mode":"read"}
gdapi/loglevel: {"level":"info"}
gdapi/audit/list: {"since":0,"limit":100}
gdapi/audit/clear: {"force":true}
project/run: {"scene_path":"res://test.tscn"}
uid/get: {"file_path":"res://test.tscn"}
uid/update_all: {"project_path":"res://tests","force":true}
```

Scene examples are the five exact bodies from Task 6. Built-in `command/doc` uses `{"command":"gdapi/health/ping"}`. Ensure every route's `returns_fields` is non-empty.

- [ ] **Step 6: Run the full verification gate**

Set `GODOT_BIN` to a Godot 4.7.x executable, then run:

```bash
cargo fmt --check
cargo clippy --workspace
cargo test --workspace
uv run pytest tests/e2e/ -v
git diff --check
git status --short
```

Expected:

```text
cargo fmt --check: exit 0
cargo clippy --workspace: exit 0
cargo test --workspace: all tests pass
pytest: all collected tests pass, no implementation-error skip
git diff --check: no output
git status --short: only Task 8 files are modified
```

- [ ] **Step 7: Update README with the verified route and test commands**

Document the exact self-description commands:

```bash
gdcli exec gdapi/routes
gdcli exec command/list
gdcli exec command/doc scene/save
```

Document the M1 verification command and Godot requirement:

```bash
GODOT_BIN=/path/to/Godot-4.7 uv run pytest tests/e2e/ -v
```

On Windows, show the PowerShell environment assignment followed by the same Python command; do not create a PowerShell script.

- [ ] **Step 8: Commit M1 contract closure**

```bash
git add README.md gdapi/addon/runtime/error_codes.gd gdapi/addon/runtime/builtin_command_help.gd gdapi/addon/routes tests/e2e/test_m1_contracts.py
git commit -m "test: close gdapi M1 contracts"
```

- [ ] **Step 9: Record final evidence for handoff**

Run:

```bash
git log --oneline -8
git status --short
```

Report the Godot executable's `--version`, godot-rust version from `cargo tree -p gdapi`, the exact pytest pass count, the exact Cargo pass count, and confirm the worktree is clean. Do not claim M1 complete if any Godot 4.7 E2E test failed or was skipped because of an implementation error.

## Self-Review

Spec coverage:

- Godot 4.7-only build/runtime/test baseline: Task 1.
- Exact four built-ins and 20-route inventory: Task 2.
- Automated request/route-doc GDScript tests and invalid-body contract: Task 3.
- Router add/change/delete hot reload and dead help removal: Task 4.
- PathGuard modes and project/UID integration: Task 5.
- Variant codec integration, file mutation force policy, non-undoable response fields, and scene audit: Task 6.
- Real `EditorUndoRedoManager` do/undo/redo proof without production test routes: Task 7.
- Standard errors, exact audit identity, doc completeness, README, and full verification: Task 8.

Scope intentionally deferred to M2:

- Public `node/property/set` and other current-edited-scene routes. M1 proves the shared EditAction wrapper with a fixture-only editor plugin; M2 consumes it in public node routes.
- PackedArray codec support.
- Persistent audit storage.
- Runtime probe, game-system, diagnostics, export, and high-risk route families.

Type and naming consistency:

- `parse_godot_version` and `require_godot_47` are defined in Task 1 and reused by the session fixture.
- `run_godot_script` is defined in Task 3 and reused by the headless helper suites in Tasks 4, 5, and 6; Task 7 deliberately uses an isolated editor process instead.
- `GdApiVariantCodec.decode` always returns an `ok` dictionary and is consumed by `scene/add_node`.
- `GdApiEditAction.commit_property` returns `ok`, `previous`, and `history_id`, matching the editor test plugin.
- Audit records always use the exact public route path.
- No canonical path, alias metadata, Godot 4.3–4.6 compatibility branch, shell script, or PowerShell script is introduced.
