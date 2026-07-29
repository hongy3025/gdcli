# gdcli M4 Handoff

## Objective

Complete the 51 public M4 game-system routes in `docs/superpowers/plans/2026-07-21-gdcli-m4-game-systems.md`, obeying `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md` when they differ.

Work on the current branch; the user explicitly declined a worktree. Preserve all existing uncommitted changes.

## Non-negotiable invariants

- Exactly 51 M4 public routes; do not add public `runtime/**` routes. M3 must retain exactly 35 runtime routes.
- Physics/navigation is 2D only. Reject 3D before mutation using `not_supported`.
- JSON is typed via `VariantCodec`; errors use stable standard codes.
- Editor mutation uses UndoRedo; file/resource/runtime mutation returns `undoable:false`, and uses force/audit as required.
- M4 E2E tests operate only on a private clone of `tests/fixtures/m4_project`.
- `gdcli install` embeds addon contents from the CLI binary. Force rebuild after addon changes:

```powershell
cargo clean -p gdcli
cargo build --workspace
```

## Current uncommitted work

- M4 bridge: `runtime/game_route.gd`, `runtime/runtime_route.gd`, `runtime/runtime_probe.gd`.
- Public bridge routes: physics raycast, navigation path/get and agent/target.
- Private fixture and E2E harness: `tests/fixtures/m4_project/**`, `tests/e2e/m4/**`.
- Incomplete Task 2 animation/AnimationTree services and route scripts.

Start with:

```powershell
git status --short
git diff --check
```

## Verified Task 1 evidence

Before the later animation work, these passed:

```powershell
uv run pytest tests/e2e/m4/test_m4_contract.py tests/e2e/m4/test_m4_game_bridge.py -v
uv run pytest tests/e2e/m3/test_m3_contract.py -v
```

Results were 4 M4 passes and 4 M3 passes. The bridge maps only these fixed internal operations:

- `physics/raycast` -> `m4/physics/raycast`
- `navigation/path/get` -> `m4/navigation/path/get`
- `navigation/agent/target` -> `m4/navigation/agent/target`

## Immediate blocker: animation command documentation

`tests/e2e/m4/test_animation.py` checks the 11 Task 2 routes. `gdapi/routes` lists all of them, but `command/doc animation/create` fails:

```text
SCRIPT ERROR: Invalid call. Nonexistent function 'new' in base 'GDScript'.
at res://addons/gdapi/runtime/builtin_command_help.gd:39
var handler = _routes[command].new()
```

Reproduce:

```powershell
cargo clean -p gdcli
cargo build --workspace
uv run pytest tests/e2e/m4/test_animation.py -v
```

Already disproved:

- Adding `-> GdApiRouteDoc` to all new `doc()` functions.
- Reformatting `animation/create.gd` to existing typed/multiline style.
- Removing its preload of `animation_editor.gd`.

The last change is a temporary isolation experiment: restore real `animation/create` behavior after diagnosing the registry problem.

### Recommended diagnosis

Instrument the router or `builtin_command_help.gd` temporarily and inspect, for `animation/create` versus known-good `physics/raycast`:

1. `typeof(_routes[command])`
2. resource path and class
3. whether it is `Script` and `can_instantiate()`
4. script parser errors/method list
5. `.uid`/import metadata and ResourceLoader behavior

Do not leave instrumentation in production. The failure occurs before `doc()` runs.

## Task 2 status

Current code attempts animation resource copy/replacement through UndoRedo for create/delete/track/key and contains a preliminary AnimationTree blend service. It is not accepted:

- `animation_tree/state/add` and `transition/add` are placeholders returning `not_supported`; implement real `AnimationNodeStateMachine` mutations with UndoRedo.
- Add true E2E for create/track/key, undo/redo, persistence/reopen, invalid inputs, duplicate names, and force safeguards.
- Check `tests/e2e/m4/helpers.py`: its `editor_undo/editor_redo` assumes routes not yet confirmed. Resolve through the existing fixture plugin or an approved testing control path.

## Remaining implementation order

1. Complete Task 2 animation and AnimationTree.
2. Task 3 TileMapLayer (6 routes).
3. Task 4 material/shader (11 routes).
4. Task 5 audio (6 routes).
5. Task 6 UI/theme (8 routes).
6. Task 7 2D physics editor routes.
7. Task 8 2D navigation editor routes.
8. Task 9: docs, 51-route manifest lock, closure report, full verification.

## Completion verification

Run all of these only after a requirement-by-requirement spec/plan audit:

```powershell
cargo fmt --check
cargo clippy --workspace
cargo test --workspace
uv run pytest tests/e2e/m4 -v
uv run pytest tests/e2e/m3/test_m3_contract.py -v
uv run pytest tests/e2e/ -v
git diff --check
```

Tests must prove final state, failed-operation no-side-effects, UndoRedo or explicit `undoable:false`, persistence/runtime evidence, audit, and force behavior—not merely HTTP success.
