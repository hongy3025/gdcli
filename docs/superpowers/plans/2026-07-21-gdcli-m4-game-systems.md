# gdcli M4 Game Systems Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add typed authoring and verification routes for Godot's core animation, tile, rendering, audio, UI, physics, and navigation systems.

**Architecture:** Each game-system domain gets a focused service and natural route family. Services reuse M2 node/resource editing and M3 runtime assertions; editor-scene mutations use UndoRedo while saved resource and project-bus mutations use force protection, audit, and `undoable:false`. Every domain has an immutable fixture asset and verifies state after save/reopen, not merely the HTTP response.

**Tech Stack:** Godot 4.7 Animation/TileMapLayer/Rendering/Audio/UI/Physics/Navigation APIs, M1–M3 shared contracts, pytest/uv.

## Global Constraints

- Support only Godot 4.7.x and require completed M1–M3 plans.
- Use `TileMapLayer` as the Godot 4.7 tile-editing primitive; the public route family remains `tilemap/**`.
- Use VariantCodec for every typed value and return `invalid_param` before mutation on type mismatch.
- Scene-node mutations are UndoRedo actions; resource files, shader files, bus layouts, baking, and saved assets are non-undoable.
- Existing destinations require `force:true`; destructive operations always require `force:true`.
- Every domain query returns stable sorted arrays and resource paths rather than opaque Object IDs.
- Runtime play/path/raycast verification uses M3 routes and never adds a second transport.
- Each domain fixture is copied per test and leaves no imported/generated asset in the source tree.

## File Structure

| File | Responsibility after M4 |
|---|---|
| `gdapi/addon/runtime/services/animation_editor.gd` | AnimationLibrary, tracks, keys, and AnimationTree editing |
| `gdapi/addon/runtime/services/tilemap_editor.gd` | TileMapLayer cells, rectangles, and TileSet inspection |
| `gdapi/addon/runtime/services/rendering_editor.gd` | Materials, shaders, uniforms, assignment, and persistence |
| `gdapi/addon/runtime/services/audio_editor.gd` | Audio buses and AudioStreamPlayer nodes |
| `gdapi/addon/runtime/services/ui_editor.gd` | Control layout and declarative UI tree construction |
| `gdapi/addon/runtime/services/physics_editor.gd` | Bodies, shapes, layers, raycasts, and joints |
| `gdapi/addon/runtime/services/navigation_editor.gd` | Regions, baking, paths, and agent targets |
| `gdapi/addon/routes/{animation,animation_tree,tilemap,material,shader,audio,ui,theme,physics,navigation}/**` | Public game-system routes |
| `tests/fixtures/m4_project/**` | One independent scene/resource set per domain |
| `tests/e2e/m4/**` | Domain persistence, typing, safety, and runtime verification |

---

### Task 1: Build Domain-Isolated M4 Fixtures and Shared Assertions

**Files:**
- Create: `tests/fixtures/m4_project/project.godot`
- Create: `tests/fixtures/m4_project/scenes/{animation,tilemap,rendering,audio,ui,physics,navigation}.tscn`
- Create: `tests/fixtures/m4_project/resources/**`
- Create: `tests/fixtures/m4_project/tests/domain_probe.gd`
- Create: `tests/fixtures/m4_project/addons/gdapi_test/plugin.cfg`
- Create: `tests/fixtures/m4_project/addons/gdapi_test/plugin.gd`
- Create: `tests/e2e/m4/conftest.py`
- Create: `tests/e2e/m4/test_fixture_domains.py`

**Interfaces:**
- Produces `m4_editor`, `open_domain(env,name)`, `save_reopen(env)`, `runtime_assert(env,condition)`, `fixture_probe(env,operation,data)`, `animation_snapshot(env,name)`, `editor_undo(env)`, `editor_redo(env)`, and `resource_digest(project,path)`.
- Domain scenes have roots named `AnimationFixture`, `TileFixture`, `RenderingFixture`, `AudioFixture`, `UiFixture`, `PhysicsFixture`, and `NavigationFixture`.

- [ ] **Step 1: Write fixture independence tests**

```python
@pytest.mark.parametrize("domain", [
    "animation", "tilemap", "rendering", "audio", "ui", "physics", "navigation"
])
def test_domain_scene_opens_without_import_errors(m4_editor, domain):
    opened = open_domain(m4_editor, domain)
    assert opened["path"] == f"res://scenes/{domain}.tscn"
    assert exec_ok(m4_editor, "scene/tree")["root"]["name"].endswith("Fixture")


def test_each_test_uses_private_project(m4_editor):
    assert m4_editor["project"] != m4_editor["source_fixture"]
```

- [ ] **Step 2: Run and observe missing fixture errors**

Run: `uv run pytest tests/e2e/m4/test_fixture_domains.py -v`

Expected: ERROR because the M4 fixture and helpers do not exist.

- [ ] **Step 3: Create minimal valid assets and reuse the M2 harness**

Copy the M2 lifecycle and fixture-only undo/redo command plugin, point them at `m4_project`, and create domain scenes using text `.tscn`/`.tres` files that Godot 4.7 imports without warnings. Extend the fixture command plugin with action `probe`; it calls `domain_probe.gd` in the running editor and writes the encoded result through the same atomic result file. `save_reopen` saves, closes, opens the same path, and waits until `scene/current.path` matches. `fixture_probe` submits `{action:"probe",operation,data}` and parses the result; `animation_snapshot` calls its `animation_snapshot` operation.

- [ ] **Step 4: Verify all fixture domains**

Run: `uv run pytest tests/e2e/m4/test_fixture_domains.py -v`

Expected: 8 passed and source fixture digests unchanged.

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/m4_project tests/e2e/m4
git commit -m "test: add isolated M4 game-system fixtures"
```

---

### Task 2: Add Animation and AnimationTree Authoring

**Files:**
- Create: `gdapi/addon/runtime/services/animation_editor.gd`
- Create: `gdapi/addon/routes/animation/{create,delete,play,stop}.gd`
- Create: `gdapi/addon/routes/animation/track/{add,remove}.gd`
- Create: `gdapi/addon/routes/animation/key/{add,remove}.gd`
- Create: `gdapi/addon/routes/animation_tree/state/add.gd`
- Create: `gdapi/addon/routes/animation_tree/transition/add.gd`
- Create: `gdapi/addon/routes/animation_tree/blend/set.gd`
- Create: `tests/e2e/m4/test_animation.py`

**Interfaces:**
- Animation bodies identify `{player_path,library,animation}`; tracks add `{type,path,index?}` and keys add `{track,time,value,transition?}`.
- AnimationTree state/transition routes identify `{tree_path,state_machine_path}` and resource-backed nodes.
- Create/delete/track/key/state/transition/blend are undoable scene mutations; play/stop are non-undoable editor preview state.

- [ ] **Step 1: Write typed track/key and persistence test**

```python
def test_animation_track_key_round_trip(m4_editor):
    open_domain(m4_editor, "animation")
    exec_ok(m4_editor, "animation/create", {
        "player_path": "/root/AnimationFixture/AnimationPlayer",
        "library": "", "animation": "move", "length": 1.0
    })
    track = exec_ok(m4_editor, "animation/track/add", {
        "player_path": "/root/AnimationFixture/AnimationPlayer", "animation": "move",
        "type": "value", "path": "Sprite2D:position"
    })
    exec_ok(m4_editor, "animation/key/add", {
        "player_path": "/root/AnimationFixture/AnimationPlayer", "animation": "move",
        "track": track["track"], "time": 0.5,
        "value": {"type": "Vector2", "value": [40, 20]}
    })
    save_reopen(m4_editor)
    info = animation_snapshot(m4_editor, "move")
    assert info["tracks"][0]["keys"][0]["value"] == {"type":"Vector2","value":[40.0,20.0]}
```

Add this exact rejection matrix, then use the shared undo/redo and runtime helpers for the positive paths:

```python
@pytest.mark.parametrize("route,data,code", [
    ("animation/create", {"player_path":"/root/AnimationFixture/AnimationPlayer","library":"","animation":"idle"}, "conflict"),
    ("animation/track/add", {"player_path":"/root/AnimationFixture/AnimationPlayer","animation":"idle","type":"unknown","path":"Sprite2D:position"}, "invalid_param"),
    ("animation/track/add", {"player_path":"/root/AnimationFixture/AnimationPlayer","animation":"idle","type":"value","path":"Missing:position"}, "not_found"),
    ("animation/key/add", {"player_path":"/root/AnimationFixture/AnimationPlayer","animation":"idle","track":0,"time":99,"value":1}, "invalid_param"),
    ("animation_tree/state/add", {"tree_path":"/root/AnimationFixture/AnimationTree","state_machine_path":"parameters/missing","name":"Run","animation":"run"}, "not_found"),
])
def test_animation_rejections(m4_editor, route, data, code):
    open_domain(m4_editor, "animation")
    before = fixture_probe(m4_editor, "animation_all", {})
    assert exec_error(m4_editor, route, data)["code"] == code
    assert fixture_probe(m4_editor, "animation_all", {}) == before


def test_animation_undo_redo_and_runtime_play(m4_editor):
    open_domain(m4_editor, "animation")
    exec_ok(m4_editor, "animation/create", {"player_path":"/root/AnimationFixture/AnimationPlayer","library":"","animation":"move"})
    editor_undo(m4_editor)
    assert "move" not in fixture_probe(m4_editor, "animation_names", {})
    editor_redo(m4_editor)
    exec_ok(m4_editor, "animation/play", {"player_path":"/root/AnimationFixture/AnimationPlayer","animation":"move"})
    assert runtime_assert(m4_editor, {"op":"eq","left":{"node_path":"/root/AnimationFixture/AnimationPlayer","property":"current_animation"},"right":"move"})["passed"]
```

- [ ] **Step 2: Run animation tests**

Run: `uv run pytest tests/e2e/m4/test_animation.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement resource-safe Animation APIs**

Resolve `AnimationPlayer`, get/create `AnimationLibrary`, and duplicate edited built-in resources before mutation when `resource_local_to_scene` is false. Map track strings to Godot constants with a fixed dictionary. Store the complete before/after resource snapshots in one UndoRedo action. Use `AnimationNodeStateMachine.add_node/add_transition` and set blend parameters only after property-list validation.

- [ ] **Step 4: Verify persistence and runtime playback**

Run: `uv run pytest tests/e2e/m4/test_animation.py -v`

Expected: PASS, including typed key equality after save/reopen and runtime position change during playback.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/animation_editor.gd gdapi/addon/routes/animation gdapi/addon/routes/animation_tree tests/e2e/m4/test_animation.py
git commit -m "feat: add animation authoring routes"
```

---

### Task 3: Add TileMapLayer and TileSet Operations

**Files:**
- Create: `gdapi/addon/runtime/services/tilemap_editor.gd`
- Create: `gdapi/addon/routes/tilemap/info.gd`
- Create: `gdapi/addon/routes/tilemap/cell/{get,set}.gd`
- Create: `gdapi/addon/routes/tilemap/rect/fill.gd`
- Create: `gdapi/addon/routes/tilemap/layer/clear.gd`
- Create: `gdapi/addon/routes/tilemap/used_cells.gd`
- Create: `tests/e2e/m4/test_tilemap.py`

**Interfaces:**
- Tile coordinates use `{x:int,y:int}`; cell identity is `{source_id,atlas_coords:[x,y],alternative_tile}`.
- Rect fill consumes `{layer_path,rect:{position:[x,y],size:[w,h]},cell,force}` and caps area at 65,536 cells.
- Cell set is undoable; rect fill and layer clear require force but remain a single undoable editor action.

- [ ] **Step 1: Write exact cell, rectangle, clear, and reopen tests**

```python
def test_tile_cells_are_exact_and_persistent(m4_editor):
    open_domain(m4_editor, "tilemap")
    layer = "/root/TileFixture/Ground"
    cell = {"source_id": 0, "atlas_coords": [0, 0], "alternative_tile": 0}
    exec_ok(m4_editor, "tilemap/cell/set", {"layer_path": layer, "coords": [2, 3], "cell": cell})
    assert exec_ok(m4_editor, "tilemap/cell/get", {
        "layer_path": layer, "coords": [2, 3]
    })["cell"] == cell
    exec_ok(m4_editor, "tilemap/rect/fill", {
        "layer_path": layer, "rect": {"position":[0,0],"size":[2,2]},
        "cell": cell, "force": True
    })
    save_reopen(m4_editor)
    assert len(exec_ok(m4_editor, "tilemap/used_cells", {"layer_path": layer})["cells"]) == 5
```

- [ ] **Step 2: Run tile tests**

Run: `uv run pytest tests/e2e/m4/test_tilemap.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement Godot 4.7 TileMapLayer editing**

Require the target to be `TileMapLayer`, validate TileSet source and atlas coordinates, snapshot all affected cells before a batch action, then apply `set_cell` or `erase_cell`. Sort used coordinates by y then x. Reject old `TileMap` nodes with `not_supported` and a detail directing callers to `TileMapLayer`.

- [ ] **Step 4: Verify batching, undo, and limits**

Run: `uv run pytest tests/e2e/m4/test_tilemap.py -v`

Expected: PASS; one undo reverses an entire rect/clear operation and an excessive rectangle has no side effect.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/tilemap_editor.gd gdapi/addon/routes/tilemap tests/e2e/m4/test_tilemap.py
git commit -m "feat: add TileMapLayer editing routes"
```

---

### Task 4: Add Material and Shader Workflows

**Files:**
- Create: `gdapi/addon/runtime/services/rendering_editor.gd`
- Create: `gdapi/addon/routes/material/{create,info,set,assign,duplicate,save}.gd`
- Create: `gdapi/addon/routes/shader/{read,write,uniforms}.gd`
- Create: `gdapi/addon/routes/shader/material/create.gd`
- Create: `gdapi/addon/routes/shader/param/set.gd`
- Create: `tests/e2e/m4/test_rendering.py`

**Interfaces:**
- Material targets are a resource `path` or `{node_path,property}`; assignments to current scene are undoable.
- Shader write consumes `{path,code,force}` and validates by assigning code to `Shader` before touching disk.
- Uniform values use VariantCodec and are checked against `Shader.get_shader_uniform_list()`.

- [ ] **Step 1: Write shader uniform and material persistence tests**

```python
def test_shader_material_typed_uniform(m4_editor):
    open_domain(m4_editor, "rendering")
    code = "shader_type canvas_item; uniform vec4 tint : source_color = vec4(1.0);"
    exec_ok(m4_editor, "shader/write", {
        "path": "res://resources/generated.gdshader", "code": code
    })
    exec_ok(m4_editor, "shader/material/create", {
        "shader_path": "res://resources/generated.gdshader",
        "path": "res://resources/generated_material.tres"
    })
    exec_ok(m4_editor, "shader/param/set", {
        "material_path": "res://resources/generated_material.tres",
        "name": "tint", "value": {"type":"Color","value":[0.2,0.4,0.6,1.0]}, "force": True
    })
    assert exec_ok(m4_editor, "material/info", {
        "path": "res://resources/generated_material.tres"
    })["parameters"]["tint"] == {"type":"Color","value":[0.2,0.4,0.6,1.0]}
```

Add exact rendering safety tests:

```python
def test_rendering_rejections_and_undo(m4_editor):
    open_domain(m4_editor, "rendering")
    assert exec_error(m4_editor, "shader/write", {"path":"res://resources/bad.gdshader","code":"shader_type canvas_item; this is invalid"})["code"] == "invalid_param"
    assert exec_error(m4_editor, "shader/param/set", {"material_path":"res://resources/material.tres","name":"missing","value":1,"force":True})["code"] == "not_found"
    assert exec_error(m4_editor, "shader/param/set", {"material_path":"res://resources/material.tres","name":"tint","value":{"type":"Vector2","value":[1,2]},"force":True})["code"] == "invalid_param"
    assert exec_error(m4_editor, "shader/write", {"path":"res://resources/existing.gdshader","code":"shader_type canvas_item;"})["code"] == "unsafe_operation"
    before = fixture_probe(m4_editor, "node_material", {"node_path":"/root/RenderingFixture/Sprite2D"})
    exec_ok(m4_editor, "material/assign", {"node_path":"/root/RenderingFixture/Sprite2D","property":"material","path":"res://resources/material.tres"})
    editor_undo(m4_editor)
    assert fixture_probe(m4_editor, "node_material", {"node_path":"/root/RenderingFixture/Sprite2D"}) == before
```

- [ ] **Step 2: Run rendering tests**

Run: `uv run pytest tests/e2e/m4/test_rendering.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement typed material/shader services**

Support `StandardMaterial3D`, `CanvasItemMaterial`, `ShaderMaterial`, and any instantiable Material subclass. Validate shader code in memory, read uniform `type`/`hint`, and reject mismatches before set. File saves use ResourceSaver and M1 force/audit rules. Node material assignment uses EditAction property commit.

- [ ] **Step 4: Verify rendering persistence and runtime color**

Run: `uv run pytest tests/e2e/m4/test_rendering.py -v`

Expected: PASS and M3 screenshot pixel probe confirms the fixture tint changed.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/rendering_editor.gd gdapi/addon/routes/material gdapi/addon/routes/shader tests/e2e/m4/test_rendering.py
git commit -m "feat: add material and shader workflows"
```

---

### Task 5: Add Audio Bus and Player Operations

**Files:**
- Create: `gdapi/addon/runtime/services/audio_editor.gd`
- Create: `gdapi/addon/routes/audio/bus/{list,add,remove}.gd`
- Create: `gdapi/addon/routes/audio/player/{create,play,stop}.gd`
- Create: `tests/e2e/m4/test_audio.py`

**Interfaces:**
- Bus add/remove consumes `{name,index?,force}` and persists `res://default_bus_layout.tres`.
- Player create consumes `{parent_path,type,stream_path,name,bus}` and is undoable.
- Preview play/stop is non-undoable and returns the selected player path and playing state.

- [ ] **Step 1: Write bus/player persistence and preview tests**

```python
def test_audio_bus_and_player(m4_editor):
    open_domain(m4_editor, "audio")
    exec_ok(m4_editor, "audio/bus/add", {"name": "SFX", "force": True})
    assert "SFX" in [bus["name"] for bus in exec_ok(m4_editor, "audio/bus/list")["buses"]]
    player = exec_ok(m4_editor, "audio/player/create", {
        "parent_path": "/root/AudioFixture", "type": "AudioStreamPlayer",
        "stream_path": "res://resources/tone.wav", "name": "Tone", "bus": "SFX"
    })
    assert player["undoable"] is True
    assert exec_ok(m4_editor, "audio/player/play", {"player_path": "/root/AudioFixture/Tone"})["playing"]
```

- [ ] **Step 2: Run audio tests**

Run: `uv run pytest tests/e2e/m4/test_audio.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement validated bus layout and player handling**

Protect `Master` from removal, reject duplicate bus names, snapshot bus layout before mutation, save the layout resource, and audit. Allow only `AudioStreamPlayer`, `AudioStreamPlayer2D`, and `AudioStreamPlayer3D`; validate stream and bus before node creation.

- [ ] **Step 4: Verify bus snapshot restoration and runtime playback**

Run: `uv run pytest tests/e2e/m4/test_audio.py -v`

Expected: PASS; teardown restores the original bus-layout digest and runtime reports the player stopped after stop.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/audio_editor.gd gdapi/addon/routes/audio tests/e2e/m4/test_audio.py
git commit -m "feat: add audio authoring routes"
```

---

### Task 6: Add UI Layout and Theme Editing

**Files:**
- Create: `gdapi/addon/runtime/services/ui_editor.gd`
- Create: `gdapi/addon/routes/ui/control/set_anchor.gd`
- Create: `gdapi/addon/routes/ui/text/set.gd`
- Create: `gdapi/addon/routes/ui/layout/build.gd`
- Create: `gdapi/addon/routes/theme/create.gd`
- Create: `gdapi/addon/routes/theme/color/set.gd`
- Create: `gdapi/addon/routes/theme/constant/set.gd`
- Create: `gdapi/addon/routes/theme/font_size/set.gd`
- Create: `gdapi/addon/routes/theme/stylebox/set.gd`
- Create: `tests/e2e/m4/test_ui_theme.py`

**Interfaces:**
- Layout build consumes a bounded tree `{type,name,properties,children}` with at most 200 Control nodes.
- Theme setters consume `{path,theme_type,name,value,force}`; stylebox value is a Resource path.
- Anchor, text, and layout mutations are undoable; saved Theme resource mutations are non-undoable.

- [ ] **Step 1: Write declarative layout and typed theme tests**

```python
def test_ui_layout_and_theme(m4_editor):
    open_domain(m4_editor, "ui")
    spec = {"type":"VBoxContainer","name":"Menu","children":[
        {"type":"Label","name":"Title","properties":{"text":"gdcli"},"children":[]},
        {"type":"Button","name":"Play","properties":{"text":"Play"},"children":[]},
    ]}
    result = exec_ok(m4_editor, "ui/layout/build", {
        "parent_path": "/root/UiFixture", "layout": spec
    })
    assert result["created"] == 3 and result["undoable"] is True
    exec_ok(m4_editor, "theme/color/set", {
        "path":"res://resources/ui_theme.tres", "theme_type":"Label",
        "name":"font_color", "value":{"type":"Color","value":[1,0,0,1]}, "force":True
    })
```

Add disallowed non-Control type, node cap, invalid anchor preset, unsupported text node, missing theme item, undo, and save/reopen assertions.

- [ ] **Step 2: Run UI/theme tests**

Run: `uv run pytest tests/e2e/m4/test_ui_theme.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement allowlisted layout construction and Theme APIs**

Allow only Control subclasses, prevalidate the complete tree and decoded properties, then commit one UndoRedo action. Set anchors with `Control.set_anchors_preset`; text only on `Label`, `RichTextLabel`, `Button`, `LineEdit`, and `TextEdit`. Use Theme's typed setters and save only after validating item type/name/value.

- [ ] **Step 4: Verify UI tree and screenshot**

Run: `uv run pytest tests/e2e/m4/test_ui_theme.py -v`

Expected: PASS after save/reopen; M3 screenshot metadata and runtime node text match expected values.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/ui_editor.gd gdapi/addon/routes/ui gdapi/addon/routes/theme tests/e2e/m4/test_ui_theme.py
git commit -m "feat: add UI and theme authoring routes"
```

---

### Task 7: Add Physics Body, Shape, Layer, Raycast, and Joint Operations

**Files:**
- Create: `gdapi/addon/runtime/services/physics_editor.gd`
- Create: `gdapi/addon/routes/physics/body/create.gd`
- Create: `gdapi/addon/routes/physics/shape/create.gd`
- Create: `gdapi/addon/routes/physics/layer/set.gd`
- Create: `gdapi/addon/routes/physics/raycast.gd`
- Create: `gdapi/addon/routes/physics/joint/create.gd`
- Create: `tests/e2e/m4/test_physics.py`

**Interfaces:**
- Body and shape creation are editor UndoRedo operations with 2D/3D dimension consistency checks.
- Layer set consumes integer `collision_layer` and `collision_mask` in `[0, 2^32-1]`.
- Raycast is a non-mutating runtime operation routed over M3; joint creation is undoable.

- [ ] **Step 1: Write exact shape/layer/raycast tests**

```python
def test_physics_shape_layer_and_raycast(m4_editor):
    open_domain(m4_editor, "physics")
    body = exec_ok(m4_editor, "physics/body/create", {
        "parent_path":"/root/PhysicsFixture", "type":"StaticBody2D", "name":"Wall"
    })
    exec_ok(m4_editor, "physics/shape/create", {
        "body_path":body["node_path"], "type":"RectangleShape2D",
        "properties":{"size":{"type":"Vector2","value":[20,40]}}
    })
    exec_ok(m4_editor, "physics/layer/set", {
        "node_path":body["node_path"], "collision_layer":4, "collision_mask":2
    })
    save_reopen(m4_editor)
    hit = exec_ok(m4_editor, "physics/raycast", {
        "from":{"type":"Vector2","value":[0,0]}, "to":{"type":"Vector2","value":[100,0]},
        "collision_mask":4
    })
    assert hit["hit"] and hit["collider_path"].endswith("/Wall")
```

- [ ] **Step 2: Run physics tests**

Run: `uv run pytest tests/e2e/m4/test_physics.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement dimension-safe physics services**

Allow CharacterBody, StaticBody, RigidBody, Area, CollisionShape, and Joint subclasses for 2D/3D. Validate shape properties through property lists and VariantCodec. Execute raycasts in the running scene using `PhysicsDirectSpaceState2D.intersect_ray` or 3D equivalent, encoding position and normal.

- [ ] **Step 4: Verify persistence, undo, and runtime hit typing**

Run: `uv run pytest tests/e2e/m4/test_physics.py -v`

Expected: PASS; mixing 2D/3D returns `invalid_param` without creating nodes.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/physics_editor.gd gdapi/addon/routes/physics tests/e2e/m4/test_physics.py
git commit -m "feat: add physics authoring and raycast routes"
```

---

### Task 8: Add Navigation Region, Bake, Path, and Agent Operations

**Files:**
- Create: `gdapi/addon/runtime/services/navigation_editor.gd`
- Create: `gdapi/addon/routes/navigation/region/list.gd`
- Create: `gdapi/addon/routes/navigation/mesh/bake.gd`
- Create: `gdapi/addon/routes/navigation/path/get.gd`
- Create: `gdapi/addon/routes/navigation/agent/target.gd`
- Create: `tests/e2e/m4/test_navigation.py`

**Interfaces:**
- Region list supports 2D and 3D and returns path, enabled, map RID validity, and resource path.
- Bake consumes `{region_path,save_path?,force}` and is audited/non-undoable.
- Path and target are runtime operations; points and target values use typed Vector2/Vector3 JSON.

- [ ] **Step 1: Write region, bake, path, and target tests**

```python
def test_navigation_bake_and_runtime_path(m4_editor):
    open_domain(m4_editor, "navigation")
    regions = exec_ok(m4_editor, "navigation/region/list")
    assert regions["regions"][0]["path"] == "/root/NavigationFixture/Region"
    baked = exec_ok(m4_editor, "navigation/mesh/bake", {
        "region_path":"/root/NavigationFixture/Region",
        "save_path":"res://resources/baked_navigation.tres", "force":True
    })
    assert baked["baked"] and baked["undoable"] is False
    path = exec_ok(m4_editor, "navigation/path/get", {
        "map":"default", "from":{"type":"Vector2","value":[8,8]},
        "to":{"type":"Vector2","value":[120,8]}
    })
    assert len(path["points"]) >= 2
```

- [ ] **Step 2: Run navigation tests**

Run: `uv run pytest tests/e2e/m4/test_navigation.py -v`

Expected: FAIL with route `not_found`.

- [ ] **Step 3: Implement editor baking and runtime NavigationServer queries**

Use region APIs appropriate to NavigationRegion2D/3D; reject mixed dimensions. Bake asynchronously, complete exactly once, save only after successful bake, and remove callbacks on timeout. At runtime query the default map with NavigationServer2D/3D and set NavigationAgent target position after typed validation.

- [ ] **Step 4: Verify baked resource and runtime path**

Run: `uv run pytest tests/e2e/m4/test_navigation.py -v`

Expected: PASS; timeout/failure does not create the save path and leaves no bake callback.

- [ ] **Step 5: Commit**

```bash
git add gdapi/addon/runtime/services/navigation_editor.gd gdapi/addon/routes/navigation tests/e2e/m4/test_navigation.py
git commit -m "feat: add navigation authoring and runtime routes"
```

---

### Task 9: Lock M4 Route, Documentation, and Persistence Contracts

**Files:**
- Create: `tests/e2e/m4/test_m4_contract.py`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`

**Interfaces:**
- M4 exposes exactly the route files named in Tasks 2–8; no `manage` route or alias is added.
- Each domain test verifies create/query/modify/save/reopen and either UndoRedo or explicit non-undoability.

- [ ] **Step 1: Add cross-domain contract checks**

```python
DOMAIN_PREFIXES = [
    "animation/", "animation_tree/", "tilemap/", "material/", "shader/",
    "audio/", "ui/", "theme/", "physics/", "navigation/",
]

EXPECTED_M4_ROUTES = {
    *{f"animation/{name}" for name in ["create","delete","play","stop","track/add","track/remove","key/add","key/remove"]},
    *{f"animation_tree/{name}" for name in ["state/add","transition/add","blend/set"]},
    *{f"tilemap/{name}" for name in ["info","cell/get","cell/set","rect/fill","layer/clear","used_cells"]},
    *{f"material/{name}" for name in ["create","info","set","assign","duplicate","save"]},
    *{f"shader/{name}" for name in ["read","write","uniforms","material/create","param/set"]},
    *{f"audio/{name}" for name in ["bus/list","bus/add","bus/remove","player/create","player/play","player/stop"]},
    *{f"ui/{name}" for name in ["control/set_anchor","text/set","layout/build"]},
    *{f"theme/{name}" for name in ["create","color/set","constant/set","font_size/set","stylebox/set"]},
    *{f"physics/{name}" for name in ["body/create","shape/create","layer/set","raycast","joint/create"]},
    *{f"navigation/{name}" for name in ["region/list","mesh/bake","path/get","agent/target"]},
}


def test_every_m4_route_has_complete_docs_and_mutation_contract(m4_editor):
    routes = exec_ok(m4_editor, "gdapi/routes")["routes"]
    selected = {route for route in routes if any(route.startswith(p) for p in DOMAIN_PREFIXES)}
    assert selected == EXPECTED_M4_ROUTES
    for route in sorted(selected):
        doc = command_doc(m4_editor, route)
        assert doc["summary"] and doc["returns"]["fields"]
        if doc["params"]:
            assert doc["examples"]
```

- [ ] **Step 2: Run the complete M4 suite**

Run: `uv run pytest tests/e2e/m4 -v`

Expected: PASS with all seven source-fixture domain digests unchanged.

- [ ] **Step 3: Document domain schemas and Godot 4.7 TileMapLayer decision**

Add command examples for typed animation keys, tile cells, shader uniforms, Theme values, physics vectors, and navigation points. Record why public `tilemap/**` maps to `TileMapLayer` only.

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
git add tests/e2e/m4 README.md docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md
git commit -m "docs: complete M4 game systems milestone"
```
