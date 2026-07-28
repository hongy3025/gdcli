# Task 8 report — session-scoped M3 editor harness

Date: 2026-07-29
Base: `cb173c9`

## Delivered

- Made `m3_editor` session-scoped: workspace build, fixture copy/install, editor start, metadata/readiness polling, and teardown occur once per M3 pytest session.
- Added explicit `attach_editor`/`detach_editor`, `attach_game`/`detach_game`, `reset_fixture`, and stale runtime-root cleanup helpers.
- Merged the duplicate lifecycle assertions into one `m3_lifecycle` scenario covering initial stopped, two run/stop cycles, connected transport, pending zero, and stale transport cleanup.
- Added bounded CLI subprocesses and failure diagnostics containing `command`, `exit_code`, `stdout`, `stderr`, `runtime_status`, and `godot_log_tail`.
- Preserved original test failures when cleanup fails; recovery attempts are bounded to one readiness retry and are reported as warnings/events.
- Added `pytest-timeout>=2.3`, refreshed `uv.lock`, and applied a 180-second per-test deadlock guard to E2E tests.

## TDD evidence

RED assertions were added before the harness implementation:

```text
uv run pytest tests/e2e/m3/test_m3_contract.py::test_failed_cli_diagnostics_include_runtime_context -v
1 failed: diagnostics map lacked command/exit_code/stdout/stderr/runtime_status/godot_log_tail
```

The session/counter assertion also failed against the original function-scoped fixture because `build_count` was absent.

GREEN verification, bounded to the requested status/contract scope:

```text
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; uv run pytest tests/e2e/m3/test_runtime_status.py tests/e2e/m3/test_m3_contract.py -v --durations=20 --timeout=180
7 passed in 10.74s
```

The focused run reported one editor setup and the lifecycle scenario passed both run/stop cycles. `python -m py_compile` passed for changed Python files and `git diff --check` exited 0.

## Deferred RED / preserved boundaries

- Shared data-plane game state reset is intentionally not enabled; `m3_running` still restarts the game per test until Task 10 validates the fixture-only runtime reset route.
- No runtime routes, production GDScript handlers, CLI/Rust code, or unrelated route migrations were changed.
- The full M3 and full E2E suites were not run in this handoff because the user requested bounded focused tests only.
- Handoff-owned dirty files (`.gitignore`, fixture project files, and the roadmap status report) were not changed or staged.

## Fix round 1 — reviewer findings

Addressed on top of `4b868fe`:

- Readiness/reset polling now raises `HarnessFailure` with command, exit code, stdout, stderr, runtime status, and Godot log tail. Recovery warnings retain the same structured evidence and no longer replace the original failure.
- `game_attached` remains true until both stop and stopped-state polling succeed. Editor teardown retries game teardown, then terminates/kills the editor and records diagnostics.
- Added injected failure tests for pending/teardown failure and fake-process kill behavior.
- Added stale-file cleanup before editor attach and after reset, plus a connected-game reset lifecycle test. Shared data-plane fixture reset remains deferred to Task 10.
- Setup counters now derive from completed build/install/editor-start lifecycle events rather than literal values.

Fix-round RED:

```text
uv run pytest tests/e2e/m3/test_harness.py -v --timeout=30
2 failed: detach_game cleared game_attached after wait failure; detach_editor did not retry and recovery omitted diagnostic fields
```

Fix-round GREEN, with the explicit Godot 4.7.1 override:

```text
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; uv run pytest tests/e2e/m3/test_harness.py tests/e2e/m3/test_runtime_status.py tests/e2e/m3/test_m3_contract.py -v --durations=20 --timeout=180
10 passed in 11.57s
```

## Fix round 2 — teardown/status/counter findings

Addressed on top of `89008cd`:

- `detach_game` now clears `game_attached` only after stop, stopped-state polling, and stale-runtime cleanup all succeed. Cleanup-only failures retain ownership, raise structured diagnostics, and enter editor teardown retry/force-kill handling.
- Status diagnostics now preserve the actual last `runtime/status` payload, including failed or non-connected results; they no longer substitute a generic self-failed marker.
- `game_run_count` and `game_stop_count` increment only after their respective CLI lifecycle command succeeds.
- Added cleanup-only, last-status, and failed-command-counter regressions.
- No real disconnect/pending transition test was added: the currently migrated runtime operation is synchronous, while async assert/signal routes remain outside Task 8. The pending cleanup coverage is injected harness behavior only.

Fix-round RED:

```text
uv run pytest tests/e2e/m3/test_harness.py -v --timeout=30
4 failed: cleanup-only teardown cleared attachment; readiness/reset diagnostics replaced the last status payload; failed lifecycle commands incremented counters
```

Fix-round GREEN, with the explicit Godot 4.7.1 override:

```text
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; uv run pytest tests/e2e/m3/test_harness.py tests/e2e/m3/test_runtime_status.py tests/e2e/m3/test_m3_contract.py -v --durations=20 --timeout=180
14 passed in 11.59s
```
