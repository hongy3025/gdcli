# Task 10 report — fixture reset and shared data-plane game

Date: 2026-07-29
Base: `07a1446`

## Delivered

- Corrected the Godot 4.7 EngineDebugger channel contract to use
  `gdapi:protocol` end to end, while the runtime capture callback accepts the
  stripped `protocol` sub-channel.
- Corrected scalar `runtime/node/get` encoding by retaining the
  `VariantCodec.from_variant()` result as `Variant`.
- Added one fixed-semantics fixture reset helper on `GdApiRuntimeProbe`.
  The internal `runtime/fixture/reset` op accepts no payload fields and reuses
  this helper; the EngineDebugger harness reaches the same helper only through
  the explicit `ProbeTarget.reset_shared_fixture` node-call allowlist.
- The reset restores fixture properties and counters, invalidates and
  disconnects pending timers, releases action edge state, restores the known
  signal connection exactly once, preserves dedicated infrastructure nodes,
  removes runtime-created descendants, and clears the runtime probe ring.
- Switched `m3_running` to one session-scoped shared game. Two lifecycle
  run/stop cycles and stale cleanup always run first, independent of test
  collection order; each data-plane test receives a reset before execution.
- Reset failure diagnostics retain the original command, runtime status, log
  tail, and explicit recovery marker. Each reset flow may restart at most once;
  previous recovery attempts do not permanently exhaust later reset flows.

## TDD evidence

RED was observed before the fixes:

```text
uv run python -m py_compile tests/e2e/m3/conftest.py
IndentationError: unindent does not match any outer indentation level (line 653)
```

```text
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; \
uv run pytest tests/e2e/test_gdscript_units.py -k runtime_transport_integration -v
29 passed, 2 failed
```

The missing fixed helper and non-empty internal reset payload both failed.

```text
uv run pytest tests/e2e/m3/test_harness.py -k each_reset_flow -v
1 failed
```

The second independent reset flow was rejected because the old recovery limit
was consumed permanently at session scope.

The real EngineDebugger reset sequence also reproduced a post-reset
`runtime/log/clear` failure (`runtime_probe is not registered`) when reset and
ring clear were split across two public calls.

## GREEN verification

```text
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; \
uv run pytest tests/e2e/test_gdscript_units.py -v
14 passed in 10.16s
```

```text
uv run pytest tests/e2e/m3/test_harness.py -v
7 passed in 0.24s
```

```text
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; \
uv run pytest tests/e2e/m3/test_runtime_status.py \
tests/e2e/m3/test_runtime_nodes.py -v --durations=20 --maxfail=1
21 passed in 16.84s
```

The shared-game budget assertion observed one editor start, exactly three game
starts (two lifecycle cycles plus one shared data-plane game), zero reset
restarts, and zero recovery markers.

```text
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; \
uv run pytest tests/e2e/m3/test_m3_contract.py \
-k "runtime_manifest_match or runtime_manifest_has_no_aliases" -v
2 passed, 2 deselected
runtime_route_files=35
```

`python -m py_compile` and `git diff --check` exited 0. No Godot or gdcli
process remained after verification.

## Preserved later-task RED

The Task 10 brief's exact three-file command was run without skip or weakened
assertions:

```text
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; \
uv run pytest tests/e2e/m3/test_runtime_nodes.py \
tests/e2e/m3/test_runtime_input.py \
tests/e2e/m3/test_runtime_observability.py \
-v --durations=20 --maxfail=1
16 passed, 1 failed
```

The first Task 11 input behavior failed because the input route family still
executes outside the game process. Log/debug routes likewise remain scheduled
for Task 13. Task 10 does not add skips, xfails, direct HTTP calls, or local-op
fallbacks to hide these planned migration failures.

## Protected working-tree state

The handoff-owned changes in `.gitignore`, both protected `project.godot`
files, `runtime_main.tscn`, the roadmap status report, and
`tests/fixtures/m3_project/addons/` were not modified, staged, or committed by
this task.

## Fix round 1

### Finding-to-fix mapping

1. Removed the harness-owned file-transport request IDs and direct
   inbox/outbox writes. Both EngineDebugger and file transport now reset only
   through broker-owned `runtime/node/call` to the fixed
   `ProbeTarget.reset_shared_fixture` allowlist hook. The internal probe reset
   operation remains private and is not used by the harness.
2. Split fixed identity protection from allowlisted property/method access.
   `ProbeTarget`, the three infrastructure nodes, the scene root, and runtime
   probe cannot be duplicated, renamed, reparented, or removed.
   `ProbeTarget` still permits its required set/call surface, and reset now
   restores `process_mode` to `PROCESS_MODE_INHERIT`. Task 9 duplicate/rename
   coverage now uses runtime-created dedicated nodes; runtime-created
   reparent/remove behavior remains enabled.
3. A successful reset recovery restores the shared environment only for later
   tests, then raises `HarnessFailure` for the affected test with the original
   diagnostics and `recovery_succeeded: true`. Session teardown always checks
   one editor, at most three planned game starts, zero reset restarts, and zero
   recovery markers/events. Cleanup and budget failures are preserved together
   in an `ExceptionGroup`.

### TDD and verification evidence

- Harness RED: recovery returned success, file transport entered the direct
  file path, and no session-budget function existed.
- NodeOps RED: duplicate/rename/reparent/remove of `ProbeTarget` succeeded and
  its allowlisted set boundary was not separated from identity protection.
- Finalizer RED: `finalize_m3_session` was absent and could not report cleanup
  plus budget failures together.
- Original-diagnostics RED: recovery rebuilt diagnostics instead of retaining
  the originating `HarnessFailure.diagnostics`.

Final results:

```text
uv run pytest tests/e2e/m3/test_harness.py -v
10 passed

GODOT_BIN=Godot-v4.7.1 uv run pytest tests/e2e/test_gdscript_units.py -v
14 passed

GODOT_BIN=Godot-v4.7.1 uv run pytest \
  tests/e2e/m3/test_runtime_status.py tests/e2e/m3/test_runtime_nodes.py \
  -v --durations=20 --maxfail=1
25 passed

GODOT_BIN=Godot-v4.7.1 uv run pytest tests/e2e/m3/test_m3_contract.py \
  -k "runtime_manifest_match or runtime_manifest_has_no_aliases" -v
2 passed, 2 deselected; runtime route files = 35

uv run python -m py_compile tests/e2e/m3/conftest.py \
  tests/e2e/m3/test_harness.py tests/e2e/m3/test_runtime_nodes.py
exit 0
```

The exact Task 10 three-file command remains intentionally RED only at later
task boundaries: 27 passed / 9 failed across Task 11 input behavior and Task 13
log/debug behavior. No skip, xfail, direct HTTP fallback, or local operation
was added.

Fix round 1 is recorded by the commit containing this report.
