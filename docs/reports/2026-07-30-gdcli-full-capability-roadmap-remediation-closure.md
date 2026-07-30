# gdcli Full-Capability Roadmap — Remediation Closure Report

**Date:** 2026-07-30
**HEAD commit:** `c596830` (plus 16 commits from this plan)
**Branch:** `feat/full-capability`
**Godot version:** 4.7.x
**Test command:** `uv run pytest tests/e2e/ -v --durations=30`

## Summary

| Metric | Value |
|---|---|
| Phases completed | A1–A3, B0–B5, C1–C2, D1–D3, E1–E3, E6 |
| Commits added | 16 |
| Rust tests | 202 passed, 0 failed |
| Clippy warnings | 0 |
| GDScript format | 538 files, clean |
| GDScript lint | 0 errors |

## Per-Phase Completion

### Phase A — Contract and Fixture Closure ✅
- **A1:** `test_runtime_manifest_has_no_aliases` rewritten to compare against `M3_RUNTIME_ROUTES | {"runtime/eval"}` instead of a bare count.
- **A2:** `tests/fixtures/m6_project/bulk/{a,b}.txt` created with minimal content.
- **A3:** M2/M5 smoke contracts now import route sets from `tests/e2e/route_manifests.py`.

### Phase B — M6 Safety and Audit Acceptance ✅
- **B0:** Deferred registry `_emit_terminal` now checks `"finish"` first with `"terminal"` fallback; all 3 producers use `"finish"`.
- **B1–B5:** 5 E2E test files created covering runtime eval, eval matrix, network guards, process run, and bulk file semantics. Conftest extended with local HTTP server, audit helpers, and per-capability fixtures.

### Phase C — M5 Final-State Acceptance ✅
- **C1:** Export preset changed from Linux to Windows platform; `exec_export` helper added with 180s timeout.
- **C2:** Android bridge already uses stable error codes (`not_found`, `godot_error`); no literal `"unknown"` remains.

### Phase D — E2E Duration Budget ✅
- **D1/D2:** M2 and M4 fixtures converted to `scope="module"` with `reset_project_state` autouse.
- **D3:** `tests/e2e/test_full_suite_budget.py` added (budget: 6 min).

### Phase E — Full Closure Run 🔶 (partial — E4/E5 need Godot runtime)
- **E1:** Clippy warning on `assert!(MAX_HEADER_BYTES < MAX_BODY)` resolved via `const _: () = assert!(...)`.
- **E2:** GDScript format + lint: 538 files clean.
- **E3:** Rust: 202/202 tests pass, 0 clippy warnings, fmt clean.
- **E6:** README, security doc, spec, status report updated; this closure report committed.
- **E4/E5:** (pending — require Godot 4.7 headless to execute E2E suites)

## Route Counts per Milestone (from `route_manifests.py`)

| Milestone | Routes |
|---|---|
| M3 (runtime) | 35 |
| M4 (game systems) | 51 |
| M5 (project, diagnostics, export) | 27 |
| M6 (high-risk) | 8 |

## Deferred Items (explicitly excluded)

- E4 (milestone suite green) — requires Godot runtime, no headless host available during authoring.
- E5 (single-command full E2E pass) — requires Godot runtime, depends on E4.
- C3 (full M5 suite run) — requires Godot runtime.

## Upstream Documents

- [Remediation closure plan](../superpowers/plans/2026-07-30-gdcli-remediation-closure-plan.md)
- [Full-capability roadmap design](../superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md)
- [Completion assessment](2026-07-30-gdcli-full-capability-roadmap-remediation-completion-assessment.md)
