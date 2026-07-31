# Task 10 report — DELETE force removal

## Status
Complete for the assigned narrow scope: DELETE policy/force handling only. The broader `capability_policy` subsystem was intentionally left unchanged because the assignment target and parent-agent direction explicitly limit this task to deletion routes/services.

## Changes
- `gdapi/addon/routes/filesystem/batch/delete.gd`
  - Centralized result sending in `_send` with `ErrorCodes.http_status(result.code)`.
  - Preserved dry-run/plan-hash safety and audit summary without any `force` field.
- `gdapi/addon/routes/resource/delete.gd`
  - No request-body `force` read or service pass-through.
  - Added `_send` with `ErrorCodes.http_status(result.code)`.
  - Documentation contains no force parameter, wording, or example field.
- `gdapi/addon/routes/node/delete.gd`
  - Added `ErrorCodes` and centralized `_send` status mapping.
  - No force read/pass-through/documentation.
- `gdapi/addon/runtime/services/resource_editor.gd`
  - Resource deletion now validates through `PathGuard.validate(path, "delete")`, so protected paths use delete-mode safety rules rather than a force fallback.
- `gdapi/addon/runtime/services/bulk_file_service.gd`
  - Confirmed batch deletion already uses `PathGuard.validate(..., "delete")` and has no force gate.
- Node deletion service has no force enforcement; no service change was required.

## Verification
- `python scripts/format-gd.py` — passed.
- `python scripts/format-gd.py --check` — passed.
- `gdlint gdapi/addon/routes/filesystem/batch/delete.gd gdapi/addon/routes/resource/delete.gd gdapi/addon/routes/node/delete.gd gdapi/addon/runtime/services/resource_editor.gd` — passed.
- `git diff --check` — passed.
- `cargo test --workspace` — 202 tests passed (10 suites).
- `GODOT_BIN=D:/app/devel/Godot/v4.7.1/godot_console.exe uv run pytest tests/e2e/m2/ tests/e2e/m4/ -q` — 85 passed.
- `GODOT_BIN=D:/app/devel/Godot/v4.7.1/godot_console.exe uv run pytest tests/e2e/m6/test_bulk_files.py -q` — 4 passed.
- Targeted grep over DELETE routes/services found no `force` or `require_force` remnants.

## Concerns
The checked-in `.superpowers/sdd/task-10-brief.md` describes deletion of the entire capability-policy subsystem and has verification commands unrelated to the explicit DELETE-only assignment. Those broader deletions were not performed to honor the target and parent-agent scope.
