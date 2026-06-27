# gdcli M1 Route Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build M1 from `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`: canonical route namespaces, route metadata, shared safety helpers, audit routes, and a Godot E2E smoke harness.

**Architecture:** Keep `gdcli exec` unchanged. Extend the gdapi GDScript router and runtime helpers so existing route files can expose both legacy names and canonical names such as `editor/scene/create`; add small route helpers for path validation, variant conversion, UndoRedo access, error codes, and audit logging.

**Tech Stack:** Rust workspace (`cargo test`, `cargo clippy`, `cargo fmt --check`), Godot 4.x GDScript addon, PowerShell/Bash E2E scripts using `GODOT_BIN`.

## Global Constraints

- User API remains only `gdcli exec <route> --data ...`; do not add MCP server or new CLI subcommands.
- New public routes must use canonical prefixes: `editor/**`, `runtime/**`, `project/**`, `shared/**`.
- Existing no-prefix routes such as `scene/create`, `project/run`, `log/output`, `godot/version`, and `uid/get` must continue to work as legacy aliases.
- Rust GDExtension remains business-logic-free; M1 business logic lives in GDScript runtime helpers and routes.
- Dangerous or destructive routes must require `force:true` and return `unsafe_operation` when missing.
- All new helper files must be installed by `gdcli install` through the existing embedded addon mechanism.
- Do not stage the currently deleted `docs/superpowers/specs/2026-06-27-gdcli-basic-editing-design.md` unless the user explicitly asks.
- Do not add source code comments beyond existing file headers.

## File Structure

- Modify `gdapi/addon/runtime/router.gd`: register canonical routes and legacy aliases; expose route metadata to built-in help routes.
- Modify `gdapi/addon/runtime/route_doc.gd`: add `canonical_path`, `aliases`, and `is_alias` metadata fields.
- Modify `gdapi/addon/runtime/builtin_routes.gd`: return route names plus alias metadata.
- Modify `gdapi/addon/runtime/builtin_help.gd`: include canonical path and aliases in list/detail output.
- Modify `gdapi/addon/runtime/builtin_commands.gd`: include canonical path and aliases in command list output.
- Modify `gdapi/addon/runtime/builtin_command_help.gd`: resolve legacy aliases and include metadata.
- Create `gdapi/addon/runtime/error_codes.gd`: central error code constants and response helpers.
- Create `gdapi/addon/runtime/path_guard.gd`: normalize and validate `res://`/`user://` paths.
- Create `gdapi/addon/runtime/variant_codec.gd`: convert explicit JSON typed values to Godot Variants and back.
- Create `gdapi/addon/runtime/edit_action.gd`: small wrapper around `EditorUndoRedoManager` discovery.
- Create `gdapi/addon/runtime/audit_log.gd`: helper that records audit events through `plugin.gd`.
- Modify `gdapi/addon/plugin.gd`: store audit events and expose list/clear methods.
- Create `gdapi/addon/routes/project/audit/list.gd`: read audit events.
- Create `gdapi/addon/routes/project/audit/clear.gd`: clear audit events only with `force:true`.
- Create `gdapi/addon/routes/project/health/path_check.gd`: E2E-safe route for path guard validation.
- Modify `cli/tests/addon_deploy_test.rs`: assert new runtime helper and route files are installed.
- Create `scripts/e2e-m1-smoke.ps1`: Windows M1 E2E smoke.
- Create `scripts/e2e-m1-smoke.sh`: POSIX M1 E2E smoke.

---

### Task 1: Add M1 E2E Harness First

**Files:**
- Create: `scripts/e2e-m1-smoke.ps1`
- Create: `scripts/e2e-m1-smoke.sh`

**Interfaces:**
- Consumes: current `gdcli install`, `gdcli exec`, `.godot/gdapi.json`.
- Produces: repeatable M1 smoke commands that later tasks must make pass.

- [ ] **Step 1: Write the failing Windows E2E script**

Create `scripts/e2e-m1-smoke.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"

if (-not $env:GODOT_BIN) {
    throw "GODOT_BIN is required for M1 E2E smoke"
}

$RepoRoot = Resolve-Path "$PSScriptRoot/.."
$Fixture = Join-Path $RepoRoot "tests\fixture_project"
$GdcliBin = Join-Path $RepoRoot "target\debug\gdcli.exe"
$GdapiDll = Join-Path $RepoRoot "target\debug\gdapi.dll"
$Meta = Join-Path $Fixture ".godot\gdapi.json"
$AddonBin = Join-Path $Fixture "addons\gdapi\bin\windows"

function Invoke-GdcliJson($ArgsList) {
    $output = & $GdcliBin --json @ArgsList
    if ($LASTEXITCODE -ne 0) {
        throw "gdcli failed: $($ArgsList -join ' ')`n$output"
    }
    return $output | ConvertFrom-Json
}

function Assert-HasRoute($Routes, $Name) {
    if ($Routes -notcontains $Name) {
        throw "missing route: $Name"
    }
}

cargo build --workspace
& $GdcliBin install --project $Fixture --force
if (-not (Test-Path $AddonBin)) { New-Item -ItemType Directory -Force -Path $AddonBin | Out-Null }
Copy-Item $GdapiDll $AddonBin -Force

$Godot = $null
try {
    if (Test-Path $Meta) { Remove-Item -Force $Meta }
    $Godot = Start-Process -FilePath $env:GODOT_BIN -ArgumentList "--editor", "--headless", "--path", $Fixture -PassThru

    $ready = $false
    for ($i = 0; $i -lt 45; $i++) {
        if (Test-Path $Meta) {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw "gdapi.json never appeared" }

    $ping = Invoke-GdcliJson @("exec", "ping", "--project", $Fixture)
    if (-not $ping.ok) { throw "ping did not return ok:true" }

    $routes = Invoke-GdcliJson @("exec", "routes", "--project", $Fixture)
    Assert-HasRoute $routes.routes "editor/scene/create"
    Assert-HasRoute $routes.routes "scene/create"
    Assert-HasRoute $routes.routes "shared/godot/version"
    Assert-HasRoute $routes.routes "godot/version"
    if (-not $routes.aliases."scene/create") { throw "scene/create alias metadata missing" }

    $commands = Invoke-GdcliJson @("exec", "commands", "--project", $Fixture)
    $sceneCreate = $commands.commands | Where-Object { $_.path -eq "editor/scene/create" } | Select-Object -First 1
    if (-not $sceneCreate) { throw "commands missing editor/scene/create" }
    if ($sceneCreate.canonical_path -ne "editor/scene/create") { throw "canonical_path mismatch" }

    $help = Invoke-GdcliJson @("exec", "command-help", "scene/create", "--project", $Fixture)
    if ($help.doc.canonical_path -ne "editor/scene/create") { throw "legacy command-help did not resolve canonical path" }

    $safePath = Invoke-GdcliJson @("exec", "project/health/path_check", "--project", $Fixture, "--data", '{"path":"scenes/test.tscn","mode":"read"}')
    if ($safePath.path -ne "res://scenes/test.tscn") { throw "path_check did not normalize project-relative path" }

    & $GdcliBin --json exec project/health/path_check --project $Fixture --data '{"path":"../outside.txt","mode":"read"}' | Out-Null
    if ($LASTEXITCODE -eq 0) { throw "path traversal was accepted" }

    & $GdcliBin --json exec project/audit/clear --project $Fixture --data '{}' | Out-Null
    if ($LASTEXITCODE -eq 0) { throw "audit clear without force was accepted" }

    $cleared = Invoke-GdcliJson @("exec", "project/audit/clear", "--project", $Fixture, "--data", '{"force":true}')
    if (-not $cleared.ok) { throw "audit clear force failed" }

    Write-Host "PASS: M1 E2E smoke" -ForegroundColor Green
} finally {
    if ($Godot) { Stop-Process -Id $Godot.Id -Force -ErrorAction SilentlyContinue }
}
```

- [ ] **Step 2: Write the failing POSIX E2E script**

Create `scripts/e2e-m1-smoke.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${GODOT_BIN:-}" ]]; then
  echo "GODOT_BIN is required for M1 E2E smoke" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$REPO_ROOT/tests/fixture_project"
GDCLI_BIN="$REPO_ROOT/target/debug/gdcli"
META="$FIXTURE/.godot/gdapi.json"

json_get() {
  python -c 'import json,sys; data=json.load(sys.stdin); cur=data
for part in sys.argv[1].split("."):
    cur=cur[part]
print(cur)'
}

assert_route() {
  local routes_json="$1"
  local name="$2"
  python -c 'import json,sys; data=json.loads(sys.argv[1]); name=sys.argv[2]
assert name in data["routes"], f"missing route: {name}"' "$routes_json" "$name"
}

cargo build --workspace
"$GDCLI_BIN" install --project "$FIXTURE" --force
"$REPO_ROOT/scripts/setup-dev.sh"
rm -f "$META"

"$GODOT_BIN" --editor --headless --path "$FIXTURE" &
GODOT_PID=$!
trap 'kill "$GODOT_PID" 2>/dev/null || true; wait "$GODOT_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 45); do
  if [[ -f "$META" ]]; then
    break
  fi
  sleep 1
done
if [[ ! -f "$META" ]]; then
  echo "gdapi.json never appeared" >&2
  exit 1
fi

PING=$("$GDCLI_BIN" --json exec ping --project "$FIXTURE")
[[ "$(printf '%s' "$PING" | json_get ok)" == "True" || "$(printf '%s' "$PING" | json_get ok)" == "true" ]]

ROUTES=$("$GDCLI_BIN" --json exec routes --project "$FIXTURE")
assert_route "$ROUTES" "editor/scene/create"
assert_route "$ROUTES" "scene/create"
assert_route "$ROUTES" "shared/godot/version"
assert_route "$ROUTES" "godot/version"
python -c 'import json,sys; data=json.loads(sys.argv[1]); assert data["aliases"]["scene/create"] == "editor/scene/create"' "$ROUTES"

COMMANDS=$("$GDCLI_BIN" --json exec commands --project "$FIXTURE")
python -c 'import json,sys; data=json.loads(sys.argv[1]); matches=[c for c in data["commands"] if c["path"]=="editor/scene/create"]; assert matches and matches[0]["canonical_path"]=="editor/scene/create"' "$COMMANDS"

HELP=$("$GDCLI_BIN" --json exec command-help scene/create --project "$FIXTURE")
python -c 'import json,sys; data=json.loads(sys.argv[1]); assert data["doc"]["canonical_path"]=="editor/scene/create"' "$HELP"

SAFE=$("$GDCLI_BIN" --json exec project/health/path_check --project "$FIXTURE" --data '{"path":"scenes/test.tscn","mode":"read"}')
python -c 'import json,sys; data=json.loads(sys.argv[1]); assert data["path"]=="res://scenes/test.tscn"' "$SAFE"

if "$GDCLI_BIN" --json exec project/health/path_check --project "$FIXTURE" --data '{"path":"../outside.txt","mode":"read"}'; then
  echo "path traversal was accepted" >&2
  exit 1
fi

if "$GDCLI_BIN" --json exec project/audit/clear --project "$FIXTURE" --data '{}'; then
  echo "audit clear without force was accepted" >&2
  exit 1
fi

"$GDCLI_BIN" --json exec project/audit/clear --project "$FIXTURE" --data '{"force":true}' >/dev/null
echo "PASS: M1 E2E smoke"
```

- [ ] **Step 3: Make POSIX script executable**

Run:

```bash
git update-index --chmod=+x scripts/e2e-m1-smoke.sh
```

Expected: no output.

- [ ] **Step 4: Run E2E to verify it fails before implementation**

Run on Windows:

```powershell
$env:GODOT_BIN="C:\path\to\Godot_v4.x.exe"
./scripts/e2e-m1-smoke.ps1
```

Expected: FAIL while checking `editor/scene/create` or `project/health/path_check` because M1 router/helper routes do not exist yet.

Run on Linux/macOS:

```bash
GODOT_BIN=/path/to/godot ./scripts/e2e-m1-smoke.sh
```

Expected: FAIL while checking `editor/scene/create` or `project/health/path_check` because M1 router/helper routes do not exist yet.

- [ ] **Step 5: Commit the failing harness**

```bash
git add scripts/e2e-m1-smoke.ps1 scripts/e2e-m1-smoke.sh
git commit -m "test: add gdapi m1 e2e smoke"
```

---

### Task 2: Add Route Metadata and Canonical Namespace Aliases

**Files:**
- Modify: `gdapi/addon/runtime/route_doc.gd`
- Modify: `gdapi/addon/runtime/router.gd`
- Modify: `gdapi/addon/runtime/builtin_routes.gd`
- Modify: `gdapi/addon/runtime/builtin_help.gd`
- Modify: `gdapi/addon/runtime/builtin_commands.gd`
- Modify: `gdapi/addon/runtime/builtin_command_help.gd`

**Interfaces:**
- Consumes: route scripts under `gdapi/addon/routes/{editor,shared}`.
- Produces: `Router.get_route_meta(key) -> Dictionary`, route metadata dictionaries with `canonical_path:String`, `aliases:Array`, `is_alias:bool`.

- [ ] **Step 1: Extend `GdApiRouteDoc` metadata fields**

In `gdapi/addon/runtime/route_doc.gd`, add fields after `var examples`:

```gdscript
var canonical_path: String = ""
var aliases: Array[String] = []
var is_alias: bool = false
```

Add fluent methods before `to_dict()`:

```gdscript
func canonical(path: String) -> GdApiRouteDoc:
	canonical_path = path
	return self

func alias(path: String) -> GdApiRouteDoc:
	if not aliases.has(path):
		aliases.append(path)
	return self

func alias_view(path: String) -> GdApiRouteDoc:
	canonical_path = path
	is_alias = true
	return self
```

Update `to_dict()` to include metadata:

```gdscript
func to_dict() -> Dictionary:
	var param_dicts: Array = []
	for p in params:
		param_dicts.append(p.to_dict())
	return {
		"summary": summary,
		"description": description,
		"params": param_dicts,
		"returns": {
			"description": returns_desc,
			"fields": returns_fields,
		},
		"examples": examples,
		"canonical_path": canonical_path,
		"aliases": aliases,
		"is_alias": is_alias,
	}
```

Update `to_summary_dict()`:

```gdscript
func to_summary_dict() -> Dictionary:
	var param_summary: Array = []
	for p in params:
		param_summary.append({"name": p.name, "required": p.required})
	return {
		"summary": summary,
		"params": param_summary,
		"canonical_path": canonical_path,
		"aliases": aliases,
		"is_alias": is_alias,
	}
```

- [ ] **Step 2: Replace router registration with canonical metadata**

In `gdapi/addon/runtime/router.gd`, add member dictionaries near `_routes`:

```gdscript
var _route_meta: Dictionary = {}
var _alias_to_canonical: Dictionary = {}
var _canonical_to_aliases: Dictionary = {}
```

Replace `scan()` with:

```gdscript
func scan(root_dir: String, force: bool = false) -> void:
	if force:
		_routes.clear()
		_route_meta.clear()
		_alias_to_canonical.clear()
		_canonical_to_aliases.clear()
		_file_mtimes.clear()
		_needs_update = true

	_register_builtin_route("ping", BuiltinPing)

	_scan_context_dir(root_dir, "editor", force)
	_scan_context_dir(root_dir, "shared", force)
	_scan_context_dir(root_dir, "runtime", force)
	_scan_context_dir(root_dir, "project", force)

	if _needs_update:
		_refresh_builtin_handlers()
```

Add helper methods before `_scan_dir_with_mtime`:

```gdscript
func _register_builtin_route(key: String, script: Script) -> void:
	_routes[key] = script
	_route_meta[key] = {
		"canonical_path": key,
		"aliases": [],
		"is_alias": false,
	}

func _scan_context_dir(root_dir: String, context: String, force: bool) -> void:
	var dir_path := root_dir + "/" + context
	_scan_dir_with_mtime(dir_path, context, context, force)

func _legacy_key_for(context: String, relative_key: String) -> String:
	if context == "editor" or context == "shared":
		return relative_key
	return ""

func _register_route(key: String, script: Script, canonical_path: String, is_alias: bool) -> void:
	_routes[key] = script
	var aliases: Array = _canonical_to_aliases.get(canonical_path, [])
	_route_meta[key] = {
		"canonical_path": canonical_path,
		"aliases": aliases,
		"is_alias": is_alias,
	}
	if is_alias:
		_alias_to_canonical[key] = canonical_path

func _register_canonical_and_legacy(context: String, relative_key: String, script: Script) -> void:
	var canonical_path := context + "/" + relative_key
	var legacy_path := _legacy_key_for(context, relative_key)
	var aliases: Array = []
	if legacy_path != "" and legacy_path != canonical_path:
		aliases.append(legacy_path)
		_canonical_to_aliases[canonical_path] = aliases
	_register_route(canonical_path, script, canonical_path, false)
	for alias in aliases:
		_register_route(alias, script, canonical_path, true)

func get_route_meta(key: String) -> Dictionary:
	return _route_meta.get(key, {"canonical_path": key, "aliases": [], "is_alias": false})

func _refresh_builtin_handlers() -> void:
	_builtin_routes_handler = BuiltinRoutes.new()
	_builtin_help_handler = BuiltinHelp.new()
	_builtin_commands_handler = BuiltinCommands.new()
	_builtin_command_help_handler = BuiltinCommandHelp.new()
	var names: Array = _routes.keys()
	names.append("routes")
	names.append("help")
	names.append("commands")
	names.append("command-help")
	names.sort()
	_builtin_routes_handler.set_route_names(names)
	_builtin_routes_handler.set_route_meta(_route_meta, _alias_to_canonical)

	var all_routes: Dictionary = _routes.duplicate()
	all_routes["routes"] = BuiltinRoutes
	all_routes["help"] = BuiltinHelp
	all_routes["commands"] = BuiltinCommands
	all_routes["command-help"] = BuiltinCommandHelp
	var all_meta := _route_meta.duplicate()
	for builtin in ["routes", "help", "commands", "command-help"]:
		all_meta[builtin] = {"canonical_path": builtin, "aliases": [], "is_alias": false}
	_builtin_help_handler.set_routes(all_routes)
	_builtin_help_handler.set_route_meta(all_meta)
	_builtin_commands_handler.set_routes(all_routes)
	_builtin_commands_handler.set_route_meta(all_meta)
	_builtin_command_help_handler.set_routes(all_routes)
	_builtin_command_help_handler.set_route_meta(all_meta)
	_needs_update = false
```

Replace `_scan_dir_with_mtime` signature and route registration body:

```gdscript
func _scan_dir_with_mtime(dir_path: String, prefix: String, context: String, force: bool) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := dir_path + "/" + name
		if dir.current_is_dir():
			var sub_prefix := (prefix + "/" + name) if prefix != "" else name
			_scan_dir_with_mtime(full, sub_prefix, context, force)
		elif name.ends_with(".gd") and not name.begins_with("_"):
			var route_name := name.substr(0, name.length() - 3)
			var key := (prefix + "/" + route_name) if prefix != "" else route_name
			var relative_key := key.trim_prefix(context + "/")
			var mtime := FileAccess.get_modified_time(full)
			var old_mtime: int = _file_mtimes.get(full, 0)
			if force or mtime != old_mtime:
				var script: Script = load(full) as Script
				if script != null:
					_register_canonical_and_legacy(context, relative_key, script)
					_file_mtimes[full] = mtime
					_needs_update = true
		name = dir.get_next()
	dir.list_dir_end()
```

- [ ] **Step 3: Update built-in route list metadata**

In `builtin_routes.gd`, add fields and setter:

```gdscript
var _route_meta: Dictionary = {}
var _alias_to_canonical: Dictionary = {}

func set_route_meta(route_meta: Dictionary, alias_to_canonical: Dictionary) -> void:
	_route_meta = route_meta
	_alias_to_canonical = alias_to_canonical
```

Replace `handle()`:

```gdscript
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	res.json({
		"ok": true,
		"routes": _route_names,
		"aliases": _alias_to_canonical,
		"meta": _route_meta,
	})
```

- [ ] **Step 4: Update help and commands to inject metadata**

In each of `builtin_help.gd`, `builtin_commands.gd`, and `builtin_command_help.gd`, add:

```gdscript
var _route_meta: Dictionary = {}

func set_route_meta(route_meta: Dictionary) -> void:
	_route_meta = route_meta

func _apply_meta(path: String, doc: Dictionary) -> Dictionary:
	var meta: Dictionary = _route_meta.get(path, {"canonical_path": path, "aliases": [], "is_alias": false})
	doc["path"] = path
	doc["canonical_path"] = meta.get("canonical_path", path)
	doc["aliases"] = meta.get("aliases", [])
	doc["is_alias"] = meta.get("is_alias", false)
	return doc
```

In `builtin_help.gd`, replace detail path assignment:

```gdscript
var handler = _routes[path].new()
var detail: Dictionary = _apply_meta(path, handler.doc().to_dict())
res.json({"ok": true, "doc": detail})
```

In `builtin_help.gd`, replace list append:

```gdscript
var summary: Dictionary = _apply_meta(key, handler.doc().to_summary_dict())
result.append(summary)
```

In `builtin_commands.gd`, replace list append:

```gdscript
var summary: Dictionary = _apply_meta(key, handler.doc().to_summary_dict())
result.append(summary)
```

In `builtin_command_help.gd`, replace detail path assignment:

```gdscript
var handler = _routes[command].new()
var detail: Dictionary = _apply_meta(command, handler.doc().to_dict())
res.json({"ok": true, "doc": detail})
```

- [ ] **Step 5: Run tests and expected E2E partial result**

Run:

```bash
cargo test --workspace
```

Expected: PASS.

Run with Godot:

```bash
GODOT_BIN=/path/to/godot ./scripts/e2e-m1-smoke.sh
```

Expected: FAIL at `project/health/path_check` because canonical route aliases now work but helper routes are not implemented.

- [ ] **Step 6: Commit route namespace work**

```bash
git add gdapi/addon/runtime/router.gd gdapi/addon/runtime/route_doc.gd gdapi/addon/runtime/builtin_routes.gd gdapi/addon/runtime/builtin_help.gd gdapi/addon/runtime/builtin_commands.gd gdapi/addon/runtime/builtin_command_help.gd
git commit -m "feat(gdapi): add canonical route aliases"
```

---

### Task 3: Add Shared Runtime Helpers and Path Health Route

**Files:**
- Create: `gdapi/addon/runtime/error_codes.gd`
- Create: `gdapi/addon/runtime/path_guard.gd`
- Create: `gdapi/addon/runtime/variant_codec.gd`
- Create: `gdapi/addon/runtime/edit_action.gd`
- Create: `gdapi/addon/routes/project/health/path_check.gd`
- Modify: `cli/tests/addon_deploy_test.rs`

**Interfaces:**
- Produces: `GdApiPathGuard.validate(path:String, mode:String) -> Dictionary`.
- Produces: `GdApiVariantCodec.to_variant(value:Variant) -> Variant` and `from_variant(value:Variant) -> Variant`.
- Produces: `GdApiEditAction.undo_redo() -> EditorUndoRedoManager`.
- Produces: `project/health/path_check` route for E2E validation.

- [ ] **Step 1: Add install packaging test first**

Append this test to `cli/tests/addon_deploy_test.rs`:

```rust
#[test]
fn install_includes_m1_runtime_helpers() {
    let dir = TempDir::new().unwrap();
    make_godot_project(dir.path());

    Command::cargo_bin("gdcli")
        .unwrap()
        .args(["install", "--project", dir.path().to_str().unwrap()])
        .assert()
        .success();

    for file in [
        "addons/gdapi/runtime/error_codes.gd",
        "addons/gdapi/runtime/path_guard.gd",
        "addons/gdapi/runtime/variant_codec.gd",
        "addons/gdapi/runtime/edit_action.gd",
        "addons/gdapi/routes/project/health/path_check.gd",
    ] {
        assert!(dir.path().join(file).exists(), "missing installed file: {file}");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cargo test -p gdcli --test addon_deploy_test install_includes_m1_runtime_helpers
```

Expected: FAIL with `missing installed file: addons/gdapi/runtime/error_codes.gd`.

- [ ] **Step 3: Create `error_codes.gd`**

Create `gdapi/addon/runtime/error_codes.gd`:

```gdscript
@tool
class_name GdApiErrorCodes
extends RefCounted

const MISSING_PARAM := "missing_param"
const INVALID_PARAM := "invalid_param"
const INVALID_PATH := "invalid_path"
const NOT_FOUND := "not_found"
const CONFLICT := "conflict"
const NOT_SUPPORTED := "not_supported"
const PERMISSION_DENIED := "permission_denied"
const UNSAFE_OPERATION := "unsafe_operation"
const TIMEOUT := "timeout"
const GODOT_ERROR := "godot_error"

static func require_force(res: GdApiResponse, force: bool, operation: String) -> bool:
	if force:
		return true
	res.error(operation + " requires force:true", UNSAFE_OPERATION, 403)
	return false
```

- [ ] **Step 4: Create `path_guard.gd`**

Create `gdapi/addon/runtime/path_guard.gd`:

```gdscript
@tool
class_name GdApiPathGuard
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const BLOCKED_WRITE_PREFIXES := [
	"res://addons/gdapi/",
	"res://.godot/",
]

static func validate(path: String, mode: String = "read") -> Dictionary:
	if path.strip_edges().is_empty():
		return _err("path is required", ErrorCodes.INVALID_PATH)
	if path.contains(".."):
		return _err("path traversal is not allowed", ErrorCodes.INVALID_PATH)
	if path.is_absolute_path():
		return _err("absolute system paths are not allowed", ErrorCodes.INVALID_PATH)
	var normalized := normalize(path)
	if not normalized.begins_with("res://") and not normalized.begins_with("user://"):
		return _err("only res:// and user:// paths are allowed", ErrorCodes.INVALID_PATH)
	if mode == "write" or mode == "delete":
		for prefix in BLOCKED_WRITE_PREFIXES:
			if normalized.begins_with(prefix):
				return _err("path is protected: " + normalized, ErrorCodes.PERMISSION_DENIED, 403)
	return {"ok": true, "path": normalized}

static func normalize(path: String) -> String:
	var p := path.strip_edges().replace("\\", "/")
	if p.begins_with("res://") or p.begins_with("user://"):
		return p
	return "res://" + p.trim_prefix("/")

static func _err(message: String, code: String, status: int = 400) -> Dictionary:
	return {"ok": false, "error": message, "code": code, "status": status}
```

- [ ] **Step 5: Create `variant_codec.gd`**

Create `gdapi/addon/runtime/variant_codec.gd`:

```gdscript
@tool
class_name GdApiVariantCodec
extends RefCounted

static func to_variant(value: Variant) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return value
	if not value.has("type"):
		return value
	var type_name: String = value.get("type", "")
	var raw = value.get("value", null)
	match type_name:
		"Vector2": return Vector2(float(raw[0]), float(raw[1]))
		"Vector2i": return Vector2i(int(raw[0]), int(raw[1]))
		"Vector3": return Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
		"Vector3i": return Vector3i(int(raw[0]), int(raw[1]), int(raw[2]))
		"Vector4": return Vector4(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]))
		"Vector4i": return Vector4i(int(raw[0]), int(raw[1]), int(raw[2]), int(raw[3]))
		"Color": return Color(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]) if raw.size() > 3 else 1.0)
		"Rect2": return Rect2(to_variant({"type":"Vector2","value":raw[0]}), to_variant({"type":"Vector2","value":raw[1]}))
		"Rect2i": return Rect2i(to_variant({"type":"Vector2i","value":raw[0]}), to_variant({"type":"Vector2i","value":raw[1]}))
		"Quaternion": return Quaternion(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]))
		"NodePath": return NodePath(str(raw))
		"Resource": return load(str(raw))
		_: return value

static func from_variant(value: Variant) -> Variant:
	match typeof(value):
		TYPE_VECTOR2: return {"type":"Vector2", "value":[value.x, value.y]}
		TYPE_VECTOR2I: return {"type":"Vector2i", "value":[value.x, value.y]}
		TYPE_VECTOR3: return {"type":"Vector3", "value":[value.x, value.y, value.z]}
		TYPE_VECTOR3I: return {"type":"Vector3i", "value":[value.x, value.y, value.z]}
		TYPE_VECTOR4: return {"type":"Vector4", "value":[value.x, value.y, value.z, value.w]}
		TYPE_VECTOR4I: return {"type":"Vector4i", "value":[value.x, value.y, value.z, value.w]}
		TYPE_COLOR: return {"type":"Color", "value":[value.r, value.g, value.b, value.a]}
		TYPE_RECT2: return {"type":"Rect2", "value":[from_variant(value.position).value, from_variant(value.size).value]}
		TYPE_RECT2I: return {"type":"Rect2i", "value":[from_variant(value.position).value, from_variant(value.size).value]}
		TYPE_QUATERNION: return {"type":"Quaternion", "value":[value.x, value.y, value.z, value.w]}
		TYPE_NODE_PATH: return {"type":"NodePath", "value":str(value)}
		TYPE_OBJECT:
			if value is Resource and value.resource_path != "":
				return {"type":"Resource", "value":value.resource_path}
			return str(value)
		_: return value
```

- [ ] **Step 6: Create `edit_action.gd`**

Create `gdapi/addon/runtime/edit_action.gd`:

```gdscript
@tool
class_name GdApiEditAction
extends RefCounted

static func plugin():
	if Engine.has_meta("gdapi_plugin"):
		return Engine.get_meta("gdapi_plugin")
	return null

static func undo_redo():
	var p = plugin()
	if p and p.has_method("get_undo_redo"):
		return p.get_undo_redo()
	return null

static func has_undo_redo() -> bool:
	return undo_redo() != null
```

- [ ] **Step 7: Create path health route**

Create `gdapi/addon/routes/project/health/path_check.gd`:

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var path: String = req.get_body("path", "")
	var mode: String = req.get_body("mode", "read")
	var result := PathGuard.validate(path, mode)
	if not result.ok:
		res.error(result.error, result.code, result.status)
		return
	res.json({"ok": true, "path": result.path, "mode": mode})

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("校验并规范化项目路径")
		.desc("用于验证 gdapi 路径安全策略；返回规范化后的 res:// 或 user:// 路径")
		.param("path", "String", true, "待校验路径")
		.param("mode", "String", false, "read、write 或 delete", "read")
		.returns("路径校验结果", {"ok":"bool", "path":"String", "mode":"String"})
	)
```

- [ ] **Step 8: Run tests and E2E partial result**

Run:

```bash
cargo test -p gdcli --test addon_deploy_test install_includes_m1_runtime_helpers
cargo test --workspace
```

Expected: PASS.

Run with Godot:

```bash
GODOT_BIN=/path/to/godot ./scripts/e2e-m1-smoke.sh
```

Expected: FAIL at `project/audit/clear` because audit routes are not implemented yet.

- [ ] **Step 9: Commit shared helper work**

```bash
git add cli/tests/addon_deploy_test.rs gdapi/addon/runtime/error_codes.gd gdapi/addon/runtime/path_guard.gd gdapi/addon/runtime/variant_codec.gd gdapi/addon/runtime/edit_action.gd gdapi/addon/routes/project/health/path_check.gd
git commit -m "feat(gdapi): add m1 runtime helpers"
```

---

### Task 4: Add Audit Buffer and Audit Routes

**Files:**
- Create: `gdapi/addon/runtime/audit_log.gd`
- Modify: `gdapi/addon/plugin.gd`
- Create: `gdapi/addon/routes/project/audit/list.gd`
- Create: `gdapi/addon/routes/project/audit/clear.gd`
- Modify: `cli/tests/addon_deploy_test.rs`

**Interfaces:**
- Produces: plugin methods `audit_event(event:Dictionary)`, `get_audit_since(since:int, limit:int) -> Array`, `clear_audit() -> void`.
- Produces: `project/audit/list` and `project/audit/clear` routes.

- [ ] **Step 1: Extend install packaging test for audit files**

In `install_includes_m1_runtime_helpers`, extend the file array with:

```rust
"addons/gdapi/runtime/audit_log.gd",
"addons/gdapi/routes/project/audit/list.gd",
"addons/gdapi/routes/project/audit/clear.gd",
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cargo test -p gdcli --test addon_deploy_test install_includes_m1_runtime_helpers
```

Expected: FAIL with `missing installed file: addons/gdapi/runtime/audit_log.gd`.

- [ ] **Step 3: Add audit state to plugin**

In `gdapi/addon/plugin.gd`, add constants and fields after log fields:

```gdscript
const MAX_AUDIT_ENTRIES: int = 1000

var _audit_buffer: Array = []
var _audit_seq: int = 0
```

Add methods after `get_log_since`:

```gdscript
func audit_event(event: Dictionary) -> void:
	_audit_seq += 1
	var entry := event.duplicate(true)
	entry["seq"] = _audit_seq
	entry["ts"] = Time.get_unix_time_from_system()
	_audit_buffer.append(entry)
	if _audit_buffer.size() > MAX_AUDIT_ENTRIES:
		_audit_buffer.pop_front()

func get_audit_since(since: int, limit: int) -> Array:
	var entries: Array = []
	for entry in _audit_buffer:
		if entry.seq > since:
			entries.append(entry)
			if entries.size() >= limit:
				break
	return entries

func clear_audit() -> void:
	_audit_buffer.clear()
```

- [ ] **Step 4: Create audit helper**

Create `gdapi/addon/runtime/audit_log.gd`:

```gdscript
@tool
class_name GdApiAuditLog
extends RefCounted

static func record(route: String, safety: String, summary: Dictionary, ok: bool, code: String = "") -> void:
	if not Engine.has_meta("gdapi_plugin"):
		return
	var plugin = Engine.get_meta("gdapi_plugin")
	if not plugin or not plugin.has_method("audit_event"):
		return
	plugin.audit_event({
		"route": route,
		"safety": safety,
		"summary": summary,
		"ok": ok,
		"code": code,
	})
```

- [ ] **Step 5: Create audit list route**

Create `gdapi/addon/routes/project/audit/list.gd`:

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	if not Engine.has_meta("gdapi_plugin"):
		res.error("gdapi plugin is unavailable", "godot_error", 500)
		return
	var plugin = Engine.get_meta("gdapi_plugin")
	var since: int = int(req.get_body("since", 0))
	var limit: int = int(req.get_body("limit", 100))
	if limit < 1:
		limit = 1
	if limit > 1000:
		limit = 1000
	res.json({"ok": true, "entries": plugin.get_audit_since(since, limit)})

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("读取 gdapi 审计日志")
		.desc("返回指定 seq 之后的审计日志条目")
		.param("since", "int", false, "起始 seq，不包含该值", 0)
		.param("limit", "int", false, "最大返回数量，范围 1..1000", 100)
		.returns("审计日志列表", {"ok":"bool", "entries":"Array"})
	)
```

- [ ] **Step 6: Create audit clear route with force requirement**

Create `gdapi/addon/routes/project/audit/clear.gd`:

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var force: bool = bool(req.get_body("force", false))
	if not ErrorCodes.require_force(res, force, "project/audit/clear"):
		AuditLog.record("project/audit/clear", "dangerous", {"force": false}, false, ErrorCodes.UNSAFE_OPERATION)
		return
	if not Engine.has_meta("gdapi_plugin"):
		res.error("gdapi plugin is unavailable", ErrorCodes.GODOT_ERROR, 500)
		return
	var plugin = Engine.get_meta("gdapi_plugin")
	plugin.clear_audit()
	AuditLog.record("project/audit/clear", "dangerous", {"force": true}, true)
	res.json({"ok": true, "cleared": true})

func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("清空 gdapi 审计日志")
		.desc("危险操作；必须传 force:true")
		.param("force", "bool", true, "必须为 true 才会清空审计日志", false)
		.returns("清空结果", {"ok":"bool", "cleared":"bool"})
	)
```

- [ ] **Step 7: Run tests and M1 E2E**

Run:

```bash
cargo test -p gdcli --test addon_deploy_test install_includes_m1_runtime_helpers
cargo test --workspace
```

Expected: PASS.

Run with Godot:

```bash
GODOT_BIN=/path/to/godot ./scripts/e2e-m1-smoke.sh
```

Expected: PASS.

- [ ] **Step 8: Commit audit work**

```bash
git add cli/tests/addon_deploy_test.rs gdapi/addon/plugin.gd gdapi/addon/runtime/audit_log.gd gdapi/addon/routes/project/audit/list.gd gdapi/addon/routes/project/audit/clear.gd
git commit -m "feat(gdapi): add audit log routes"
```

---

### Task 5: Final Verification and Documentation Touches

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md` only if implementation reveals a mismatch.

**Interfaces:**
- Consumes: M1 scripts and routes from Tasks 1-4.
- Produces: documented M1 smoke command and final verification evidence.

- [ ] **Step 1: Add README E2E command**

In `README.md`, after the `gdcli status` section, add:

```markdown
---

## 开发验证

M1 gdapi 路由基础设施端到端验证需要设置 `GODOT_BIN`：

```bash
GODOT_BIN=/path/to/godot ./scripts/e2e-m1-smoke.sh
```

Windows：

```powershell
$env:GODOT_BIN="C:\path\to\Godot.exe"
./scripts/e2e-m1-smoke.ps1
```
```

- [ ] **Step 2: Run Rust verification**

Run:

```bash
cargo fmt --check
cargo clippy --workspace
cargo test --workspace
```

Expected: all PASS.

- [ ] **Step 3: Run M1 E2E verification**

Run on the current platform:

```bash
GODOT_BIN=/path/to/godot ./scripts/e2e-m1-smoke.sh
```

or:

```powershell
$env:GODOT_BIN="C:\path\to\Godot.exe"
./scripts/e2e-m1-smoke.ps1
```

Expected: `PASS: M1 E2E smoke`.

- [ ] **Step 4: Inspect git status and avoid unrelated deletion**

Run:

```bash
git status --short
```

Expected tracked changes for M1 only. If `D docs/superpowers/specs/2026-06-27-gdcli-basic-editing-design.md` is still present, do not stage it.

- [ ] **Step 5: Commit documentation touch**

```bash
git add README.md
git commit -m "docs: document gdapi m1 smoke test"
```

- [ ] **Step 6: Report verification evidence**

Return these exact items to the user:

```text
M1 route infrastructure implemented.
Verified:
- cargo fmt --check
- cargo clippy --workspace
- cargo test --workspace
- scripts/e2e-m1-smoke on <platform>
```

## Self-Review

Spec coverage:

- Canonical route namespaces: Task 2.
- Legacy aliases: Task 2.
- Route metadata in help/commands/routes: Task 2.
- Path guard: Task 3.
- Variant codec: Task 3.
- UndoRedo helper: Task 3.
- Error helper: Task 3.
- Audit helper and audit routes: Task 4.
- E2E harness with positive and negative checks: Task 1 plus Task 4.
- Final lint/type/test/E2E verification: Task 5.

Plan quality scan result: all steps specify concrete files, commands, and expected results; no incomplete sections remain.

Type consistency:

- `set_route_meta(route_meta, alias_to_canonical)` is only used by `BuiltinRoutes`.
- `set_route_meta(route_meta)` is used by help, commands, and command-help.
- `GdApiPathGuard.validate(path, mode)` returns `ok`, and on failure returns `error`, `code`, `status`.
- `GdApiAuditLog.record(route, safety, summary, ok, code)` is used by `project/audit/clear`.
