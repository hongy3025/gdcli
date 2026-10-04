# Task 5 report — generation binding and stale transport cleanup

Date: 2026-07-29
Base: `7e11ea8`
Commit: `335ff2b` plus fix round `3a80509`

## Takeover audit

- Took over the dirty worktree from the stopped agent with HEAD still at
  `7e11ea8`.
- Preserved the handoff-owned `.gitignore`, fixture project files, roadmap
  report, and `tests/fixtures/m3_project/addons/` changes outside the Task 5
  change set.
- Audited the partial generation implementation and corrected hello metadata
  validation, malformed JSON handling before typed assignment, and generation
  metadata on the focused debugger/integration test replies.

## Delivered

- Added optional generation metadata to protocol-v1 request/reply messages and
  generation-aware hello result metadata without changing the v1 top-level
  message kinds or transport set.
- Added `broker.begin_generation() -> String`, generation-aware
  `begin_connect`, generation status, request binding, stale reply rejection,
  and restart/disconnect pending cleanup with exactly-once callbacks.
- Bound the first valid file hello when no generation is active; subsequent
  hello, request, and reply metadata must match the current generation.
- Added generation propagation through file probe and EngineDebugger hello/
  reply paths, including pid, started_at, and transport metadata.
- Added recursive cleanup guarded to the runtime root for editor start/restart,
  stop, disappearing hello, probe stop, and plugin exit. Probe stop removes its
  complete directory, including inbox/outbox files.
- Added real broker/transport lifecycle assertions for stale hello/outbox,
  missing hello detach, generation reply rejection, metadata, and recursive
  cleanup. Updated the existing integration fixture to rebind an intentionally
  invalidated debugger session after a generation restart.

## Verification

RED evidence:

```text
uv run pytest tests/e2e/test_gdscript_units.py -k runtime_transport_integration -v
1 failed: generation contract requires broker.begin_generation()
```

Focused Godot 4.7.1 GREEN:

```text
GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_protocol or runtime_broker or runtime_transport_file or runtime_transport_integration or runtime_debugger_plugin" -v
6 passed, 6 deselected
```

Additional bounded RED evidence captured during takeover:

```text
runtime_transport_file_editor: incomplete hello was accepted
runtime_transport_file_probe: non-dictionary inbox caused a typed-assignment error
runtime_debugger_plugin: generation-bound reply without metadata did not complete
```

The corresponding focused test-first corrections were made after those
failures. No further test process was launched during final handoff after the
user requested commit-only completion.

Rust regression:

```text
cargo test --workspace
196 passed, 0 failed
```

`git diff --check`: run as the final pre-commit verification.

## Intentional non-scope

- No public routes or route handlers were changed.
- No CLI, Rust production code, protocol version, or transport type was
  changed.
- No unrelated editor behavior, mutation behavior, or handoff-owned dirty file
  was modified or staged.
- Full M3 route migration, audit/bounds closure, and later runtime behavior
  remain deferred to their planned tasks.

## Handoff-owned files preserved

`.gitignore`, `tests/fixture_project/project.godot`,
`tests/fixtures/m3_project/project.godot`,
`tests/fixtures/m3_project/scenes/runtime_main.tscn`,
`docs/reports/2026-07-29-gdcli-roadmap-implementation-status.md`, and
`tests/fixtures/m3_project/addons/` remain outside the Task 5 change set.

## Fix round 1 on `335ff2b`

Review findings addressed:

- Narrowly normalize only integral float `pid` values inside hello event
  results before hello validation; protocol version/id normalization remains
  unchanged.
- Reject generation-less file probe requests whenever the probe has an active
  generation. Existing probe tests now write the current generation; legacy
  no-generation behavior remains available when no generation is active.
- Keep generation-less file replies and debugger replies from completing
  generation-bound pending requests.
- Recursively remove a disappeared probe directory, including hello/inbox/
  outbox files, within the bounded runtime root.

Fix-round RED evidence:

```text
GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_transport_file_editor or runtime_transport_file_probe or runtime_debugger_plugin" -v
file_probe: generation-less request incorrectly produced a reply
file_editor: integral JSON pid=1 was rejected and dependent hello tests failed
debugger plugin: generation-less reply assertion already passed through broker rejection
```

Fix-round GREEN evidence:

```text
GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_protocol or runtime_broker or runtime_transport_file or runtime_transport_integration or runtime_debugger_plugin" -v
6 passed, 6 deselected in 8.20s
```

No Rust sources changed in this fix round; `cargo test --workspace` was not
rerun. The prior Task 5 evidence remains `196 passed, 0 failed`.

## Fix round 2 on `3a80509`

The RuntimeProbe EngineDebugger capture boundary now requires the inbound
request generation to match the active file/runtime generation. A
generation-less request is rejected before `_dispatch`, so it cannot produce
a generation-less reply. When no generation is active, the existing legacy
generation-less capture behavior remains unchanged.

The regression test uses the real `Broker`, `ProbeTransport`, and
`RuntimeProbe` harness. It starts a broker generation, has the probe adopt that
generation from its marker, sends a generation-less `runtime/log/clear`
request through `_on_runtime_capture`, and verifies the capture is rejected
and the probe ring buffer is not cleared.

Fix-round RED evidence:

```text
GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_transport_integration" -v
25 passed, 2 failed
generationless EngineDebugger request is ignored - expected 'false', got 'true'
ignored request is not dispatched or replied - expected '1', got '0'
```

Fix-round GREEN evidence:

```text
GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe uv run pytest tests/e2e/test_gdscript_units.py -k "runtime_transport_integration" -v
1 passed, 11 deselected in 6.14s
```

Final `git diff --check`: exit 0 with no whitespace errors; Git emitted only
the existing LF/CRLF working-copy advisory warnings. No cargo test was run in
this round because no Rust files changed.
