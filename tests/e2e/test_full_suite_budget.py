import re
import subprocess
import sys
from pathlib import Path

import pytest


BUDGET_SECONDS = 6 * 60
pytestmark = [
    pytest.mark.budget,
    pytest.mark.timeout(BUDGET_SECONDS + 30),
]


def test_full_suite_under_budget():
    root = Path(__file__).resolve().parents[2]
    cmd = [
        sys.executable,
        "-m",
        "pytest",
        "tests/e2e/",
        "-q",
        "-s",
        "--durations=20",
        "-x",
        "--ignore",
        "tests/e2e/test_full_suite_budget.py",
    ]
    result = subprocess.run(cmd, cwd=root, capture_output=True, text=True, timeout=BUDGET_SECONDS + 30)
    assert result.returncode == 0, result.stdout + result.stderr
    # Verify exactly one editor start
    assert "GODOT_EDITOR_STARTS=1" in result.stdout, (
        f"expected GODOT_EDITOR_STARTS=1, got:\n{result.stdout}"
    )
    summary = next((t for t in result.stdout.splitlines() if t.startswith("=====") and " in " in t), "")
    match = re.search(r"\bin\s+([0-9]+(?:\.[0-9]+)?)s\b", summary)
    elapsed = float(match.group(1)) if match else None
    assert elapsed is not None
    assert elapsed <= BUDGET_SECONDS, f"full suite took {elapsed:.1f}s, budget is {BUDGET_SECONDS}s"
