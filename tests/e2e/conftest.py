"""E2E test fixtures — Godot editor lifecycle management.

The single Godot editor and unified project are owned by
`tests/e2e/shared_fixture.py`. The session-scoped `e2e_editor` fixture and
its module-scoped aliases (`m2_editor`, `m3_editor`, `m4_env`,
`m5_editor`, `m6_editor*`) are re-exported here so any test in the
`tests/e2e/` tree can request them by name.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

import pytest

import sys as _sys
from pathlib import Path as _P
_THIS_DIR = _P(__file__).resolve().parent
if str(_THIS_DIR.parent) not in _sys.path:
    _sys.path.insert(0, str(_THIS_DIR.parent))

from e2e.shared_fixture import (  # noqa: E402,F401 — re-export
    E2E_DEADLOCK_TIMEOUT_SECONDS,
    EDITOR_START_COUNTER,
    build_editor_environment,
    build_environment,
    e2e_editor,
    gdcli_call,
    gdcli_expect_failure,
    m2_editor,
    m3_editor,
    m3_running,
    m4_env,
    m5_editor,
    m6_editor,
    m6_editor_bulk,
    m6_editor_eval,
    m6_editor_network,
    m6_editor_process,
    teardown_environment,
)
from e2e.timing import (
    TIMINGS, positive_seconds, successful_wait, validate_configuration, write_report,
)
from e2e.m2.helpers import fixture_command

_CASE_REPORTS: dict[str, dict] = {}
_DESELECTED_CASES: list[str] = []
_SESSION_STARTED = 0.0


def pytest_configure(config):
    try:
        validate_configuration()
    except ValueError as exc:
        raise pytest.UsageError(str(exc)) from exc
    TIMINGS.samples.clear()
    TIMINGS.enabled = False

    _CASE_REPORTS.clear()
    _DESELECTED_CASES.clear()


def pytest_sessionstart(session):
    del session
    global _SESSION_STARTED
    _SESSION_STARTED = time.monotonic()


def pytest_deselected(items):
    _DESELECTED_CASES.extend(item.nodeid for item in items)


def pytest_runtest_logreport(report):
    row = _CASE_REPORTS.setdefault(
        report.nodeid,
        {"nodeid": report.nodeid, "status": "passed", "setup_seconds": 0.0,
         "call_seconds": 0.0, "teardown_seconds": 0.0},
    )
    row[f"{report.when}_seconds"] = report.duration
    row["total_seconds"] = sum(row[f"{phase}_seconds"] for phase in ("setup", "call", "teardown"))
    if report.failed:
        row["status"] = "failed"
    elif report.skipped and row["status"] != "failed":
        row["status"] = "skipped"


@pytest.hookimpl(tryfirst=True)
def pytest_runtest_setup(item):
    # Unit/mocked harness tests coexist with real E2E tests in the file session.
    # Only the actual shared-editor fixture closure supplies measured samples.
    TIMINGS.enabled = "e2e_editor" in item.fixturenames


def pytest_sessionfinish(session, exitstatus):
    path = Path(os.environ.get("GDAPI_E2E_TIMING_JSON", ".pytest-artifacts/wait-timings.json"))
    if not path.is_absolute():
        path = Path(session.config.rootpath) / path
    write_report(
        path, exitstatus=int(exitstatus), editor_starts=int(EDITOR_START_COUNTER["starts"]),
        cases=list(_CASE_REPORTS.values()), deselected=_DESELECTED_CASES,
        session_seconds=time.monotonic() - _SESSION_STARTED,
    )


def pytest_terminal_summary(terminalreporter):
    terminalreporter.section("Successful wait timings (seconds; recommendations only)")
    for group, row in TIMINGS.summary().items():
        terminalreporter.write_line(
            f"{group}: count={row['count']} P50={row['p50_seconds']:.4f} "
            f"P95={row['p95_seconds']:.4f} P99={row['p99_seconds']:.4f} "
            f"max={row['max_seconds']:.4f} P99*3={row['recommended_timeout_seconds']:.4f}"
        )
    terminalreporter.write_line(
        "JSON: " + os.environ.get("GDAPI_E2E_TIMING_JSON", ".pytest-artifacts/wait-timings.json")
    )


def pytest_collection_modifyitems(items):
    """Bound deadlocks and reorder collected tests by wall-time bucket."""
    timeout_marker = pytest.mark.timeout(positive_seconds("GDAPI_E2E_DEADLOCK_TIMEOUT_SECONDS"))
    for item in items:
        if item.get_closest_marker("budget") is None:
            item.add_marker(timeout_marker)
    # Reorder the items in place by wall-time bucket so fast contract /
    # lightweight tests fire first and slow paths sit at the back. See
    # `tests/e2e/test_collection_order.py` for the contract.
    from e2e.shared_fixture import bucketize
    reordered = bucketize(list(items))
    items[:] = reordered


def gdcli_json(env: dict, *args: str) -> dict:
    """Run the actual CLI and parse its JSON response."""
    result = subprocess.run(
        [str(env["gdcli"]), "--json", *args],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    if result.returncode != 0:
        raise AssertionError(
            f"gdcli returned {result.returncode}: {args}\n{result.stderr or result.stdout}"
        )
    return json.loads(result.stdout)


def gdcli_expect_fail(env: dict, *args: str) -> int:
    """Run gdcli and assert nonzero exit code. Returns the exit code."""
    result = subprocess.run(
        [str(env["gdcli"]), "--json", *args],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    assert result.returncode != 0, f"expected nonzero exit: {args}\n{result.stdout}"
    return result.returncode


@successful_wait("native_suite")
def run_native_suite(env: dict, script: str) -> dict:
    """Execute a native GDScript suite inside the already running editor."""
    return fixture_command(env, "run_suite", data={"path": script}, timeout=45.0)
