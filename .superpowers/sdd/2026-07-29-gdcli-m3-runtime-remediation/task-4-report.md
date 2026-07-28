# Task 4 report — EngineDebugger registration and transport fallback

Date: 2026-07-29
Base: `b734ec0`
Commit message: `fix(m3): register debugger and prioritize transports`

## Scope delivered

- Registered the instantiated `EditorDebuggerPlugin` in `_enter_tree()` and kept the paired removal in `_exit_tree()`.
- Kept broker transport selection centralized at `engine_debugger > file > none`.
- Added explicit EngineDebugger detach behavior: same-session file fallback remains active, while detaching the final transport fails each pending request exactly once.
- Routed debugger session clear through the explicit engine detach path and only marks a debugger transport connected after a valid session attach.
- Preserved protocol v1, CLI boundaries, existing transport boundaries, and all runtime route/generation work for later tasks.

## TDD evidence

RED was observed before production changes:

```text
uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_broker or runtime_debugger_plugin" -v
3 failed: missing explicit engine detach and missing add_debugger_plugin registration
```

Focused GREEN:

```text
GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_broker or runtime_debugger_plugin" -v
3 passed, 10 deselected
```

The full GDScript unit run passed 12 tests and retained one intentional Task 5 RED: the generation contract requires `broker.begin_generation()`.

Rust regression tests:

```text
cargo test --workspace
all workspace test groups passed (0 failures)
```

`git diff --check` passed.

## Handoff-owned files

The pre-existing dirty paths were not edited or staged:

- `.gitignore`
- `tests/fixture_project/project.godot`
- `tests/fixtures/m3_project/project.godot`
- `tests/fixtures/m3_project/scenes/runtime_main.tscn`
- `docs/reports/2026-07-29-gdcli-roadmap-implementation-status.md`
- `tests/fixtures/m3_project/addons/`

## Deferred RED

Task 5 generation binding/stale cleanup remains intentionally RED. No generation metadata, runtime routes, route generation, or CLI changes were made in Task 4.
