# Task 11 report — runtime input route family

Date: 2026-07-29
Base: `96456db`
Branch: `feat/full-capability`

## Scope

- Migrated all six `runtime/input/*` handlers to `GdApiRuntimeRoute`.
- Every input handler dispatches its exact operation with `mutation=true` and no
  editor-local `runtime_input_ops.gd` load.
- Added bounded game-side validation for keys, mouse, gamepad, touch, actions,
  and sequences.
- Sequence validation now checks every entry, child route, child payload, and
  the cumulative sum of relative `after_ms` delays before executing any event.
- Child operation failures are returned unchanged instead of being converted to
  a successful sequence.
- Replaced `_input()` action observation with `_process()` false-to-true edge
  polling; reset releases `ui_accept` and synchronizes the previous state.
- Kept capture and observability route families untouched.

## TDD evidence

RED:

- The source-contract subset failed first on `runtime/input/key`: it still
  extended `route_handler.gd` and loaded `runtime_input_ops.gd`.
- The first full pre-migration RED run exceeded the outer 124-second command
  limit while exercising the old local/long-sequence path. Exact task-owned
  pytest/Godot/gdcli processes were then terminated and no residual process was
  retained.
- The first game-process implementation run was `21 passed / 5 failed`.
  Four valid event failures showed that integral JSON numbers arrive at the
  game as integral floats; the fifth failure showed the existing audit-clear
  `force:true` contract. Validation was corrected to accept only finite,
  integral numeric values while continuing to reject strings, fractions, and
  out-of-range values.

GREEN:

- `GODOT_BIN=...v4.7.1... uv run pytest tests/e2e/m3/test_runtime_input.py -v`
  — 27 passed.
- `GODOT_BIN=...v4.7.1... uv run pytest tests/e2e/test_gdscript_units.py -v`
  — 14 passed.
- `GODOT_BIN=...v4.7.1... uv run pytest tests/e2e/m3/test_runtime_status.py tests/e2e/m3/test_runtime_nodes.py tests/e2e/m3/test_runtime_input.py -v`
  — 53 passed.
- `GODOT_BIN=...v4.7.1... uv run pytest tests/e2e/m3/test_m3_contract.py -k "runtime_manifest_match or runtime_manifest_has_no_aliases" -v`
  — 2 passed, 2 deselected.
- Runtime route files: exactly 35.
- `git diff --check`: passed.

## Behavioral coverage

- Key, mouse, gamepad, touch, action, and valid sequence effects are observed
  through counters in the game process.
- One held `ui_accept` press increments once; a release enables exactly one
  increment on the next press.
- Invalid key, mouse, gamepad, touch, action, and sequence values return stable
  validation codes without counter mutation.
- 101 entries and cumulative delay over 10 seconds are rejected.
- Unsupported child routes and invalid child data are rejected before a valid
  earlier sequence entry can execute.
- Successful and rejected input mutations are audited through the adapter;
  secret and large payload summaries remain redacted/bounded.

## Repository safety

No worktree or prohibited Git operation was used. The protected user-owned
files were not modified by Task 11 and will not be staged:

- `.gitignore`
- `tests/fixture_project/project.godot`
- `tests/fixtures/m3_project/project.godot`
- `tests/fixtures/m3_project/scenes/runtime_main.tscn`
- `docs/reports/2026-07-29-gdcli-roadmap-implementation-status.md`
- `tests/fixtures/m3_project/addons/`

## Fix round 1

Review findings addressed:

- Replaced approximate integer checks with finite, exact `value == floor(value)`
  checks and range validation before any integer conversion. Added direct
  GDScript coverage for fractional near-integers, negative epsilon, NaN,
  infinities, oversized values, and every input integer field.
- RuntimeRoute now always propagates the normalized operation timeout. File
  probe deadlines use the operation timeout plus 500 ms transport grace, which
  remains below the broker's 1000 ms grace. Sequence cumulative delays must be
  less than the operation timeout, and the operation checks its absolute
  deadline after each await and before dispatching a child event.
- Action simulation now sends `InputEventAction` and flushes accumulated input
  so held presses remain idempotent while zero-delay release/press transitions
  are observed before the sequence reply.

The fix necessarily extended the original Task 11 file list with
`runtime_route.gd`, `runtime_transport_file_probe.gd`, their GDScript tests, and
a focused `test_runtime_input_ops.gd` suite because the review identified a
cross-layer timeout prerequisite.

RED evidence:

- Focused InputOps tests initially reported 28 failed assertions.
- File probe deadline tests initially reported 2 failed assertions.
- The zero-delay action sequence E2E initially observed no second edge.

GREEN evidence with Godot 4.7.1:

- `uv run pytest tests/e2e/m3/test_runtime_input.py -v` — 29 passed.
- `uv run pytest tests/e2e/test_gdscript_units.py -v` — 15 passed.
- `uv run pytest tests/e2e/m3/test_runtime_status.py tests/e2e/m3/test_runtime_nodes.py tests/e2e/m3/test_runtime_input.py -v`
  — 55 passed.
- Runtime manifest tests — 2 passed; route file count remains exactly 35.
- `py_compile` and `git diff --check` passed.
- No residual Godot, gdcli, or pytest process remained after verification.
