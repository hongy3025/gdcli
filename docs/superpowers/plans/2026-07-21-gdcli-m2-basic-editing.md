# gdcli M2 Basic Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a complete, undoable editor-authoring workflow for scenes, nodes, scripts, files, resources, signals, groups, selection, and editor navigation.

**Architecture:** Keep every public command as one filesystem-discovered route while moving reusable behavior into focused services under `runtime/services/`. Editor-state mutations use the M1 `GdApiEditAction`; file/resource mutations use `GdApiPathGuard`, explicit overwrite protection, `undoable:false`, and audit records. E2E tests operate on a copied fixture project so mutations never leak between tests.

**Tech Stack:** Godot 4.7.x GDScript editor APIs, gdcli generic HTTP exec transport, pytest/uv, M1 PathGuard/VariantCodec/EditAction/AuditLog contracts.

## Global Constraints

- Support only Godot 4.7.x and consume the completed M1 baseline before starting M2.
- Preserve existing `scene/create`, `scene/add_node`, `scene/save`, `scene/load_sprite`, and `scene/export_mesh_library` behavior.
- `scene/current/save` is the current editor scene operation; it must not change `scene/save` semantics.
- Every route accepts POST with a JSON object and publishes complete `doc()` metadata.
- Current-editor mutations return `changed` and `undoable:true`; file/resource mutations return `undoable:false`.
- Overwrite, delete, move-to-existing, and patch operations require `force:true` and audit success and failure.
- Decode incoming typed values with `GdApiVariantCodec.decode()` and encode property results with `from_variant()`.
- Use only the ten M1 standard error codes.
- Do not duplicate LSP rename, references, definition, declaration, symbols, hover, or diagnostics.
- All auxiliary scripts remain Python.

## File Structure

| File | Responsibility after M2 |
|---|---|
| `gdapi/addon/runtime/services/scene_editor.gd` | Resolve current/open scenes and serialize editor scene trees |
| `gdapi/addon/runtime/services/node_editor.gd` | Resolve NodePaths and perform UndoRedo node/property/signal/group mutations |
| `gdapi/addon/runtime/services/text_edit.gd` | Read, write, and apply bounded line patches |
| `gdapi/addon/runtime/services/resource_editor.gd` | Inspect, create, assign, move, delete, and reimport resources |
| `gdapi/addon/routes/scene/**/*.gd` | Current scene lifecycle and tree queries |
| `gdapi/addon/routes/node/**/*.gd` | Node, property, signal, and group API |
| `gdapi/addon/routes/script/**/*.gd` | Script file, attachment, editor navigation, and validation API |
| `gdapi/addon/routes/filesystem/**/*.gd` | Project-file listing, text IO, search, grep, and reimport API |
| `gdapi/addon/routes/resource/**/*.gd` | Resource metadata, dependency, search, mutation, and assignment API |
| `gdapi/addon/routes/editor/**/*.gd` | True editor UI state: selection and main screen |
| `tests/fixtures/m2_project/**` | Immutable authoring fixture copied for each E2E case |
| `tests/e2e/m2/conftest.py` | Isolated Godot editor lifecycle and route helpers |
| `tests/e2e/m2/test_*.py` | M2 contract and persistence acceptance tests |

---

### Task 1: Build an Isolated M2 Editor Harness

**Files:**
- Create: `tests/fixtures/m2_project/project.godot`
- Create: `tests/fixtures/m2_project/scenes/main.tscn`
- Create: `tests/fixtures/m2_project/scripts/player.gd`
- Create: `tests/fixtures/m2_project/scripts/broken.gd`
- Create: `tests/fixtures/m2_project/resources/player_data.tres`
- Create: `tests/fixtures/m2_project/addons/gdapi_test/plugin.cfg`
- Create: `tests/fixtures/m2_project/addons/gdapi_test/plugin.gd`
- Create: `tests/e2e/m2/conftest.py`
- Create: `tests/e2e/m2/test_fixture_isolation.py`

**Interfaces:**
- Produces: `m2_editor(tmp_path_factory) -> dict`, `exec_ok(env, route, data={}) -> dict`, `exec_error(env, route, data) -> dict`, `command_doc(env, route) -> dict`, `tree_digest(path) -> str`, `editor_undo(env)`, and `editor_redo(env)`.
- Produces fixture nodes `Main/Player`, `Main/Player/Child`, `Main/Target`, signal `Player.health_changed`, group `actors`, and resource `player_data.tres`.

- [ ] **Step 1: Write the isolation test**

```python
def test_fixture_is_a_private_copy(m2_editor):
    fixture = m2_editor["project"]
    source = m2_editor["root"] / "tests" / "fixtures" / "m2_project"
    assert fixture != source
    marker = fixture / "generated.txt"
    marker.write_text("private", encoding="utf-8")
    assert not (source / "generated.txt").exists()


def test_editor_starts_with_main_scene(m2_editor):
    result = exec_ok(m2_editor, "scene/current")
    assert result["path"] == "res://scenes/main.tscn"
```

- [ ] **Step 2: Run it and verify the missing fixture fails**

Run: `uv run pytest tests/e2e/m2/test_fixture_isolation.py -v`

Expected: ERROR because `m2_editor` is not defined.

- [ ] **Step 3: Add the immutable fixture and lifecycle**

Implement function-scoped `m2_editor` so every test receives a fresh project copy. Copy with:

```python
project = tmp_path_factory.mktemp("m2") / "project"
shutil.copytree(root / "tests" / "fixtures" / "m2_project", project)
install = subprocess.run(
    [str(gdcli), "install", "--project", str(project), "--force"],
    capture_output=True, text=True,
)
assert install.returncode == 0, install.stderr
godot = subprocess.Popen(
    [godot_bin, "--editor", "--headless", "--path", str(project),
     "--editor-pid", str(os.getpid())],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
)
```

Wait for `.godot/gdapi.json`, yield the project/token/port/binary map, then terminate the process and assert it exits. Implement `exec_error` by running `gdcli --json exec`, asserting a nonzero exit, and parsing stdout as JSON.

The fixture-only editor plugin polls `.godot/gdapi-test-command.json`; for `undo` or `redo` it resolves the edited root's history and invokes exactly one action, then atomically writes `.godot/gdapi-test-result.json`. `editor_undo`/`editor_redo` delete stale result, write `{"action":"undo"}` or `{"action":"redo"}`, wait up to two seconds, and assert `{"ok":true}`. The plugin is part of test fixtures only and never enters `gdapi/addon`.

```gdscript
@tool
extends EditorPlugin

const COMMAND := "res://.godot/gdapi-test-command.json"
const RESULT := "res://.godot/gdapi-test-result.json"
const RESULT_TEMP := "res://.godot/gdapi-test-result.tmp"

func _process(_delta: float) -> void:
	if not FileAccess.file_exists(COMMAND):
		return
	var body = JSON.parse_string(FileAccess.get_file_as_string(COMMAND))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(COMMAND))
	var root := EditorInterface.get_edited_scene_root()
	var ok := false
	if root != null and typeof(body) == TYPE_DICTIONARY:
		var manager := get_undo_redo()
		var history := manager.get_history_undo_redo(manager.get_object_history_id(root))
		ok = history.undo() if body.get("action") == "undo" else history.redo()
	var file := FileAccess.open(RESULT_TEMP, FileAccess.WRITE)
	file.store_string(JSON.stringify({"ok": ok}))
	file.close()
	if FileAccess.file_exists(RESULT):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RESULT))
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(RESULT_TEMP),
		ProjectSettings.globalize_path(RESULT)
	)
```

Implement the positional-only command documentation helper as:

```python
def command_doc(env: dict, route: str) -> dict:
    result = subprocess.run(
        [str(env["gdcli"]), "--json", "exec", "command/doc", route,
         "--project", str(env["project"])],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    return json.loads(result.stdout)["doc"]
```

- [ ] **Step 4: Verify isolated startup**

Run: `uv run pytest tests/e2e/m2/test_fixture_isolation.py -v`

Expected: 2 passed on Godot 4.7.x and no `generated.txt` in the source fixture.

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/m2_project tests/e2e/m2
git commit -m "test: add isolated M2 editor fixture"
```

---

### Task 2: Add Current Scene Lifecycle and Tree Queries

**Files:**
- Create: `gdapi/addon/runtime/services/scene_editor.gd`
- Create: `gdapi/addon/routes/scene/current.gd`
- Create: `gdapi/addon/routes/scene/current/save.gd`
- Create: `gdapi/addon/routes/scene/open.gd`
- Create: `gdapi/addon/routes/scene/close.gd`
- Create: `gdapi/addon/routes/scene/tree.gd`
- Create: `gdapi/addon/routes/scene/list_open.gd`
- Create: `tests/e2e/m2/test_scene_editor.py`

**Interfaces:**
- Produces: `GdApiSceneEditor.current_root() -> Node`, `resolve(path: String) -> Dictionary`, `describe_tree(root: Node, max_depth: int) -> Dictionary`.
- Route schemas: `scene/current {}`; `scene/open {path}`; `scene/current/save {path?,force?}`; `scene/close {path?}`; `scene/tree {path?,max_depth?}`; `scene/list_open {}`.

- [ ] **Step 1: Write lifecycle and exact-tree tests**

```python
def test_scene_lifecycle_and_tree(m2_editor):
    current = exec_ok(m2_editor, "scene/current")
    assert current == {"ok": True, "path": "res://scenes/main.tscn", "edited": False}
    tree = exec_ok(m2_editor, "scene/tree", {"max_depth": 4})
    assert tree["root"]["name"] == "Main"
    assert [(n["name"], n["type"]) for n in tree["root"]["children"]] == [
        ("Player", "Node2D"), ("Target", "Node2D")
    ]
    opened = exec_ok(m2_editor, "scene/list_open")
    assert "res://scenes/main.tscn" in opened["paths"]


def test_open_rejects_missing_scene_without_state_change(m2_editor):
    before = exec_ok(m2_editor, "scene/current")
    error = exec_error(m2_editor, "scene/open", {"path": "res://missing.tscn"})
    assert error["code"] == "not_found"
    assert exec_ok(m2_editor, "scene/current") == before
```

- [ ] **Step 2: Run tests and observe route-not-found failures**

Run: `uv run pytest tests/e2e/m2/test_scene_editor.py -v`

Expected: FAIL with `not_found` for the six new routes.

- [ ] **Step 3: Implement the scene service and route adapters**

Use this recursive representation:

```gdscript
static func describe_tree(node: Node, max_depth: int, depth: int = 0) -> Dictionary:
	var item := {
		"name": node.name,
		"path": str(node.get_path()),
		"type": node.get_class(),
		"scene_file_path": node.scene_file_path,
		"children": [],
	}
	if depth < max_depth:
		for child in node.get_children():
			item.children.append(describe_tree(child, max_depth, depth + 1))
	return item
```

`scene/open` validates with PathGuard/read and calls `EditorInterface.open_scene_from_path`. `scene/current/save` calls `EditorInterface.save_scene()` or `save_scene_as(path)` and requires force when the destination already exists. `scene/close` calls `EditorInterface.close_scene()` for the requested or current scene. Every response includes `changed`, `undoable:false`, and the affected path.

- [ ] **Step 4: Verify lifecycle, docs, and persistence**

Run: `uv run pytest tests/e2e/m2/test_scene_editor.py tests/e2e/test_m1_contracts.py -v`

Expected: PASS; `command/doc scene/current/save` documents `path`, `force`, `changed`, `saved`, and `undoable`.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/scene_editor.gd gdapi/addon/routes/scene tests/e2e/m2/test_scene_editor.py
git commit -m "feat: add current scene lifecycle routes"
```

---

### Task 3: Add Undoable Node and Property Editing

**Files:**
- Create: `gdapi/addon/runtime/services/node_editor.gd`
- Create: `gdapi/addon/routes/node/{create,delete,duplicate,rename,reparent,move,get,set,list,select}.gd`
- Create: `gdapi/addon/routes/node/property/{get,set,list,reset,revert}.gd`
- Create: `tests/e2e/m2/test_node_editor.py`

**Interfaces:**
- Produces: `GdApiNodeEditor.find(root: Node, path: String) -> Dictionary` and mutation methods returning `{ok,changed,undoable,node_path}`.
- Produces property routes `node/property/get`, `node/property/set`, `node/property/list`, `node/property/reset`, and `node/property/revert`.
- Node identity is an absolute scene-root NodePath such as `/root/Main/Player`; mutation bodies use `node_path` and `parent_path`.
- Property set body is `{node_path, property, value}` where `value` is VariantCodec JSON.

- [ ] **Step 1: Write a single ordered undo/redo acceptance test**

```python
def test_node_mutations_are_stepwise_undoable(m2_editor):
    created = exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Sprite2D", "name": "Icon"
    })
    assert created["undoable"] is True
    renamed = exec_ok(m2_editor, "node/rename", {
        "node_path": "/root/Main/Icon", "name": "Avatar"
    })
    assert renamed["node_path"] == "/root/Main/Avatar"
    value = {"type": "Vector2", "value": [24, 32]}
    assert exec_ok(m2_editor, "node/property/set", {
        "node_path": "/root/Main/Avatar", "property": "position", "value": value
    })["undoable"] is True
    prop = exec_ok(m2_editor, "node/property/get", {
        "node_path": "/root/Main/Avatar", "property": "position"
    })
    assert prop["value"] == {"type": "Vector2", "value": [24.0, 32.0]}
```

After the create/rename/property sequence, prove each history step through the fixture-only command channel:

```python
    editor_undo(m2_editor)
    assert exec_ok(m2_editor, "node/property/get", {
        "node_path":"/root/Main/Avatar","property":"position"
    })["value"] == {"type":"Vector2","value":[0.0,0.0]}
    editor_undo(m2_editor)
    assert exec_ok(m2_editor, "node/get", {"node_path":"/root/Main/Icon"})["name"] == "Icon"
    editor_undo(m2_editor)
    assert exec_error(m2_editor, "node/get", {"node_path":"/root/Main/Icon"})["code"] == "not_found"
    editor_redo(m2_editor)
    editor_redo(m2_editor)
    editor_redo(m2_editor)
    assert exec_ok(m2_editor, "node/get", {"node_path":"/root/Main/Avatar"})["name"] == "Avatar"
```

Add this rejection matrix:

```python
@pytest.mark.parametrize("route,data,code", [
    ("node/get", {"node_path":"/root/Main/Missing"}, "not_found"),
    ("node/create", {"parent_path":"/root/Main","type":"MissingClass","name":"Bad"}, "invalid_param"),
    ("node/delete", {"node_path":"/root/Main"}, "permission_denied"),
    ("node/reparent", {"node_path":"/root/Main/Player","parent_path":"/root/Main/Player/Child"}, "conflict"),
    ("node/property/set", {"node_path":"/root/Main/Player","property":"script/source_code","value":"x"}, "permission_denied"),
    ("node/property/set", {"node_path":"/root/Main/Player","property":"position","value":{"type":"Vector2","value":[1]}}, "invalid_param"),
])
def test_node_rejections_are_atomic(m2_editor, route, data, code):
    before = exec_ok(m2_editor, "scene/tree")
    assert exec_error(m2_editor, route, data)["code"] == code
    assert exec_ok(m2_editor, "scene/tree") == before
```

- [ ] **Step 2: Run the focused tests**

Run: `uv run pytest tests/e2e/m2/test_node_editor.py -v`

Expected: FAIL because `node/create` and property routes are absent.

- [ ] **Step 3: Implement one mutation service used by all node routes**

The service commits ownership-aware node creation with:

```gdscript
static func create_node(parent: Node, node: Node, name: String) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	var undo := GdApiEditAction.undo_redo()
	undo.create_action("gdcli: create node")
	undo.add_do_method(parent, "add_child", node, true)
	undo.add_do_property(node, "name", name)
	undo.add_do_property(node, "owner", root)
	undo.add_undo_method(parent, "remove_child", node)
	undo.add_do_reference(node)
	undo.commit_action()
	return {"ok": true, "changed": true, "undoable": true}
```

Use matching do/undo methods for delete, duplicate, reparent, and move. Use M1 `commit_property` for rename and property set/reset/revert. Query routes never create an UndoRedo action. `node/set` accepts a `properties` dictionary and rejects the entire request before mutation if any decoded property is invalid.

- [ ] **Step 4: Run node, codec, and restart persistence tests**

Run: `uv run pytest tests/e2e/m2/test_node_editor.py tests/e2e/test_m1_scene_safety.py -v`

Expected: PASS, including typed Vector2, Color, NodePath, and Resource round trips and save/reopen verification.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/node_editor.gd gdapi/addon/routes/node tests/e2e/m2/test_node_editor.py tests/fixture_project/addons/gdapi_test
git commit -m "feat: add undoable node and property editing"
```

---

### Task 4: Add Selection and Main-Screen Control

**Files:**
- Create: `gdapi/addon/routes/editor/selection/get.gd`
- Create: `gdapi/addon/routes/editor/selection/set.gd`
- Create: `gdapi/addon/routes/editor/main_screen/set.gd`
- Create: `tests/e2e/m2/test_editor_ui.py`

**Interfaces:**
- `editor/selection/set` consumes `{node_paths:Array[String], clear:bool=true}`.
- `editor/main_screen/set` consumes `{screen:String}` with allowlist `2D`, `3D`, `Script`, `AssetLib`.
- `node/select` remains a single-node convenience route implemented through the same selection service.

- [ ] **Step 1: Write UI state tests**

```python
def test_selection_round_trip(m2_editor):
    result = exec_ok(m2_editor, "editor/selection/set", {
        "node_paths": ["/root/Main/Player", "/root/Main/Target"]
    })
    assert result["changed"] is True and result["undoable"] is False
    assert exec_ok(m2_editor, "editor/selection/get")["node_paths"] == [
        "/root/Main/Player", "/root/Main/Target"
    ]


def test_main_screen_allowlist(m2_editor):
    assert exec_ok(m2_editor, "editor/main_screen/set", {"screen": "Script"})["screen"] == "Script"
    assert exec_error(m2_editor, "editor/main_screen/set", {"screen": "Debugger"})["code"] == "invalid_param"
```

- [ ] **Step 2: Run and confirm route failures**

Run: `uv run pytest tests/e2e/m2/test_editor_ui.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement through Godot editor interfaces**

Resolve all paths before clearing the selection, then use `EditorInterface.get_selection().clear()` and `add_node(node)`. Switch main screens only through `EditorInterface.set_main_screen_editor(screen)`. Return `changed`, `undoable:false`, and final state; do not audit read-only selection queries.

- [ ] **Step 4: Verify state and error atomicity**

Run: `uv run pytest tests/e2e/m2/test_editor_ui.py -v`

Expected: PASS; an invalid path leaves the previous selection unchanged.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/routes/editor gdapi/addon/routes/node/select.gd tests/e2e/m2/test_editor_ui.py
git commit -m "feat: add editor selection and screen routes"
```

---

### Task 5: Add Safe Script and Text Editing

**Files:**
- Create: `gdapi/addon/runtime/services/text_edit.gd`
- Create: `gdapi/addon/routes/script/{read,create,write,patch,attach,detach,current,open,validate}.gd`
- Create: `tests/e2e/m2/test_script_routes.py`

**Interfaces:**
- `script/patch` consumes `{path,start_line,end_line,text,force}` with 1-based inclusive line numbers.
- `script/validate` returns `{ok,valid,errors:Array[{line,column,message}]}` and does not mutate files.
- Attach/detach consume `{node_path,path?}` and use UndoRedo; create/write/patch are audited and non-undoable.

- [ ] **Step 1: Write creation, patch, validation, and attachment tests**

```python
def test_script_authoring_and_attachment(m2_editor):
    path = "res://scripts/generated.gd"
    source = "extends Node2D\nvar speed := 10\n"
    assert exec_ok(m2_editor, "script/create", {"path": path, "content": source})["written"]
    denied = exec_error(m2_editor, "script/patch", {
        "path": path, "start_line": 2, "end_line": 2, "text": "var speed := 20"
    })
    assert denied["code"] == "unsafe_operation"
    exec_ok(m2_editor, "script/patch", {
        "path": path, "start_line": 2, "end_line": 2,
        "text": "var speed := 20", "force": True
    })
    assert exec_ok(m2_editor, "script/validate", {"path": path})["valid"] is True
    attached = exec_ok(m2_editor, "script/attach", {
        "node_path": "/root/Main/Player", "path": path
    })
    assert attached["undoable"] is True
```

Add exact script rejection cases:

```python
@pytest.mark.parametrize("route,data,code", [
    ("script/patch", {"path":"res://scripts/player.gd","start_line":99,"end_line":99,"text":"x","force":True}, "invalid_param"),
    ("script/write", {"path":"res://addons/gdapi/plugin.gd","content":"x","force":True}, "permission_denied"),
    ("script/write", {"path":"res://scripts/player.gd","content":"x"}, "unsafe_operation"),
    ("script/attach", {"node_path":"/root/Main/Missing","path":"res://scripts/player.gd"}, "not_found"),
])
def test_script_rejections_do_not_change_files(m2_editor, route, data, code):
    before = tree_digest(m2_editor["project"])
    assert exec_error(m2_editor, route, data)["code"] == code
    assert tree_digest(m2_editor["project"]) == before


def test_invalid_script_is_a_successful_validation_result(m2_editor):
    result = exec_ok(m2_editor, "script/validate", {"path":"res://scripts/broken.gd"})
    assert result["valid"] is False and result["errors"]
```

- [ ] **Step 2: Run the focused test**

Run: `uv run pytest tests/e2e/m2/test_script_routes.py -v`

Expected: FAIL because the script routes are absent.

- [ ] **Step 3: Implement bounded text edits and Godot validation**

Implement the patch primitive exactly as an all-or-nothing edit:

```gdscript
static func replace_lines(source: String, first: int, last: int, text: String) -> Dictionary:
	var lines := source.split("\n", true)
	if first < 1 or last < first or last > lines.size():
		return {"ok": false, "code": "invalid_param", "error": "line range is outside the file"}
	var replacement := text.split("\n", true)
	lines = lines.slice(0, first - 1) + replacement + lines.slice(last)
	return {"ok": true, "text": "\n".join(lines)}
```

Validate with `GDScript.new()`, set `source_code`, and call `reload()`, mapping parser failure to `valid:false` rather than an HTTP failure. Open scripts with `EditorInterface.edit_script(script, line - 1, column - 1)` after validating 1-based coordinates.

- [ ] **Step 4: Verify script routes and audit entries**

Run: `uv run pytest tests/e2e/m2/test_script_routes.py -v`

Expected: PASS; failed patch/overwrite leaves bytes unchanged and audit uses the exact public route.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/text_edit.gd gdapi/addon/routes/script tests/e2e/m2/test_script_routes.py
git commit -m "feat: add safe script authoring routes"
```

---

### Task 6: Add Project Filesystem Operations

**Files:**
- Create: `gdapi/addon/routes/filesystem/{list,read,write,search,grep,reimport}.gd`
- Create: `tests/e2e/m2/test_filesystem_routes.py`

**Interfaces:**
- Produces routes `filesystem/list`, `filesystem/read`, `filesystem/write`, `filesystem/search`, `filesystem/grep`, and `filesystem/reimport`.
- List/search responses are sorted and paginated with `{items,total,offset,limit}`.
- `filesystem/grep` consumes `{root,pattern,glob?,case_sensitive?,offset?,limit?}` and returns 1-based line/column matches.
- `filesystem/write` consumes `{path,content,force?}`; reimport consumes `{paths:Array[String]}`.

- [ ] **Step 1: Write deterministic query and safety tests**

```python
def test_filesystem_query_contract(m2_editor):
    listing = exec_ok(m2_editor, "filesystem/list", {"path": "res://scripts"})
    assert listing["items"] == sorted(listing["items"], key=lambda item: item["path"])
    grep = exec_ok(m2_editor, "filesystem/grep", {
        "root": "res://scripts", "pattern": "speed", "glob": "*.gd"
    })
    assert grep["items"][0]["line"] == 2


def test_filesystem_write_requires_force(m2_editor):
    path = "res://scripts/player.gd"
    before = exec_ok(m2_editor, "filesystem/read", {"path": path})["content"]
    error = exec_error(m2_editor, "filesystem/write", {"path": path, "content": "broken"})
    assert error["code"] == "unsafe_operation"
    assert exec_ok(m2_editor, "filesystem/read", {"path": path})["content"] == before
```

- [ ] **Step 2: Run and verify absent-route failures**

Run: `uv run pytest tests/e2e/m2/test_filesystem_routes.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement PathGuard-backed, bounded operations**

Cap `limit` at 500, file reads at 4 MiB, grep matches at 10,000 before pagination, and roots to `res://` or `user://`. Write through a sibling temporary file and rename only after all validation succeeds. Reimport via `EditorInterface.get_resource_filesystem().reimport_files(paths)` and return `{reimported:paths,changed:true,undoable:false}`.

- [ ] **Step 4: Verify queries, bounds, and atomic failure**

Run: `uv run pytest tests/e2e/m2/test_filesystem_routes.py -v`

Expected: PASS, including traversal, absolute-path, protected-addon, binary-read, excessive-limit, and overwrite negatives.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/routes/filesystem tests/e2e/m2/test_filesystem_routes.py
git commit -m "feat: add bounded filesystem routes"
```

---

### Task 7: Add Resource Inspection and Mutation

**Files:**
- Create: `gdapi/addon/runtime/services/resource_editor.gd`
- Create: `gdapi/addon/routes/resource/{info,deps,search,reimport,assign,create,delete,move}.gd`
- Create: `tests/e2e/m2/test_resource_routes.py`

**Interfaces:**
- `resource/info {path}` returns class, UID, path, local-to-scene flag, and encoded stored properties.
- `resource/create {path,type,properties,force?}` supports instantiable Resource subclasses.
- `resource/assign {node_path,property,path}` is undoable editor state; create/delete/move/reimport are non-undoable audited mutations.

- [ ] **Step 1: Write resource round-trip and protection tests**

```python
def test_resource_create_assign_move_delete(m2_editor):
    created = exec_ok(m2_editor, "resource/create", {
        "path": "res://resources/generated.tres", "type": "Resource",
        "properties": {"resource_name": "Generated"}
    })
    assert created["saved"] and created["undoable"] is False
    assigned = exec_ok(m2_editor, "resource/assign", {
        "node_path": "/root/Main/Player", "property": "texture",
        "path": "res://icon.svg"
    })
    assert assigned["undoable"] is True
    moved = exec_ok(m2_editor, "resource/move", {
        "from": "res://resources/generated.tres",
        "to": "res://resources/moved.tres", "force": True
    })
    assert moved["moved"] is True
    assert exec_error(m2_editor, "resource/delete", {
        "path": "res://resources/moved.tres"
    })["code"] == "unsafe_operation"
```

Add these exact resource assertions:

```python
def test_resource_queries_and_rejections(m2_editor):
    info = exec_ok(m2_editor, "resource/info", {"path":"res://resources/player_data.tres"})
    assert info["uid"] and info["class"] == "Resource"
    deps = exec_ok(m2_editor, "resource/deps", {"path":"res://scenes/main.tscn"})
    assert deps["items"] == sorted(deps["items"])
    page = exec_ok(m2_editor, "resource/search", {"filter":"player","offset":0,"limit":1})
    assert len(page["items"]) == 1 and page["total"] >= 1
    assert exec_error(m2_editor, "resource/assign", {
        "node_path":"/root/Main/Player","property":"position","path":"res://icon.svg"
    })["code"] == "invalid_param"
    assert exec_error(m2_editor, "resource/move", {
        "from":"res://resources/player_data.tres","to":"res://icon.svg","force":True
    })["code"] == "conflict"
    assert exec_error(m2_editor, "resource/delete", {
        "path":"res://resources/player_data.tres"
    })["code"] == "unsafe_operation"
```

- [ ] **Step 2: Run focused tests**

Run: `uv run pytest tests/e2e/m2/test_resource_routes.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement resource operations**

Use `ResourceLoader.get_dependencies(path)`, `ResourceUID.path_to_uid(path)`, and the editor filesystem for queries. Instantiate only `ClassDB.is_parent_class(type, "Resource")` classes. Apply properties only after `get_property_list()` validation and VariantCodec decoding. Use `EditorInterface.get_resource_filesystem().move_file` for moves so imports and references update; reject delete when dependency search finds inbound references unless `force:true`.

- [ ] **Step 4: Verify saved state after editor restart**

Run: `uv run pytest tests/e2e/m2/test_resource_routes.py -v`

Expected: PASS; reopen shows the assigned typed resource and no failed mutation changed files.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/resource_editor.gd gdapi/addon/routes/resource tests/e2e/m2/test_resource_routes.py
git commit -m "feat: add resource inspection and mutation routes"
```

---

### Task 8: Add Persistent Signal and Group Editing

**Files:**
- Create: `gdapi/addon/routes/node/signal/{list,connect,disconnect,emit}.gd`
- Create: `gdapi/addon/routes/node/group/{list,add,remove,nodes}.gd`
- Create: `tests/e2e/m2/test_signal_group_routes.py`

**Interfaces:**
- Signal connection bodies use `{source_path,signal,target_path,method,flags?}`.
- Group mutation bodies use `{node_path,group,persistent:true}`; only persistent groups satisfy save/reopen acceptance.
- Connect/disconnect and group add/remove use UndoRedo; editor-time signal emit is non-undoable.

- [ ] **Step 1: Write persistence and duplicate-safety tests**

```python
def test_signal_and_group_persist(m2_editor):
    connection = {
        "source_path": "/root/Main/Player", "signal": "health_changed",
        "target_path": "/root/Main/Target", "method": "_on_health_changed"
    }
    assert exec_ok(m2_editor, "node/signal/connect", connection)["undoable"] is True
    assert exec_ok(m2_editor, "node/group/add", {
        "node_path": "/root/Main/Target", "group": "actors", "persistent": True
    })["undoable"] is True
    exec_ok(m2_editor, "scene/current/save")
    assert connection in exec_ok(m2_editor, "node/signal/list", {
        "node_path": "/root/Main/Player"
    })["connections"]
    assert "/root/Main/Target" in exec_ok(m2_editor, "node/group/nodes", {
        "group": "actors"
    })["node_paths"]
```

Add the rejection matrix:

```python
@pytest.mark.parametrize("route,data,code", [
    ("node/signal/connect", {"source_path":"/root/Main/Player","signal":"health_changed","target_path":"/root/Main/Target","method":"missing"}, "not_found"),
    ("node/signal/connect", {"source_path":"/root/Main/Player","signal":"missing","target_path":"/root/Main/Target","method":"_on_health_changed"}, "not_found"),
    ("node/signal/disconnect", {"source_path":"/root/Main/Player","signal":"health_changed","target_path":"/root/Main/Target","method":"missing"}, "not_found"),
    ("node/group/add", {"node_path":"/root/Main/Target","group":"","persistent":True}, "invalid_param"),
])
def test_signal_group_rejections(m2_editor, route, data, code):
    assert exec_error(m2_editor, route, data)["code"] == code


def test_duplicate_signal_and_group_are_conflicts(m2_editor):
    connection = {"source_path":"/root/Main/Player","signal":"health_changed","target_path":"/root/Main/Target","method":"_on_health_changed"}
    exec_ok(m2_editor, "node/signal/connect", connection)
    assert exec_error(m2_editor, "node/signal/connect", connection)["code"] == "conflict"
    group = {"node_path":"/root/Main/Target","group":"actors","persistent":True}
    exec_ok(m2_editor, "node/group/add", group)
    assert exec_error(m2_editor, "node/group/add", group)["code"] == "conflict"
```

- [ ] **Step 2: Run tests and confirm missing routes**

Run: `uv run pytest tests/e2e/m2/test_signal_group_routes.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement validated UndoRedo operations**

Resolve source and target before creating an action. Use `CONNECT_PERSIST` for stored connections and `Node.add_to_group(group, persistent)`. The undo side must call the exact inverse operation with the same callable or group. Sort query results by signal/group/path.

- [ ] **Step 4: Verify undo, save, close, and reopen**

Run: `uv run pytest tests/e2e/m2/test_signal_group_routes.py -v`

Expected: PASS across undo/redo and save/reopen; duplicate requests return `conflict` without a new undo action.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/routes/node/signal gdapi/addon/routes/node/group tests/e2e/m2/test_signal_group_routes.py
git commit -m "feat: add signal and group editing routes"
```

---

### Task 9: Lock M2 Route Inventory and Full Acceptance

**Files:**
- Create: `tests/e2e/m2/test_m2_contract.py`
- Modify: `tests/e2e/test_m1_smoke.py`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`

**Interfaces:**
- Produces a sorted M2 route manifest in the test, not a runtime alias registry.
- Converts the M1 exact-current inventory into a permanent baseline-subset assertion while retaining explicit retired-alias rejection.
- M2 completion requires all route docs, error codes, mutation fields, audit records, isolation, and persistence checks.

- [ ] **Step 1: Add the exact route and documentation contract test**

First update the historical M1 test so later milestones do not invalidate it:

```python
M1_BASELINE_ROUTES = {
    "command/doc", "command/list", "console/output",
    "gdapi/audit/clear", "gdapi/audit/list", "gdapi/health/pathcheck",
    "gdapi/health/ping", "gdapi/loglevel", "gdapi/routes", "godot/version",
    "project/info", "project/run", "project/stop",
    "scene/add_node", "scene/create", "scene/export_mesh_library",
    "scene/load_sprite", "scene/save", "uid/get", "uid/update_all",
}
RETIRED_ROUTES = {"routes", "commands", "help", "command-help", "gdapi/commands", "gdapi/help"}

# Replace the old equality assertion in test_route_inventory_and_command_metadata:
actual = set(resp["routes"])
assert M1_BASELINE_ROUTES <= actual
assert RETIRED_ROUTES.isdisjoint(actual)

# Replace the old command/list equality assertion as well:
commands = _exec(godot_env, "command/list")
command_paths = {item["path"] for item in commands["commands"]}
assert M1_BASELINE_ROUTES <= command_paths
assert RETIRED_ROUTES.isdisjoint(command_paths)
```

```python
M2_ROUTES = {
    *{f"scene/{name}" for name in [
        "create", "add_node", "save", "load_sprite", "export_mesh_library",
        "current", "current/save", "open", "close", "tree", "list_open",
    ]},
    *{f"node/{name}" for name in [
        "create", "delete", "duplicate", "rename", "reparent", "move", "get", "set", "list", "select",
        "property/get", "property/set", "property/list", "property/reset", "property/revert",
        "signal/list", "signal/connect", "signal/disconnect", "signal/emit",
        "group/list", "group/add", "group/remove", "group/nodes",
    ]},
    *{f"script/{name}" for name in ["read","create","write","patch","attach","detach","current","open","validate"]},
    *{f"filesystem/{name}" for name in ["list","read","write","search","grep","reimport"]},
    *{f"resource/{name}" for name in ["info","deps","search","reimport","assign","create","delete","move"]},
    "editor/selection/get", "editor/selection/set", "editor/main_screen/set",
}


def test_m2_route_families_and_docs(m2_editor):
    routes = exec_ok(m2_editor, "gdapi/routes")["routes"]
    prefixes = ("scene/", "node/", "script/", "filesystem/", "resource/", "editor/")
    selected = {route for route in routes if route.startswith(prefixes)}
    assert selected == M2_ROUTES
    for route in sorted(selected):
        doc = command_doc(m2_editor, route)
        assert doc["summary"] and doc["returns"]["fields"]
```

- [ ] **Step 2: Run the full M2 suite**

Run: `uv run pytest tests/e2e/m2 -v`

Expected: PASS with no source fixture changes and no leaked Godot process.

- [ ] **Step 3: Update user-facing command families and milestone status**

Document the new natural route families, typed Variant JSON examples, force/UndoRedo rules, and the boundary that LSP remains responsible for code intelligence. Mark M2 complete only after the command in Step 4 passes.

- [ ] **Step 4: Run repository verification**

Run:

```bash
cargo fmt --check
cargo clippy --workspace
cargo test --workspace
uv run pytest tests/e2e/ -v
git diff --check
```

Expected: all commands exit 0 on Godot 4.7.x; the isolated test directories are removed by pytest cleanup.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/test_m1_smoke.py tests/e2e/m2 README.md docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md
git commit -m "docs: complete M2 basic editing milestone"
```
