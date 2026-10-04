#!/usr/bin/env python3
"""Sequential gates. Full rerun: uv run python scripts/check.py

Select gates in fixed order (file, engine and render use independent editor sessions).
Budget reuses the file session's fresh parent measurement within this invocation;
on its own it runs the full suite. No concurrent pytest or hidden editor.
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

GATES = ("format", "clippy", "unit", "file", "engine", "render", "budget")


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
                    pytest + ["tests/e2e/test_gate_timing.py", "-m", "not budget and not engine_transport and not real_renderer"]]
    elif gate == "file":
        environment["GDAPI_E2E_TRANSPORT"] = "file"
        environment["GDAPI_E2E_EDITOR_MODE"] = "headless"
        commands = [pytest + ["tests/e2e/", "-m", "not budget and not engine_transport and not real_renderer", "-s", "--durations=20"]]
    elif gate == "engine":
        environment["GDAPI_E2E_TRANSPORT"] = "engine_debugger"
        environment["GDAPI_E2E_EDITOR_MODE"] = "headless"
        commands = [pytest + ["tests/e2e/m3/test_engine_transport.py", "-m", "engine_transport", "-s", "--durations=20"]]
    elif gate == "render":
        environment["GDAPI_E2E_TRANSPORT"] = "file"
        environment["GDAPI_E2E_EDITOR_MODE"] = "gui"
        commands = [
            pytest
            + [
                "tests/e2e/m2/test_spatial_particles.py::test_gridmap_library_cells_atomic_replace_undo_and_persistence",
                "tests/e2e/m2/test_spatial_particles.py::test_multimesh_instances_mesh_transform_color_custom_roundtrip",
                "-m",
                "real_renderer",
                "-s",
                "--durations=20",
            ]
        ]
    elif gate == "budget":
        environment["GDAPI_E2E_TRANSPORT"] = "file"
        environment["GDAPI_E2E_EDITOR_MODE"] = "headless"
        environment["GDAPI_E2E_BUDGET_TIMING_JSON"] = str(artifact_dir / "budget-file-waits.json")
        environment["GDAPI_E2E_BUDGET_JSON"] = str(artifact_dir / "budget.json")
        commands = [pytest + ["tests/e2e/test_full_suite_budget.py", "-m", "budget", "-s"]]
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
    file_wall_seconds: float | None = None
    for gate in GATES:
        if gate not in selected:
            continue
        if gate == "budget" and file_wall_seconds is not None:
            try:
                write_budget_report(
                    artifact_dir / "budget.json",
                    elapsed=file_wall_seconds,
                    child_report=artifact_dir / "file-waits.json",
                )
            except (AssertionError, OSError) as exc:
                print(f"[budget] {exc}", file=sys.stderr)
                return 1
            print(f"FULL_SUITE_PARENT_WALL_SECONDS={file_wall_seconds:.3f}", flush=True)
            continue
        for command, environment in gate_commands(gate, artifact_dir):
            report_path = Path(environment["GDAPI_E2E_TIMING_JSON"])
            if gate in ("file", "engine", "render"):
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
            if gate in ("file", "engine", "render"):
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
                if gate == "file":
                    file_wall_seconds = time.monotonic() - started
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
