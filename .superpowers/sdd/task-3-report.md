# Task 3 Report

## Status
Complete.

## Commit
`fix(network): body_size_limit at download time; drop policy target allowlists` (final hash returned with task result)

## Files changed
- `gdapi/addon/runtime/services/network_target_guard.gd`
- `gdapi/addon/runtime/services/network_service.gd`
- `gdapi/addon/routes/network/http_request.gd`
- `tests/fixture_project/tests/test_network_target_guard.gd`
- `tests/fixtures/e2e_project/tests/test_network_target_guard.gd`
- `tests/e2e/m6/test_network_request.py`
- `tests/e2e/m6/conftest.py` (adds deterministic `Content-Length` for the `/large` response so Godot reports body-limit truncation at the download stage)

## Verification
- `python scripts/format-gd.py && python scripts/format-gd.py --check`: passed; 571 files formatted/checked.
- `gdlint gdapi/addon/runtime/services/network_target_guard.gd gdapi/addon/runtime/services/network_service.gd gdapi/addon/routes/network/http_request.gd tests/fixture_project/tests/test_network_target_guard.gd tests/fixtures/e2e_project/tests/test_network_target_guard.gd`: passed; no problems.
- `cargo test --workspace`: passed; 202 tests across 10 suites.
- `GODOT_BIN="D:/app/devel/Godot/v4.7.1/godot_console.exe" uv run pytest tests/e2e/m6/test_network_request.py -v`: 7 passed, 0 failed, 0 skipped.
- `GODOT_BIN="D:/app/devel/Godot/v4.7.1/godot_console.exe" uv run pytest tests/e2e/m6/ -q`: 41 passed, 0 failed, 2 skipped.

## Previously failing network tests now passing
The four Task 1 deferred network failures, represented by their rewritten test names, now pass:
- `test_network_request_unreachable_host`
- `test_network_request_redirect_is_followed`
- `test_redirect_loop_is_rejected`
- `test_response_cap_truncates_or_errors`

## Notes
Godot 4.7 exposes the body-limit result enum as `HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED` (value 7), not the brief's nonexistent `RESULT_BODY_SIZE_LIMIT_REACHED`; the implementation uses the actual engine constant while preserving the required behavior.

## Concerns
None.
