# Runtime Probe Headless Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Godot 4.7.1 Windows headless editor reliably start and stop runtime probe scenes through `project/run` and `project/stop`.

**Architecture:** Keep the existing session-scoped editor and broker. Add pure Python editor-command/environment builders, route scene playback through the persistent `EditorPlugin`, and make the E2E harness wait for actual `editor_playing` before broker connection.

**Tech Stack:** Godot 4.7.1 GDScript, Python pytest, `gdformat`, `gdlint`, Rust workspace tests.

## Global Constraints

- Target Godot version: 4.7.x; validation binary: `D:\app\devel\Godot\v4.7.1\godot_console.exe`.
- Keep `--editor --headless --path`; add `--audio-driver Dummy`.
- Do not default to `--display-driver headless`; the progress report recorded failed scene playback with it.
- Before unit tests, run `python scripts/format-gd.py`, `python scripts/format-gd.py --check`, then `gdlint` on all modified `.gd`; install `gdtoolkit` with `uv tool install gdtoolkit` if absent.
- Daily test scope is `cargo test --workspace`; E2E and budget suites are explicit only.
- Preserve unrelated pre-existing working-tree changes.

## File Map

- `gdapi/addon/routes/project/stop.gd`: legal bounded wait and stop-before-detach ordering.
- `gdapi/addon/routes/project/run.gd`: deferred editor play request and truthful playback snapshot.
- `gdapi/addon/runtime/runtime_probe.gd`: lint-only class-definition-order fix.
- `tests/e2e/shared_fixture.py`: pure editor command builder and startup use.
- `tests/e2e/m3/conftest.py`: wait for editor playback before broker connection.
- `tests/e2e/test_shared_editor_lifecycle.py`: startup command regression test.
- `tests/e2e/m3/test_harness.py`: playback-wait regression test.

---

### Task 1: Restore GDScript gate

**Files:** Modify `gdapi/addon/routes/project/stop.gd`, `gdapi/addon/runtime/runtime_probe.gd`, and the checked-in fixture mirror only if required.

- [ ] Write the failing gate: run `python scripts/format-gd.py --check` and `gdlint` on the modified production files; observe the bare `;` parse error and class-definition-order errors.
- [ ] Replace the empty loop body in `stop.gd` with legal `pass` while preserving the 10-second condition and stop-before-detach order.
- [ ] Keep or relocate the `# gdlint: ignore=class-definitions-order` directive so the installed gdlint accepts `runtime_probe.gd`; do not alter runtime behavior.
- [ ] Run `python scripts/format-gd.py`, `python scripts/format-gd.py --check`, and `gdlint` on every modified `.gd`; require exit 0 for production files before tests.
- [ ] Commit only this gate fix with `git commit -m "fix: restore runtime route gdscript validity"`.

### Task 2: Lock headless editor startup

**Files:** Modify `tests/e2e/shared_fixture.py` and `tests/e2e/test_shared_editor_lifecycle.py`.

- [ ] Add the failing pure test:

```python
def test_build_editor_command_uses_headless_audio_driver(tmp_path: Path):
    assert shared_fixture.build_editor_command("godot.exe", tmp_path) == [
        "godot.exe", "--editor", "--headless", "--audio-driver", "Dummy",
        "--path", str(tmp_path),
    ]
```

- [ ] Run `uv run pytest tests/e2e/test_shared_editor_lifecycle.py::test_build_editor_command_uses_headless_audio_driver -q`; expect failure because the builder is absent.
- [ ] Implement `build_editor_command(godot_bin: str, project: Path) -> list[str]` returning exactly the list above, and make `_start_editor` pass it to `subprocess.Popen`.
- [ ] Implement `build_editor_environment(project: Path) -> dict[str, str]` that creates `<project>/.godot/appdata` and `<project>/.godot/localappdata`, overrides `APPDATA` and `LOCALAPPDATA`, and make `_start_editor` use it.
- [ ] Add a pure test asserting both Godot data directories are project-local and writable.
- [ ] Re-run the focused test and require one pass.
- [ ] Commit with `git commit -m "test: lock headless editor startup command"`.

### Task 3: Defer editor scene playback

**Files:** Modify `gdapi/addon/routes/project/run.gd`; add/update the adjacent route/harness contract test.

- [ ] Add a failing static regression test asserting `run.gd` contains `call_deferred` and an `editor_playing` response field; run it and confirm failure against the synchronous route.
- [ ] Read `application/run/main_scene` for the no-argument case and route both main/custom scene requests through the persistent plugin's `request_play_scene(scene_path)`, which synchronously calls `EditorInterface.play_custom_scene()`.
- [ ] Include `"editor_playing": EditorInterface.is_playing_scene()` in the acceptance response and document it as an immediate snapshot; keep `runtime_state` limited to `stopped|connecting|connected`.
- [ ] Run focused route/harness tests after the GDScript gate passes and require them to pass.
- [ ] Commit with `git commit -m "fix: defer editor scene playback from gdapi route"`.

### Task 4: Wait for actual playback in M3 harness

**Files:** Modify `tests/e2e/m3/conftest.py`, `tests/e2e/shared_fixture.py`, and `tests/e2e/m3/test_harness.py`.

- [ ] Add a failing test with status sequence `{state: stopped, editor_playing: false}` then `{state: connecting, editor_playing: true}`, asserting a new `wait_for_editor_playing(env, timeout)` returns the second payload.
- [ ] Implement `wait_for_editor_playing(env: dict[str, Any], timeout: float = 15.0) -> dict[str, Any]`, polling `runtime/status` every 0.1 seconds and raising existing `HarnessFailure` diagnostics on timeout.
- [ ] Call it immediately after every `project_run`, before `wait_for_connected`; retain the 60-second connection timeout and last-status diagnostics.
- [ ] Run `uv run pytest tests/e2e/m3/test_harness.py -q` and require all focused tests to pass.
- [ ] Commit with `git commit -m "test: wait for editor playback before probe connection"`.

### Task 5: Full verification

- [ ] Re-run the GDScript format/lint gate before any unit tests.
- [ ] Run `cargo test --workspace`.
- [ ] Run `uv run pytest tests/e2e/test_shared_editor_lifecycle.py tests/e2e/m3/test_harness.py -q`.
- [ ] With `$env:GODOT_BIN = 'D:\app\devel\Godot\v4.7.1\godot_console.exe'`, run `uv run pytest tests/e2e/m3/test_runtime_status.py -v`.
- [ ] Run `git diff --check`, inspect `git status --short` and `git diff --stat`, and report exact results without claiming success from stale output.
