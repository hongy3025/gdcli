import subprocess
import sys
from pathlib import Path

BUDGET_SECONDS = 6 * 60


def test_full_suite_under_budget():
    root = Path(__file__).resolve().parents[2]
    cmd = [sys.executable, "-m", "pytest", "tests/e2e/", "-q", "--durations=20", "-x"]
    result = subprocess.run(cmd, cwd=root, capture_output=True, text=True, timeout=BUDGET_SECONDS + 30)
    assert result.returncode == 0, result.stdout + result.stderr
    tail = result.stdout.splitlines()[-10:]
    elapsed = next((float(t.split()[2]) for t in tail if t.startswith("=====")), None)
    assert elapsed is not None
    assert elapsed <= BUDGET_SECONDS, f"full suite took {elapsed:.1f}s, budget is {BUDGET_SECONDS}s"
