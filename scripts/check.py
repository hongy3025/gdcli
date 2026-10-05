#!/usr/bin/env python3
"""Sequential gates. Full rerun: uv run python scripts/check.py

The complete E2E suite uses one persistent editor, including EngineDebugger and
renderer scenarios. Budget accepts that same fresh parent measurement; selecting
budget alone schedules E2E once. No nested pytest or hidden editor session.
"""
from __future__ import annotations

import argparse
import os
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from e2e.timing import validate_configuration, write_budget_report  # noqa: E402

GATES = ("format", "clippy", "unit", "e2e", "budget")


def gate_commands(gate: str, artifact_dir: Path) -> list[tuple[list[str], dict[str, str]]]:
    python = sys.executable
    pytest = [python, "-m", "pytest"]
    environment = os.environ.copy()
    environment.pop("PYTEST_ADDOPTS", None)
    environment["GDAPI_E2E_TIMING_JSON"] = str(artifact_dir / f"{gate}-waits.json")
    if gate == "format":
        commands = [["cargo", "fmt", "--all", "--", "--check"],
                    [python, "scripts/format-gd.py", "--check"],
                    [python, "scripts/lint-gd.py"]]
    elif gate == "clippy":
        commands = [["cargo", "clippy", "--workspace", "--all-targets", "--", "-D", "warnings"]]
    elif gate == "unit":
        commands = [["cargo", "test", "--workspace"],
                    pytest + ["tests/e2e/test_gate_timing.py", "tests/e2e/test_version_gate.py"]]
    elif gate == "e2e":
        environment["GDAPI_E2E_TRANSPORT"] = "file"
        environment["GDAPI_E2E_EDITOR_MODE"] = "gui"
        commands = [pytest + [
            "tests/e2e/", "-s", "--durations=20",
            f"--junitxml={artifact_dir / 'e2e.xml'}",
        ]]
    else:
        raise ValueError(f"unknown gate {gate!r}")
    return [(command, environment) for command in commands]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate", action="append", choices=GATES)
    parser.add_argument("--artifact-dir", type=Path, default=Path(".pytest-artifacts"))
    args = parser.parse_args(argv)
    try:
        validate_configuration()
    except ValueError as exc:
        parser.error(str(exc))
    artifact_dir = args.artifact_dir.resolve()
    selected = set(args.gate or GATES)
    if "budget" in selected:
        selected.add("e2e")
    e2e_wall_seconds: float | None = None
    for gate in GATES:
        if gate not in selected:
            continue
        if gate == "budget":
            try:
                assert e2e_wall_seconds is not None, "budget requires fresh E2E evidence"
                write_budget_report(
                    artifact_dir / "budget.json",
                    elapsed=e2e_wall_seconds,
                    child_report=artifact_dir / "e2e-waits.json",
                )
            except (AssertionError, OSError) as exc:
                print(f"[budget] {exc}", file=sys.stderr)
                return 1
            continue
        for command, environment in gate_commands(gate, artifact_dir):
            report_path = Path(environment["GDAPI_E2E_TIMING_JSON"])
            if gate == "e2e":
                report_path.unlink(missing_ok=True)
            print(f"[{gate}] {subprocess.list2cmdline(command)}", flush=True)
            started = time.monotonic()
            try:
                result = subprocess.run(command, cwd=ROOT, env=environment)
            except OSError as exc:
                print(f"[{gate}] failed to launch: {exc}", file=sys.stderr)
                return 127
            if result.returncode:
                print(f"[{gate}] failed with exit code {result.returncode}", file=sys.stderr)
                return result.returncode if result.returncode > 0 else 1
            if gate == "e2e":
                try:
                    report = json.loads(report_path.read_text(encoding="utf-8"))
                    if report.get("editor_starts") != 1 or report.get("exitstatus") != 0:
                        raise ValueError("expected exactly one editor and a successful session")
                    if report.get("transport") != environment["GDAPI_E2E_TRANSPORT"]:
                        raise ValueError("session transport does not match gate")
                    if report.get("editor_mode") != environment["GDAPI_E2E_EDITOR_MODE"]:
                        raise ValueError("session editor mode does not match gate")
                except (OSError, ValueError) as exc:
                    print(f"[{gate}] invalid session evidence {report_path}: {exc}", file=sys.stderr)
                    return 1
                e2e_wall_seconds = time.monotonic() - started
                report["parent_wall_clock_seconds"] = e2e_wall_seconds
                report_path.write_text(
                    json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8",
                )
                print(f"FULL_SUITE_PARENT_WALL_SECONDS={e2e_wall_seconds:.3f}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
