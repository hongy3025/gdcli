"""Measure the child full file session from its parent's monotonic wall clock."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

from e2e.timing import positive_seconds

pytestmark = pytest.mark.budget


def run_budget_session(root: Path, report_path: Path) -> float:
    budget = positive_seconds("GDAPI_E2E_BUDGET_SECONDS")
    command = [
        sys.executable, "-m", "pytest", "tests/e2e/", "-q", "-s",
        "--durations=20", "-m", "not budget and not engine_transport and not real_renderer",
        "--ignore", "tests/e2e/test_full_suite_budget.py",
    ]
    environment = os.environ.copy()
    environment.update(GDAPI_E2E_TRANSPORT="file", GDAPI_E2E_EDITOR_MODE="headless", GDAPI_E2E_TIMING_JSON=str(report_path))
    started = time.monotonic()
    try:
        result = subprocess.run(
            command, cwd=root, env=environment, capture_output=True,
            encoding="utf-8", errors="replace", timeout=budget + 30,
        )
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(f"full file session exceeded parent deadline {budget + 30:g}s (budget {budget:g}s)") from exc
    elapsed = time.monotonic() - started
    assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads(report_path.read_text(encoding="utf-8"))
    assert report["editor_starts"] == 1, report
    assert report["exitstatus"] == 0, report
    assert elapsed <= budget, f"full file session parent wall-clock {elapsed:.3f}s exceeds GDAPI_E2E_BUDGET_SECONDS={budget:g}s"
    return elapsed


def test_full_suite_under_budget():
    root = Path(__file__).resolve().parents[2]
    # Separate child artifact: the parent session must not overwrite its measurements.
    report_path = Path(os.environ.get(
        "GDAPI_E2E_BUDGET_TIMING_JSON", str(root / ".pytest-artifacts/budget-file-waits.json")
    )).resolve()
    elapsed = run_budget_session(root, report_path)
    budget_path = Path(os.environ.get(
        "GDAPI_E2E_BUDGET_JSON", str(root / ".pytest-artifacts/budget.json")
    )).resolve()
    budget_path.parent.mkdir(parents=True, exist_ok=True)
    budget_path.write_text(json.dumps({
        "parent_wall_clock_seconds": elapsed,
        "budget_seconds": positive_seconds("GDAPI_E2E_BUDGET_SECONDS"),
        "child_timing_json": str(report_path),
    }, indent=2) + "\n", encoding="utf-8")
    print(f"FULL_SUITE_PARENT_WALL_SECONDS={elapsed:.3f}")
