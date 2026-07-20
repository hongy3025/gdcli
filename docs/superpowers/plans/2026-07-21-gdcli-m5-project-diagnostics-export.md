# gdcli M5 Project Diagnostics and Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add snapshot-restorable project configuration, stable engine introspection, actionable diagnostics, UID repair, controlled export, and explicitly confirmed single-device Android deployment.

**Architecture:** Project configuration mutations operate on a private test snapshot and persist through Godot APIs. Diagnostics are read-only analyzers with machine-stable findings. Because Godot 4.7 does not expose an editor singleton for enumerating every built-in export platform, export presets are read through `ConfigFile` and executed by a fixed Godot CLI bridge using only `OS.get_executable_path()` and documented export arguments; Android discovery/deployment uses a second fixed-command bridge for the editor-configured ADB executable.

**Tech Stack:** Godot 4.7 ProjectSettings/InputMap/ClassDB/ResourceUID/ConfigFile/OS pipe APIs, fixed Godot export and ADB bridges, M1–M4 safety contracts, pytest/uv.

## Global Constraints

- Support only Godot 4.7.x and require completed M1–M4 plans.
- Snapshot `project.godot`, `export_presets.cfg`, bus layout, and autoload scripts before every configuration test and restore them in teardown.
- Project mutations are non-undoable persistent operations and always return `undoable:false`.
- Removing settings, actions, events, autoloads, repairing UIDs, exporting, and deploying requires `force:true`.
- ClassDB and diagnostics results are sorted, filterable, and paginated with default limit 100 and maximum 500.
- Export destinations stay inside the isolated project or an explicitly configured export root.
- Missing export templates are an explicit `not_supported` response with platform details; tests do not silently skip.
- Android deploy selects one exact serial, requires `force:true`, and rejects ambiguous/offline/unauthorized devices.
- The ADB bridge exposes only `devices -l`, `install -r <validated-apk>`, and `shell am start -n <validated-package/activity>`.
- Every persistent or external mutation is audited; keystore paths/passwords, device secrets, and environment values are redacted.

## File Structure

| File | Responsibility after M5 |
|---|---|
| `gdapi/addon/runtime/services/project_config.gd` | Settings, InputMap, and autoload mutation/persistence |
| `gdapi/addon/runtime/services/classdb_query.gd` | Stable filtered ClassDB reflection |
| `gdapi/addon/runtime/services/uid_repair.gd` | UID scan, collision/missing detection, dry run, and repair |
| `gdapi/addon/runtime/services/diagnostics.gd` | Health, unused, cycles, and script-error analyzers |
| `gdapi/addon/runtime/services/export_service.gd` | ConfigFile preset discovery and fixed Godot CLI export lifecycle |
| `gdapi/addon/runtime/services/android_bridge.gd` | Fixed ADB discovery/install/launch commands |
| `gdapi/addon/routes/{project,classdb,uid,diagnostics,export}/**` | Public M5 route adapters |
| `tests/fixtures/m5_project/**` | Snapshot-safe diagnostics and export fixture |
| `tests/e2e/m5/**` | Configuration, diagnosis, export, and optional-device acceptance |

---

### Task 1: Add Snapshot-Safe M5 Fixture Infrastructure

**Files:**
- Create: `tests/fixtures/m5_project/project.godot`
- Create: `tests/fixtures/m5_project/export_presets.cfg`
- Create: `tests/fixtures/m5_project/fixtures/{unused.tres,cycle_a.tres,cycle_b.tres,broken.gd}`
- Create: `tests/fixtures/m5_project/fixtures/state.gd`
- Create: `tests/e2e/m5/conftest.py`
- Create: `tests/e2e/m5/test_snapshot_restore.py`

**Interfaces:**
- Produces `m5_editor`, `read_only_project_file`, `project_snapshot(env) -> dict[path,sha256]`, `restore_snapshot(env)`, `assert_snapshot_restored(env,before)`, `tree_digest(path) -> str`, `restart_editor(env)`, and positional `command_doc(env,route)`.
- Optional Android tests consume `ANDROID_TEST_SERIAL`; absence skips only the real-device deploy positive case, never device-list or error-contract tests.

- [ ] **Step 1: Write restoration tests**

```python
def test_project_snapshot_restores_after_mutation(m5_editor):
    before = project_snapshot(m5_editor)
    path = m5_editor["project"] / "project.godot"
    path.write_text(path.read_text(encoding="utf-8") + "\n[temporary]\nvalue=1\n", encoding="utf-8")
    restore_snapshot(m5_editor)
    assert project_snapshot(m5_editor) == before


def test_source_fixture_is_immutable(m5_editor):
    assert tree_digest(m5_editor["source_fixture"]) == m5_editor["source_digest"]
```

- [ ] **Step 2: Run and verify missing harness failure**

Run: `uv run pytest tests/e2e/m5/test_snapshot_restore.py -v`

Expected: ERROR because `m5_editor` and snapshot helpers do not exist.

- [ ] **Step 3: Implement per-test copied project and byte snapshots**

Copy the immutable fixture, capture every tracked configuration file as bytes, and restore with atomic temporary-file replacement. After restore, trigger filesystem rescan and restart the editor when project settings/autoloads changed.

- [ ] **Step 4: Verify restoration and stale metadata cleanup**

Run: `uv run pytest tests/e2e/m5/test_snapshot_restore.py -v`

Expected: PASS; source digest unchanged and `.godot/gdapi.json` removed after teardown.

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/m5_project tests/e2e/m5
git commit -m "test: add snapshot-safe M5 fixture"
```

---

### Task 2: Add Project Settings, InputMap, and Autoload Routes

**Files:**
- Create: `gdapi/addon/runtime/services/project_config.gd`
- Create: `gdapi/addon/routes/project/settings/{get,set,list,reset}.gd`
- Create: `gdapi/addon/routes/project/input_map/list.gd`
- Create: `gdapi/addon/routes/project/input_map/action/{add,remove}.gd`
- Create: `gdapi/addon/routes/project/input_map/{bind,unbind}.gd`
- Create: `gdapi/addon/routes/project/autoload/{list,add,remove}.gd`
- Create: `tests/e2e/m5/test_project_config.py`

**Interfaces:**
- Setting values use VariantCodec; set body `{name,value}` and reset body `{name,force}`.
- Input events use tagged dictionaries for key, mouse button, joypad button/motion, and action deadzone.
- Autoload add consumes `{name,path,singleton}` and remove consumes `{name,force}`.

- [ ] **Step 1: Write persistence and restoration tests**

```python
def test_settings_input_and_autoload_persist(m5_editor):
    exec_ok(m5_editor, "project/settings/set", {
        "name":"application/config/name", "value":"M5 Fixture"
    })
    exec_ok(m5_editor, "project/input_map/action/add", {"action":"dash","deadzone":0.4})
    exec_ok(m5_editor, "project/input_map/bind", {
        "action":"dash", "event":{"type":"InputEventKey","keycode":4194321,"physical":False}
    })
    exec_ok(m5_editor, "project/autoload/add", {
        "name":"FixtureState", "path":"res://fixtures/state.gd", "singleton":True
    })
    restart_editor(m5_editor)
    assert exec_ok(m5_editor, "project/settings/get", {"name":"application/config/name"})["value"] == "M5 Fixture"
    assert exec_ok(m5_editor, "project/input_map/list", {"filter":"dash"})["actions"][0]["events"][0]["type"] == "InputEventKey"
    assert exec_ok(m5_editor, "project/autoload/list")["autoloads"][0]["name"] == "FixtureState"
```

Add this exact rejection matrix and rollback check:

```python
@pytest.mark.parametrize("route,data,code", [
    ("project/settings/set", {"name":"missing/setting","value":1}, "not_found"),
    ("project/settings/set", {"name":"_gdapi/internal","value":1}, "permission_denied"),
    ("project/input_map/action/add", {"action":"ui_accept"}, "conflict"),
    ("project/input_map/unbind", {"action":"ui_accept","event":{"type":"InputEventKey","keycode":1}}, "not_found"),
    ("project/settings/reset", {"name":"application/config/name"}, "unsafe_operation"),
    ("project/autoload/add", {"name":"Bad","path":"res://addons/gdapi/plugin.gd","singleton":True}, "permission_denied"),
])
def test_project_config_rejections(m5_editor, route, data, code):
    before = project_snapshot(m5_editor)
    assert exec_error(m5_editor, route, data)["code"] == code
    assert project_snapshot(m5_editor) == before


def test_duplicate_and_unforced_autoload_rejected(m5_editor):
    body = {"name":"FixtureState","path":"res://fixtures/state.gd","singleton":True}
    exec_ok(m5_editor, "project/autoload/add", body)
    assert exec_error(m5_editor, "project/autoload/add", body)["code"] == "conflict"
    assert exec_error(m5_editor, "project/autoload/remove", {"name":"FixtureState"})["code"] == "unsafe_operation"


def test_project_save_failure_rolls_back_memory(m5_editor, read_only_project_file):
    before = exec_ok(m5_editor, "project/settings/get", {"name":"application/config/name"})["value"]
    assert exec_error(m5_editor, "project/settings/set", {"name":"application/config/name","value":"Cannot Save"})["code"] == "godot_error"
    assert exec_ok(m5_editor, "project/settings/get", {"name":"application/config/name"})["value"] == before
```

- [ ] **Step 2: Run project configuration tests**

Run: `uv run pytest tests/e2e/m5/test_project_config.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement atomic project configuration mutations**

Validate names against `ProjectSettings.get_property_list()`, set/reset with `ProjectSettings.set_setting`, and persist with `ProjectSettings.save()`. Encode InputEvents through a fixed type mapping and call InputMap APIs before `ProjectSettings.save()`. Add/remove autoload through `EditorPlugin.add_autoload_singleton`/`remove_autoload_singleton`; require script paths under `res://` and outside protected addon internals. On save failure restore the previous in-memory value/event/autoload before replying.

- [ ] **Step 4: Verify persistence, audit, and teardown restoration**

Run: `uv run pytest tests/e2e/m5/test_project_config.py -v`

Expected: PASS and the fixture snapshot after teardown equals its initial snapshot.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/project_config.gd gdapi/addon/routes/project tests/e2e/m5/test_project_config.py
git commit -m "feat: add project configuration routes"
```

---

### Task 3: Add Stable ClassDB Reflection

**Files:**
- Create: `gdapi/addon/runtime/services/classdb_query.gd`
- Create: `gdapi/addon/routes/classdb/{classes,class,methods,properties,signals,inheriters}.gd`
- Create: `tests/e2e/m5/test_classdb.py`

**Interfaces:**
- Produces routes `classdb/classes`, `classdb/class`, `classdb/methods`, `classdb/properties`, `classdb/signals`, and `classdb/inheriters`.
- All list routes consume `{class?,filter?,inherited?,offset?,limit?}`.
- Class response contains `{name,parent,instantiable,exposed,enum_names}`.
- Methods/properties/signals normalize Godot dictionaries to stable name/type/flags/default structures and sort by name.

- [ ] **Step 1: Write stable reflection and pagination tests**

```python
def test_classdb_node2d_contract(m5_editor):
    detail = exec_ok(m5_editor, "classdb/class", {"class":"Node2D"})
    assert detail["name"] == "Node2D" and detail["parent"] == "CanvasItem"
    props = exec_ok(m5_editor, "classdb/properties", {
        "class":"Node2D", "filter":"position", "inherited":False
    })
    assert [item["name"] for item in props["items"]] == ["position"]
    assert props["items"][0]["type"] == "Vector2"


def test_classdb_pagination_is_stable(m5_editor):
    first = exec_ok(m5_editor, "classdb/classes", {"offset":0,"limit":10})
    second = exec_ok(m5_editor, "classdb/classes", {"offset":10,"limit":10})
    assert not set(first["items"]) & set(second["items"])
    assert first["items"] == sorted(first["items"])
```

- [ ] **Step 2: Run ClassDB tests**

Run: `uv run pytest tests/e2e/m5/test_classdb.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement normalized ClassDB queries**

Use `ClassDB.get_class_list`, `get_parent_class`, `can_instantiate`, `is_class_exposed`, and the method/property/signal list APIs. Convert integer Variant type IDs with `type_string`, strip unstable object references, include usage/method flags as integers, then sort before pagination. Unknown classes return `not_found`.

- [ ] **Step 4: Verify all query families and docs**

Run: `uv run pytest tests/e2e/m5/test_classdb.py -v`

Expected: PASS with maximum limit enforcement and deterministic repeated results.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/classdb_query.gd gdapi/addon/routes/classdb tests/e2e/m5/test_classdb.py
git commit -m "feat: add stable ClassDB query routes"
```

---

### Task 4: Add Dry-Run UID Repair

**Files:**
- Create: `gdapi/addon/runtime/services/uid_repair.gd`
- Create: `gdapi/addon/routes/uid/repair.gd`
- Create: `tests/e2e/m5/test_uid_repair.py`

**Interfaces:**
- `uid/repair` consumes `{roots=["res://"],dry_run=true,force=false}`.
- Returns `{scanned,missing,collisions,changes,changed,undoable:false}`; `changes` contains `{path,old_uid,new_uid,status}`.
- Non-dry-run requires force and uses `ResourceSaver.set_uid(path, uid)`.

- [ ] **Step 1: Write dry-run, repair, and idempotence tests**

```python
def test_uid_repair_dry_run_then_apply(m5_editor):
    before = tree_digest(m5_editor["project"])
    dry = exec_ok(m5_editor, "uid/repair", {"roots":["res://fixtures"],"dry_run":True})
    assert dry["missing"] >= 1 and dry["changed"] is False
    assert tree_digest(m5_editor["project"]) == before
    applied = exec_ok(m5_editor, "uid/repair", {
        "roots":["res://fixtures"],"dry_run":False,"force":True
    })
    assert applied["changed"] is True
    assert exec_ok(m5_editor, "uid/repair", {"roots":["res://fixtures"],"dry_run":True})["changes"] == []
```

- [ ] **Step 2: Run UID tests**

Run: `uv run pytest tests/e2e/m5/test_uid_repair.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement deterministic UID planning and application**

Scan importable resource extensions, obtain current UID with ResourceLoader/ResourceUID, group collisions, and generate new IDs with `ResourceUID.create_id()`. Sort paths before assigning IDs so the change order is deterministic. Validate the complete plan before applying; if any set fails, return `godot_error` with per-path details and retain audit evidence.

- [ ] **Step 4: Verify dry-run purity and applied idempotence**

Run: `uv run pytest tests/e2e/m5/test_uid_repair.py -v`

Expected: PASS, including traversal/protected-root negatives and exact audit route.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/uid_repair.gd gdapi/addon/routes/uid/repair.gd tests/e2e/m5/test_uid_repair.py
git commit -m "feat: add dry-run UID repair"
```

---

### Task 5: Add Project Diagnostics

**Files:**
- Create: `gdapi/addon/runtime/services/diagnostics.gd`
- Create: `gdapi/addon/routes/diagnostics/{health,unused_resources,cycle_deps,script_errors}.gd`
- Create: `tests/e2e/m5/test_diagnostics.py`

**Interfaces:**
- Findings are `{severity,code,message,path?,line?,details?}` sorted by severity/path/line/code.
- All routes accept `{roots?,offset?,limit?}`; health aggregates the other analyzers plus gdapi/router/runtime status.
- Diagnostics are read-only and return `ok:true` even when findings exist.

- [ ] **Step 1: Write exact intentional-finding tests**

```python
def test_fixture_diagnostics_are_exact(m5_editor):
    unused = exec_ok(m5_editor, "diagnostics/unused_resources", {"roots":["res://fixtures"]})
    assert [item["path"] for item in unused["items"]] == ["res://fixtures/unused.tres"]
    cycles = exec_ok(m5_editor, "diagnostics/cycle_deps", {"roots":["res://fixtures"]})
    assert cycles["items"][0]["cycle"] == [
        "res://fixtures/cycle_a.tres", "res://fixtures/cycle_b.tres", "res://fixtures/cycle_a.tres"
    ]
    errors = exec_ok(m5_editor, "diagnostics/script_errors", {"roots":["res://fixtures"]})
    assert errors["items"][0]["path"] == "res://fixtures/broken.gd"
    assert errors["items"][0]["line"] == 3
```

- [ ] **Step 2: Run diagnostics tests**

Run: `uv run pytest tests/e2e/m5/test_diagnostics.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement graph and parser analyzers**

Build a directed dependency graph from ResourceLoader dependencies, mark reachability from project main scene, autoloads, export filters, and `.tscn`/`.tres` references, then report unreferenced resources. Detect cycles with a recursion stack and canonicalize each cycle by rotating to its lexicographically smallest path. Validate GDScript in memory and extract parser line/column/message. Health includes Godot version, route count, filesystem scan state, runtime state, and finding counts.

- [ ] **Step 4: Verify findings, pagination, and read-only behavior**

Run: `uv run pytest tests/e2e/m5/test_diagnostics.py -v`

Expected: PASS and the project tree digest is unchanged.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/diagnostics.gd gdapi/addon/routes/diagnostics tests/e2e/m5/test_diagnostics.py
git commit -m "feat: add project diagnostics routes"
```

---

### Task 6: Add Export Preset Discovery and Controlled Export

**Files:**
- Create: `gdapi/addon/runtime/services/export_service.gd`
- Create: `gdapi/addon/routes/export/{presets,run}.gd`
- Create: `tests/e2e/m5/test_export.py`

**Interfaces:**
- `export/presets {}` returns name, platform, runnable, export path, and template availability.
- `export/run {preset,path,debug=false,force,timeout_ms=120000}` returns artifact path/size/hash and normalized export messages.
- Uses `ConfigFile` for `export_presets.cfg` and invokes only `OS.get_executable_path()` with fixed `--headless --path <project> --export-* <preset> <path>` argument shapes.

- [ ] **Step 1: Write preset, artifact, conflict, and missing-template tests**

```python
def test_minimal_pck_export(m5_editor):
    presets = exec_ok(m5_editor, "export/presets")["presets"]
    assert any(item["name"] == "M5 PCK" for item in presets)
    result = exec_ok(m5_editor, "export/run", {
        "preset":"M5 PCK", "path":"res://build/m5.pck", "force":True
    })
    artifact = m5_editor["project"] / "build" / "m5.pck"
    assert artifact.exists() and artifact.stat().st_size == result["size"]


def test_missing_template_is_explicit(m5_editor):
    error = exec_error(m5_editor, "export/run", {
        "preset":"Missing Template", "path":"res://build/missing.bin", "force":True
    })
    assert error["code"] == "not_supported"
    assert "platform" in error["details"]
```

- [ ] **Step 2: Run export tests**

Run: `uv run pytest tests/e2e/m5/test_export.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement export service with explicit template validation**

Load every `preset.N` section from `export_presets.cfg`, find the exact name, and reject duplicates. Select only one fixed flag from `--export-pack`, `--export-debug`, or `--export-release`; callers cannot provide flags. Start `OS.execute_with_pipe(OS.get_executable_path(), args, false)`, drain `stdio` and `stderr` with a combined 256 KiB cap, poll `OS.is_process_running(pid)`, kill on deadline, and read `OS.get_process_exit_code(pid)`. Map missing-template output to `not_supported`, other nonzero exits to `godot_error`, compute artifact SHA-256 through `FileAccess.get_sha256(path)`, and remove partial output on failure. Enforce destination PathGuard and overwrite force before starting the child.

- [ ] **Step 4: Verify success, missing environment, timeout, and cleanup**

Run: `uv run pytest tests/e2e/m5/test_export.py -v`

Expected: PASS; missing templates are asserted as errors, and failed export leaves no partial artifact.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/export_service.gd gdapi/addon/routes/export/presets.gd gdapi/addon/routes/export/run.gd tests/e2e/m5/test_export.py
git commit -m "feat: add controlled project export"
```

---

### Task 7: Add Explicit Single-Device Android Deploy

**Files:**
- Create: `gdapi/addon/runtime/services/android_bridge.gd`
- Create: `gdapi/addon/routes/export/android/{devices,deploy}.gd`
- Create: `tests/fixture_project/tests/test_android_bridge.gd`
- Create: `tests/e2e/m5/test_android_deploy.py`

**Interfaces:**
- `devices {}` returns `{devices:[{serial,state,model,product,transport_id}]}` from fixed `adb devices -l` parsing.
- `deploy {serial,apk_path,package,activity,force}` installs then launches exactly one validated APK.
- ADB path comes only from `EditorSettings.export/android/adb`; caller cannot supply executable or arguments.

- [ ] **Step 1: Write parser and safety tests**

```gdscript
func test_parse_adb_devices() -> void:
	var text := "List of devices attached\nemulator-5554 device product:sdk model:Pixel_8 transport_id:1\nABC unauthorized transport_id:2\n"
	var devices := AndroidBridge.parse_devices(text)
	assert_eq(devices[0], {"serial":"emulator-5554","state":"device","product":"sdk","model":"Pixel_8","transport_id":"1"})
	assert_eq(devices[1].state, "unauthorized")
```

```python
def test_deploy_requires_exact_online_device_and_force(m5_editor):
    error = exec_error(m5_editor, "export/android/deploy", {
        "serial":"emulator-5554", "apk_path":"res://build/app.apk",
        "package":"org.gdcli.fixture", "activity":"com.godot.game.GodotApp"
    })
    assert error["code"] == "unsafe_operation"
```

The positive test runs only when `ANDROID_TEST_SERIAL` is set; it must still assert the selected serial appears exactly once and is online.

- [ ] **Step 2: Run parser and contract tests**

Run: `uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/m5/test_android_deploy.py -v -k android`

Expected: FAIL because the bridge/routes are absent.

- [ ] **Step 3: Implement a fixed-command Android bridge**

Validate serial against `^[A-Za-z0-9._:-]+$`, package/activity against Android identifier patterns, and APK through PathGuard/read plus `.apk` extension. Invoke only these arrays:

```gdscript
["devices", "-l"]
["-s", serial, "install", "-r", ProjectSettings.globalize_path(apk_path)]
["-s", serial, "shell", "am", "start", "-n", package + "/" + activity]
```

Use a 60-second install timeout, cap combined output at 64 KiB, redact output before audit, and reject non-`device` states. Do not expose the bridge through `process/run`.

Run those arrays with `OS.execute_with_pipe(adb_path, args, false)`, drain both pipes without blocking, poll the returned PID, call `OS.kill(pid)` on deadline, and close both FileAccess handles on every completion path.

- [ ] **Step 4: Verify no-device and optional real-device paths**

Run: `uv run pytest tests/e2e/m5/test_android_deploy.py -v`

Expected: device listing and all negative contracts PASS everywhere; only the explicitly marked real-device positive test may skip when `ANDROID_TEST_SERIAL` is absent.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/android_bridge.gd gdapi/addon/routes/export/android tests/fixture_project/tests/test_android_bridge.gd tests/e2e/m5/test_android_deploy.py
git commit -m "feat: add confirmed Android device deploy"
```

---

### Task 8: Lock M5 Contracts and Full Verification

**Files:**
- Create: `tests/e2e/m5/test_m5_contract.py`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`

**Interfaces:**
- M5 manifest covers 4 settings, 5 input-map, 3 autoload, 6 ClassDB, 1 UID repair, 4 diagnostics, 2 export, and 2 Android routes.
- All external-environment failures are explicit except the opt-in real-device positive test.

- [ ] **Step 1: Add route/docs/audit/snapshot matrix**

```python
M5_ROUTES = {
    *{f"project/settings/{name}" for name in ["get","set","list","reset"]},
    *{f"project/input_map/{name}" for name in ["list","action/add","action/remove","bind","unbind"]},
    *{f"project/autoload/{name}" for name in ["list","add","remove"]},
    *{f"classdb/{name}" for name in ["classes","class","methods","properties","signals","inheriters"]},
    "uid/repair",
    *{f"diagnostics/{name}" for name in ["health","unused_resources","cycle_deps","script_errors"]},
    "export/presets", "export/run", "export/android/devices", "export/android/deploy",
}


def test_m5_routes_docs_and_clean_snapshot(m5_editor):
    routes = exec_ok(m5_editor, "gdapi/routes")["routes"]
    prefixes = ("project/settings/", "project/input_map/", "project/autoload/", "classdb/", "diagnostics/", "export/")
    selected = {route for route in routes if route.startswith(prefixes)}
    selected |= {route for route in routes if route == "uid/repair"}
    assert selected == M5_ROUTES
    for route in sorted(selected):
        doc = command_doc(m5_editor, route)
        assert doc["summary"] and doc["returns"]["fields"]
        if doc["params"]:
            assert doc["examples"]
    assert project_snapshot(m5_editor) == m5_editor["initial_snapshot"]
```

- [ ] **Step 2: Run the full M5 suite**

Run: `uv run pytest tests/e2e/m5 -v`

Expected: PASS, with at most one documented skip for the opt-in physical-device positive deployment.

- [ ] **Step 3: Document configuration, diagnostics, export, and Android safety**

Document snapshots, paging, finding schema, UID dry-run, export-template failures, fixed ADB command surface, serial confirmation, and audit redaction.

- [ ] **Step 4: Run repository verification**

Run:

```bash
cargo fmt --check
cargo clippy --workspace
cargo test --workspace
uv run pytest tests/e2e/ -v
git diff --check
```

Expected: all required commands exit 0 on Godot 4.7.x; only the declared physical-device positive test may skip.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/m5 README.md docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md
git commit -m "docs: complete M5 project diagnostics and export milestone"
```
