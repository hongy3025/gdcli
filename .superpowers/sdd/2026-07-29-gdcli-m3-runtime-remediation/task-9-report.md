# Task 9 report — scene/node route family

Date: 2026-07-29
Base: `07a255f`

## Delivered

- Migrated `runtime/scene/tree` and all existing `runtime/node` routes in scope to `GdApiRuntimeRoute`; no route-local `runtime_node_ops.gd` loads remain.
- Added the three independent routes `runtime/node/create`, `runtime/node/duplicate`, and `runtime/node/rename`; no aliases were added.
- Added RuntimeProbe dispatch for all three new operations.
- Implemented game-side create, duplicate, rename, typed VariantCodec set/call arguments, absolute node-path segment validation, protected-node checks, duplicate-name conflicts, and reparent cycle rejection.
- Preserved route docs and adapter mutation envelopes (`changed`, `undoable:false`, operation audit); mutation route failures continue through the adapter audit path.
- Runtime route manifest is exactly 35 routes (34 data-plane plus `runtime/status`).

## TDD evidence

RED was observed before production implementation:

```text
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; uv run pytest tests/e2e/m3/test_runtime_nodes.py tests/e2e/m3/test_m3_contract.py -v
11 failed, 4 passed in 21.22s
```

The failures included manifest `32 != 35`, missing create/duplicate/rename routes, editor-local node operation behavior, and unhandled reparent self-cycle behavior.

GREEN focused verification:

```text
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; uv run pytest tests/e2e/m3/test_runtime_nodes.py tests/e2e/m3/test_m3_contract.py -v
15 passed in 21.87s
```

```text
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; uv run pytest tests/e2e/test_gdscript_units.py -v
13 passed in 13.42s
```

`git diff --check` exited 0. No CLI/Rust files were changed.

## Fix round 1 — dedicated-node safety

Fix base: `9b01a96`

- Replaced the prior scene-descendant mutation rule with an explicit production-side policy: the existing `ProbeTarget` fixture target is allowlisted and tagged on first authorization; runtime-created and duplicated nodes receive the `gdapi_runtime_dedicated` tag; all other scene descendants are rejected for mutation.
- Protected `ProbeInput`, `ProbeInputAction`, `ProbeFinishedSignal`, and unlisted fixture controls from set/call/remove/reparent/duplicate/rename while keeping read-only inspection available.
- Restricted reparent destinations to the current scene root or another dedicated target, corrected ancestor reparenting, and preserved true cycle rejection.
- Added behavioral E2E coverage for all three named infrastructure nodes, successful created-node reparent/remove, and the exact 35-route/no-alias contract; added GDScript coverage for infrastructure and unlisted fixture rejection.

Fix-round RED evidence:

```text
uv run pytest tests/e2e/m3/test_runtime_nodes.py -k "infrastructure or created_node" -v
2 failed, 11 deselected
```

```text
uv run pytest tests/e2e/test_gdscript_units.py -k runtime_node_ops -v
2 passed, 7 failed
```

Fix-round GREEN verification:

```text
uv run pytest tests/e2e/m3/test_runtime_nodes.py tests/e2e/m3/test_m3_contract.py -v
17 passed in 27.40s
```

```text
uv run pytest tests/e2e/test_gdscript_units.py -v
14 passed in 10.22s
```

## Deferred RED / preserved boundaries

- Later input, capture, log/debug, assert, and signal route families remain deferred to their planned tasks.
- Shared data-plane game reset remains deferred to Task 10; `m3_running` continues to isolate each test by restarting the game.
- Full M3 and full E2E suites were not run in this focused Task 9 handoff.
- Handoff-owned dirty files (`.gitignore`, both fixture `project.godot` files, `runtime_main.tscn`, roadmap status report, and `tests/fixtures/m3_project/addons/`) were preserved and not staged.
