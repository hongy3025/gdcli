# Task B5: E2E for Bulk File Transactional Semantics

## Status: Complete

## Files Changed

| File | Change |
|------|--------|
| `gdapi/addon/runtime/services/bulk_file_service.gd` | Added `_debug_fail_after()` debug injection support for testing rollback behavior |
| `tests/e2e/m6/conftest.py` | Added 7 helpers: `replace_plan`, `apply_replace`, `inject_apply_failure`, `bulk_digest`, `delete_plan`, `apply_delete`, `project_file`; added `m6_editor_bulk` fixture with `bulk_files` capability enabled |
| `tests/e2e/m6/test_bulk_files.py` | New file with 4 tests covering replace dry-run/apply, rollback on failure, stale plan conflict, and delete/recover/uid lifecycle |
| `tests/fixtures/m6_project/bulk/a.txt.uid` | Added fixture uid file for delete/recover test |
| `tests/fixtures/m6_project/bulk/b.txt.uid` | Added fixture uid file |

## Test Results

```
tests/e2e/m6/test_bulk_files.py::test_replace_dry_run_then_apply      PASSED
tests/e2e/m6/test_bulk_files.py::test_replace_rolls_back_when_second_apply_fails PASSED
tests/e2e/m6/test_bulk_files.py::test_stale_plan_returns_conflict     PASSED
tests/e2e/m6/test_bulk_files.py::test_delete_recover_restores_uid_and_is_not_repeatable PASSED
```

All 4 M6 contract tests for `filesystem/batch/*` routes also pass (default-deny enforcement unchanged).

## Design Decisions

1. **Separate fixture**: Used `m6_editor_bulk` (with `bulk_files: {enabled: true}`) instead of modifying the base `m6_editor` fixture, avoiding regression in `test_m6_route_is_default_deny`.

2. **Debug injection**: Added `_debug_fail_after()` to `bulk_file_service.gd` — reads a sentinel file at `res://.gdapi-debug-apply-fail`. The `inject_apply_failure` helper writes this file via `filesystem/write`. Not under `res://.godot/` because that path is write-protected by `PathGuard`.

3. **apply helpers store original params**: `replace_plan` stores `root`/`find`/`replace` in `plan["_root"]` etc., so `apply_replace` can pass them back. The service re-scans on apply; without the original params it defaults to `root="res://"` and `find=""` which returns `invalid_param`.

4. **Test isolation**: `test_replace_dry_run_then_apply` restores file state (reverse replace) so subsequent tests see the original fixture content.

## Commits

- `test: cover bulk file transactional semantics`

## Concerns

None. All tests pass, no regressions in M6 contract tests.
