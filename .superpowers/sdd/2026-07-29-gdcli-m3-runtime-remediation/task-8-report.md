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
