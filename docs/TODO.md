# TODO: Single-editor E2E migration

## Export/run handler timeout (M5)

**Problem:** `test_export_android.py::test_export_run_returns_matching_artifact_digest` fails with 504 Gateway Timeout.

**Root cause:** The Rust GdApiServer (`gdapi/rust/src/server.rs`) has a default handler timeout of 5 seconds (`DEFAULT_TIMEOUT_MS = 5_000`). The `export/run` route handler spawns a child Godot process that takes >5 seconds to complete (exporting a PCK). The HTTP server returns 504 before the handler finishes.

**Attempted fix:** Set `GDAPI_HANDLER_TIMEOUT_MS=180000` in the Godot process environment via `shared_fixture.py:_start_editor`. This was applied but the test was not re-verified after the fix.

**Verification needed:** 
1. Kill any existing Godot editor process
2. Run `GODOT_BIN=D:/app/devel/Godot/v4.7.1/godot_console.exe python -m pytest tests/e2e/m5/test_export_android.py -x -q --durations=10`
3. If the fix works, remove the `pytestmark = pytest.mark.skip(...)` from `test_export_android.py`

**Additional issue:** `test_android_routes_are_deterministic_without_real_device` calls `exec_error` with `extra_args=["--timeout", "60"]`, but the `exec_error` function in `m3/conftest.py` does not accept `extra_args`. The test is also broken regardless of the timeout issue. Fix: either update `exec_error` to accept `extra_args`, or pass the timeout through the data dict.

## M6 policy overlay fixtures

**Status:** Implemented. Module-scoped fixtures in `m6/conftest.py` wrap session-scoped aliases with `temporary_policy`. Verification needed by running M6 tests.

## Policy restoration tests (Plan Task 4)

**Not yet created.** `tests/e2e/test_policy_restore.py` should cover:
- Overlay/restore via `temporary_policy`
- Exception-path restoration
- Restoration failure diagnostics
- Zero subprocess/editor starts during policy switching
- Real capability denial/restoration assertion

## `test_edit_action.py` migration (Plan acceptance)

**Not yet started.** `tests/e2e/test_edit_action.py::test_real_editor_undo_redo` independently executes Godot with `--editor`. Must be migrated to the shared editor or replaced by equivalent shared-editor behavior.

## Acceptance tests (Plan Task 5)

**Not yet created:**
- `EDITOR_START_COUNTER["starts"] == 1` assertion
- Machine-checkable `GODOT_EDITOR_STARTS=1` line for full-suite budget test
- Deterministic shared-state/isolation assertions

## GDScript format/lint gate

**Not yet run.** Must run before final commit:
- `python scripts/format-gd.py`
- `python scripts/format-gd.py --check`
- `gdlint` on all modified `.gd` files

## Full E2E suite

**Not yet run.** Must verify:
- Exactly one editor PID
- Total duration <= 360 seconds
- `cargo test --workspace`, `cargo fmt --check`, `cargo clippy --workspace`