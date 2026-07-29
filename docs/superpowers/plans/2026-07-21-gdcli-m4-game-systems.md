# gdcli M4 Game Systems Implementation Plan

> **For agentic workers:** execute this plan task-by-task, preserving the current branch and existing user changes. Do not create a worktree.

**Goal:** Deliver the 51 M4 public game-system routes in the roadmap, with typed editor mutations, runtime verification where required, persisted-artifact evidence, and complete route documentation.

**Architecture:** M4 stays on the existing HTTP router and M3 runtime broker. Editor-facing route handlers delegate to domain services under `gdapi/addon/runtime/services/`. The three M4 routes that need a running game use a new generic game-route adapter which maps their public operation to an internal `m4/**` runtime operation; it must share the M3 timeout, cancellation, audit, bounds, and exactly-once response semantics. It must not add routes below `runtime/**`: M3 continues to expose exactly 35 runtime routes.

**Tech stack:** Godot 4.7.x, GDScript, gdapi route/runtime infrastructure, Rust CLI transport, pytest/uv E2E fixtures, Godot editor test addon.

## Scope and invariants

- M4 public route total is exactly 51. Existing M1--M3 route names and behavior remain compatible.
- M4 v1 supports 2D-only physics and navigation. A 3D node, shape, map, or query returns `not_supported` before mutation.
- Every handler validates typed JSON via `VariantCodec` and returns `invalid_param` before it mutates editor state.
- Node/scene changes are wrapped in `GdApiEditAction`/`UndoRedo`; file writes, resource replacement, shader writes, bus-layout changes, and navigation baking are explicitly `undoable:false`, protected by `force:true` where overwriting/destructive.
- Route results use deterministic ordering and resource paths, never Godot object IDs.
- M4 E2E runs against a private clone of `tests/fixtures/m4_project`; no test alters the checked-in fixture.

## Shared test interfaces

Create `tests/e2e/m4/helpers.py` before domain tests. It owns these stable helpers:

```python
def open_domain(env: M4Env, domain: str) -> None: ...
def run_domain(env: M4Env, domain: str) -> None: ...
def stop_domain(env: M4Env) -> None: ...
def exec_ok(env: M4Env, route: str, data: dict | None = None) -> dict: ...
def exec_error(env: M4Env, route: str, data: dict | None, code: str) -> dict: ...
def command_doc(env: M4Env, route: str) -> dict: ...
def save_reopen(env: M4Env, scene_path: str) -> None: ...
def editor_undo(env: M4Env) -> None: ...
def editor_redo(env: M4Env) -> None: ...
def source_digest(path: Path) -> str: ...
```

`run_domain` uses `project/run` with the fixture's explicit `scene_path`, waits for the M3 broker connection and one physics frame, and fails rather than skips if the runtime prerequisite cannot be reached. `stop_domain` always calls `project/stop`, waits for disconnect/pending-request cleanup, and runs in fixture teardown.

## Task 1: establish the M4 bridge, fixture, and contract harness

**Files:**

- Modify: `gdapi/addon/runtime/runtime_route.gd`
- Create: `gdapi/addon/runtime/game_route.gd`
- Modify: `gdapi/addon/runtime/runtime_probe.gd`
- Create: `gdapi/addon/routes/physics/raycast.gd`
- Create: `gdapi/addon/routes/navigation/path/get.gd`
- Create: `gdapi/addon/routes/navigation/agent/target.gd`
- Create: `tests/fixtures/m4_project/project.godot`
- Create: `tests/fixtures/m4_project/scenes/{animation,tilemap,rendering,audio,ui,physics,navigation}.tscn`
- Create: `tests/fixtures/m4_project/resources/{tile.svg,tile_set.tres,tone.tres,navigation_polygon.tres}`
- Create: `tests/fixtures/m4_project/addons/gdapi_test/{plugin.cfg,plugin.gd}`
- Create: `tests/e2e/m4/{conftest.py,helpers.py,test_m4_contract.py,test_m4_game_bridge.py}`

**Implementation:**

1. Extract the shared broker dispatch lifecycle from `GdApiRuntimeRoute` without changing its public behavior. `GdApiGameRoute` must use that lifecycle and expose a fixed internal operation supplied by its subclass.
2. `physics/raycast`, `navigation/path/get`, and `navigation/agent/target` map only to `m4/physics/raycast`, `m4/navigation/path/get`, and `m4/navigation/agent/target`. Reject all client-provided operation names.
3. Extend `GdApiRuntimeProbe` with only those three explicit `m4/**` operations. Keep its M3 operation table intact; unknown operations return the established unsupported-operation error.
4. Build the source M4 project with a `GdApiRuntimeProbe` autoload, seven selected domain scenes, and fixed resources. The physics scene contains a `World2D`, deterministic static colliders, and a ray target. The navigation scene contains a `NavigationRegion2D`, a baked polygon, and a `NavigationAgent2D` target host. The tile scene has a `TileMapLayer` using the checked-in atlas resource.
5. The M4 `conftest.py` builds once per session, installs/copies the addon as existing E2E harnesses do, creates a private fixture clone per test, and guarantees editor/process cleanup.

**Tests first:** assert the three routes appear in `command/list`; each has full `command/doc`; M3 runtime route count remains 35; public requests cannot select an arbitrary operation; one successful physics and navigation round trip is observed only after `run_domain`; stopping the scene clears pending runtime state.

**Verify:**

```bash
uv run pytest tests/e2e/m4/test_m4_contract.py tests/e2e/m4/test_m4_game_bridge.py -v
uv run pytest tests/e2e/m3/test_m3_contract.py -v
```

**Commit:** `test(m4): add isolated game-system fixture and runtime bridge`

## Task 2: animation and animation-tree authoring

**Files:**

- Create: `gdapi/addon/runtime/services/animation_editor.gd`
- Create: `gdapi/addon/runtime/services/animation_tree_editor.gd`
- Create: `gdapi/addon/routes/animation/{create,delete,play,stop,track/{add,remove},key/{add,remove}}.gd`
- Create: `gdapi/addon/routes/animation_tree/{state/add,transition/add,blend/set}.gd`
- Create: `tests/e2e/m4/test_animation.py`

**Implementation:** use a fixed `AnimationPlayer`/`AnimationTree` selection contract: scene-relative node path plus animation/state identifiers. Create/delete tracks and keys through snapshot/replacement of the scene-local animation resource so UndoRedo can restore the exact resource; never mutate a nested resource in-place outside an action. `play`/`stop` validate state and persist no runtime-only claim. Tree changes target a fixed editable state-machine resource and reject missing/invalid state names before mutation.

**Tests first:** create a named animation, add/remove a value track and key, undo/redo each mutation, save/reopen, and check sorted animation/track output. Create a tree state and transition, set blend position, then cover duplicate name, missing path, invalid key value, and forced replacement safeguards.

**Verify:** `uv run pytest tests/e2e/m4/test_animation.py -v`

**Commit:** `feat(m4): add animation authoring routes`

## Task 3: TileMapLayer queries and cell editing

**Files:**

- Create: `gdapi/addon/runtime/services/tilemap_editor.gd`
- Create: `gdapi/addon/routes/tilemap/{info,cell/{get,set},rect/fill,layer/clear,used_cells}.gd`
- Create: `tests/e2e/m4/test_tilemap.py`

**Implementation:** operate exclusively on `TileMapLayer`. Decode coordinates and atlas/source identifiers strictly; reject coordinates outside Godot's signed 16-bit cell range before mutation. Call `update_internals()` only when the route must return freshly computed map data. `rect_fill` has an explicit maximum-cell bound. `layer_clear` requires `force:true`. Results use sorted `Vector2i` coordinate records and fixed source/atlas identifiers.

**Tests first:** get initial atlas cell; set it, undo/redo, save/reopen; fill a rectangle and verify all returned used cells; clear only with force; reject an absent layer/node, malformed coordinates, an out-of-range coordinate, and a rectangle exceeding the bound.

**Verify:** `uv run pytest tests/e2e/m4/test_tilemap.py -v`

**Commit:** `feat(m4): add tilemap layer routes`

## Task 4: material and shader assets

**Files:**

- Create: `gdapi/addon/runtime/services/material_editor.gd`
- Create: `gdapi/addon/runtime/services/shader_editor.gd`
- Create: `gdapi/addon/routes/material/{create,info,set,assign,duplicate,save}.gd`
- Create: `gdapi/addon/routes/shader/{read,write,uniforms,material/create,param/set}.gd`
- Create: `tests/e2e/m4/test_rendering.py`

**Implementation:** support the roadmap's documented material types only and return a stable whitelist of editable properties. Shader write/create and material save create or overwrite project-local resources only; existing targets require `force:true`, use `PathGuard`, audit the write, and report `undoable:false`. `shader/uniforms` parses the loaded shader and returns stable names/types/defaults; `param/set` validates against that list before material mutation. Duplicate produces a distinct project-local resource path.

**Tests first:** create/configure/assign a material with undo/redo; duplicate and save it; create/read/write a shader, inspect uniforms, create shader material, and set a valid parameter. Verify a reopened scene/resource, destination protection, invalid property/type, missing uniform, and traversal rejection.

**Verify:** `uv run pytest tests/e2e/m4/test_rendering.py -v`

**Commit:** `feat(m4): add material and shader routes`

## Task 5: audio bus and player controls

**Files:**

- Create: `gdapi/addon/runtime/services/audio_editor.gd`
- Create: `gdapi/addon/routes/audio/{bus/{list,add,remove},player/create,play,stop}.gd`
- Create: `tests/e2e/m4/test_audio.py`

**Implementation:** manipulate the private fixture's bus layout and fixed `AudioStreamPlayer` node contract. Bus names are unique, sorted, and validate prohibited/default bus operations. Bus layout changes are file-level, audited non-undoable operations; removing a bus needs `force:true`. Player creation is an UndoRedo node change. Playback controls require the selected audio domain running and use the M3 broker only if runtime state must be observed.

**Tests first:** list/add/remove a bus, verify source fixture digest unchanged; create player then undo/redo and save/reopen; play/stop a configured tone while the audio domain is running; cover duplicate/missing/default bus and play-without-running-domain errors.

**Verify:** `uv run pytest tests/e2e/m4/test_audio.py -v`

**Commit:** `feat(m4): add audio system routes`

## Task 6: UI controls and themes

**Files:**

- Create: `gdapi/addon/runtime/services/ui_editor.gd`
- Create: `gdapi/addon/runtime/services/theme_editor.gd`
- Create: `gdapi/addon/routes/ui/{control/set_anchor,text/set,layout/build}.gd`
- Create: `gdapi/addon/routes/theme/{create,color/set,constant/set,font_size/set,stylebox/set}.gd`
- Create: `tests/e2e/m4/test_ui.py`

**Implementation:** `control/set_anchor` addresses an existing selected Control and accepts only an explicit anchor/offset map; it cannot become arbitrary `set()` access. `text/set` is restricted to a text-capable Control allowlist, and `layout/build` uses a fixed layout allowlist. All scene tree changes use UndoRedo. Theme routes address a project-local Theme resource by controlled type/name/property keys, validate `StyleBox` input using VariantCodec, and persist through an explicit save path requiring force for replacement.

**Tests first:** set approved text/anchors/layout on a fixture Button, undo/redo and save/reopen; reject unsupported control class/property/layout values. Create a theme and set color, constant, font-size and stylebox, reload it, and reject bad theme item/type/value requests.

**Verify:** `uv run pytest tests/e2e/m4/test_ui.py -v`

**Commit:** `feat(m4): add UI and theme routes`

## Task 7: 2D physics construction and raycasts

**Files:**

- Create: `gdapi/addon/runtime/services/physics_editor.gd`
- Create: `gdapi/addon/routes/physics/{body/create,shape/create,layer/set,joint/create}.gd`
- Modify: `gdapi/addon/routes/physics/raycast.gd`
- Create: `tests/e2e/m4/test_physics.py`

**Implementation:** create only `PhysicsBody2D` and supported `CollisionShape2D` shapes, with canonical collision-layer/mask values. `raycast` obtains `World2D.direct_space_state` at runtime and uses `PhysicsRayQueryParameters2D`; it must never instantiate a direct space state. It returns deterministic hit fields (collider scene path, position, normal, rid-free metadata). Joints use a supported 2D joint whitelist. Any 3D node/shape/query is rejected with `not_supported`.

**Tests first:** create body/shape/layers/joint with undo/redo and reopen evidence; run the physics fixture and verify deterministic ray hit/miss; assert invalid layer range, missing body, and all 3D requests fail before mutation.

**Verify:** `uv run pytest tests/e2e/m4/test_physics.py -v`

**Commit:** `feat(m4): add 2D physics routes`

## Task 8: 2D navigation region, bake, path, and agent target

**Files:**

- Create: `gdapi/addon/runtime/services/navigation_editor.gd`
- Create: `gdapi/addon/routes/navigation/{region/list,mesh/bake}.gd`
- Modify: `gdapi/addon/routes/navigation/{path/get,agent/target}.gd`
- Create: `tests/e2e/m4/test_navigation.py`

**Implementation:** enumerate `NavigationRegion2D` deterministically and use the selected region's actual navigation-map RID internally, never a global `"default"` map label. Baking writes only an explicit project-local target, is bounded by the broker timeout/cleanup policy, requires force when replacing output, and is audited non-undoable. `path/get` and `agent/target` run through the Task 1 adapter and accept only 2D vectors and selected fixture node paths.

**Tests first:** list fixture regions; bake to a private target and reopen it; run the domain, get a non-empty path and set/read the agent target; assert navigation is unavailable after stop, path errors are typed, replacement needs force, and 3D requests return `not_supported`.

**Verify:** `uv run pytest tests/e2e/m4/test_navigation.py -v`

**Commit:** `feat(m4): add 2D navigation routes`

## Task 9: documentation, count lock, and milestone evidence

**Files:**

- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`
- Modify: `docs/superpowers/plans/2026-07-21-gdcli-m4-game-systems.md`
- Create: `docs/reports/YYYY-MM-DD-gdcli-m4-game-systems-closure.md`
- Modify: `tests/e2e/m4/test_m4_contract.py`

**Implementation:** document route parameters, response schema, mutation/force/undo semantics, and the M4 2D boundary. Lock the exact M4 public set in the contract test:

- `animation/{create,delete,play,stop,track/add,track/remove,key/add,key/remove}` (8)
- `animation_tree/{state/add,transition/add,blend/set}` (3)
- `tilemap/{info,cell/get,cell/set,rect/fill,layer/clear,used_cells}` (6)
- `material/{create,info,set,assign,duplicate,save}` (6)
- `shader/{read,write,uniforms,material/create,param/set}` (5)
- `audio/{bus/list,bus/add,bus/remove,player/create,play,stop}` (6)
- `ui/{control/set_anchor,text/set,layout/build}` (3)
- `theme/{create,color/set,constant/set,font_size/set,stylebox/set}` (5)
- `physics/{body/create,shape/create,layer/set,raycast,joint/create}` (5)
- `navigation/{region/list,mesh/bake,path/get,agent/target}` (4)

The closure report records commands, pass counts, fixture isolation evidence, and explicit confirmation that M3 still exposes 35 `runtime/**` routes.

**Tests first:** compare the `command/list` M4 subset to the 51-name set, fetch `command/doc` for every name, and verify no M4 route is exposed under `runtime/**`.

**Verify:**

```bash
cargo fmt --check
cargo clippy --workspace
cargo test --workspace
uv run pytest tests/e2e/m4 -v
uv run pytest tests/e2e/m3/test_m3_contract.py -v
uv run pytest tests/e2e/ -v
git diff --check
```

**Commit:** `docs(m4): close game systems milestone`

## Plan self-review

- The route inventory is 51: 8 + 3 + 6 + 6 + 5 + 6 + 3 + 5 + 5 + 4.
- The three runtime-dependent public routes are bridged through internal `m4/**` operations, so M3's 35-route runtime contract is unchanged.
- Every domain has a fixture, success path, validation failure, persistence or runtime evidence, and cleanup path.
- The plan intentionally excludes CI gating, 3D physics/navigation, arbitrary editor property setting, and shared-fixture mutation.
