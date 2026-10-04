# M3 Runtime Remediation — Closure Report

**Date**: 2026-07-29
**Status**: Closed
**Scope**: M3 runtime remediation — Godot runtime/eval, runtime_probe, runtime_route, dispatch audit, transport probes, and the M3 E2E fixture (`tests/e2e/m3/`).

## Plan source

> **Note**: `docs/superpowers/plans/2026-07-29-gdcli-m3-runtime-remediation.md` is missing from the repo. `git log --all -- '*m3*runtime*'` confirms no commit on `feat/full-capability` ever added the plan file. The historical commit `b3cc2e6 docs: remove historical handoffs, papers, and milestone docs` (2026-07-30) cleaned up milestone docs across the tree. This report is therefore based on **code + test review on 2026-08-01** plus the per-task reports stored in `.superpowers/sdd/task-*-report.md` that drove the M3 stack at the time.

## Scope recap

The M3 milestone added the in-editor runtime interrogation path:

- `runtime/eval` route → `runtime_probe.gd::eval` → `EvalService.execute(source, inputs)` (v2 protocol only).
- `runtime/status` (broker fallback hardening — later in Task 7).
- `runtime_route.gd::dispatch` carrying the `public_route` argument and the public-route-name audit convention (later expanded in Task 1).
- M3 E2E suite under `tests/e2e/m3/` plus shared transport fixtures.

## Acceptance evidence

### E2E (Task 13 verification, 2026-08-01)

```
$ GODOT_BIN=D:/app/devel/Godot/v4.7.1/godot_console.exe \
    uv run pytest tests/e2e/test_m1_smoke.py tests/e2e/m2/ tests/e2e/m3/ tests/e2e/m4/ -q
223 passed; 0 failed.
```

The M3 slice (`tests/e2e/m3/`) is part of this 223-passed run. The M3 collection exercises
the runtime/eval route, runtime_probe, and the runtime transport file probe — all green.
The historical per-task report (Task 1) noted one pre-existing flake on
`test_runtime_transport_file_probe.gd`; that flake is environment-sensitive (transport
timeouts on a busy machine) and is not a regression of the M3 work.

### Rust

```
$ cargo test --workspace
202 tests pass across 10 suites; 0 failed
```

### GDScript tooling

```
$ python scripts/format-gd.py
gdformat completed for 571 GDScript files.
$ gdlint <m3 scope>
Success: no problems found
```

### Route manifest

`gdapi/routes` and `tests/e2e/route_manifests.py` agree on the M3 route count (35 routes in the M1/M2/M3 surface; detailed in roadmap).

## Findings from 2026-08-01 review

1. **M3 plan file is genuinely missing** — no `docs/superpowers/plans/2026-07-29-gdcli-m3-runtime-remediation.md` track exists. The closest artifact is the original M3 brief which was not committed to `docs/`. This is documented in this report rather than reconstructed — re-creating a historical plan to attach this report would inverse the cleanup intent of `b3cc2e6`.
2. **`runtime/eval` audit naming** — fixed in Task 1 (`runtime_route.gd` `_complete`/`_reject` now carries `public_route`; the public route `runtime/eval` is what the audit log records, not the internal `eval` op name). See commit `72829d2` and follow-up `a937e67`.
3. **Runtime transport timeout flake** — `test_runtime_transport_file_probe.gd` was observed failing on a busy runner during Task 1 verification; reproducible on the baseline before any M3-related edits. Pre-existing, not a regression of the M3 work. Documented in `.superpowers/sdd/task-1-report.md`.

## Known leftovers / follow-up

- `runtime/eval` is v2-protocol-only; v1 callers receive `conflict`. This is by design and matches the M3 spec.
- The M3 fixture adds `AnimationPlayer` and `HTTPRequest` nodes to the test scene (commit `aff1c6e test: add AnimationPlayer/HTTPRequest nodes to fixture test scene`) — these are now part of the baseline and unrelated to the M3 closure.
- No outstanding M3 tickets remain open on the `feat/full-capability` branch as of 2026-08-01.

## Summary

M3 runtime remediation is functionally complete: 223/223 E2E tests green (M3 slice included), 202/202 Rust tests pass, GDScript tooling clean. The historical plan file is gone with the rest of milestone docs but the code and tests deliver the contract. Follow-up audit-name and runtime-eval fixes were integrated through Task 1 of the 2026-08-01 plan.
