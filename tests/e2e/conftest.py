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
import re
import shutil
import subprocess
import sys
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
    m3_lifecycle,
    m3_running,
    m4_env,
    m5_editor,
    m6_editor,
    m6_editor_bulk,
    m6_editor_eval,
    m6_editor_network,
    m6_editor_process,
    reset_shared_state,
    teardown_environment,
)


E2E_DEADLOCK_TIMEOUT_SECONDS = 180


def pytest_collection_modifyitems(items):
    """Bound deadlocks and reorder collected tests by wall-time bucket."""
    timeout_marker = pytest.mark.timeout(E2E_DEADLOCK_TIMEOUT_SECONDS)
    for item in items:
        if item.get_closest_marker("budget") is None:
            item.add_marker(timeout_marker)
    # Reorder the items in place by wall-time bucket so fast contract /
    # lightweight tests fire first and slow paths sit at the back. See
    # `tests/e2e/test_collection_order.py` for the contract.
    from e2e.shared_fixture import bucketize
    reordered = bucketize(list(items))
    items[:] = reordered


def parse_godot_version(output: str) -> tuple[int, int, int]:
    match = re.search(r"(?:v)?(\d+)\.(\d+)(?:\.(\d+))?", output)
    if match is None:
        raise RuntimeError(f"Godot 4.7.x is required; cannot parse version: {output!r}")
    return int(match.group(1)), int(match.group(2)), int(match.group(3) or 0)


def require_godot_47(godot_bin: str) -> tuple[int, int, int]:
    try:
        result = subprocess.run(
            [godot_bin, "--version"],
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"Godot 4.7.x is required: {exc}") from exc
    version = parse_godot_version(result.stdout or result.stderr)
    if version[:2] != (4, 7):
        raise RuntimeError(
            f"Godot 4.7.x is required; found {version[0]}.{version[1]}.{version[2]}"
        )
    return version


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent


def _gdcli_bin() -> Path:
    name = "gdcli.exe" if sys.platform == "win32" else "gdcli"
    return _repo_root() / "target" / "debug" / name


def _run_gdcli(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(_gdcli_bin()), "--json", *args],
        capture_output=True, encoding="utf-8", errors="replace",
    )


def _fixture_runtime_root(fixture: Path) -> Path:
    fixture = fixture.resolve()
    godot_dir = (fixture / ".godot").resolve()
    if godot_dir.parent != fixture or godot_dir.name != ".godot":
        raise RuntimeError(f"unexpected fixture metadata root: {godot_dir}")
    runtime_root = (godot_dir / "gdapi_runtime").resolve()
    if runtime_root.parent != godot_dir or runtime_root.name != "gdapi_runtime":
        raise RuntimeError(f"unexpected fixture runtime root: {runtime_root}")
    return runtime_root


def _cleanup_fixture_runtime(fixture: Path) -> None:
    runtime_root = _fixture_runtime_root(fixture)
    if runtime_root.exists():
        shutil.rmtree(runtime_root)


def _teardown_godot_fixture(godot: subprocess.Popen, fixture: Path) -> None:
    try:
        godot.terminate()
        try:
            godot.wait(timeout=10)
        except subprocess.TimeoutExpired:
            godot.kill()
            godot.wait(timeout=10)
    finally:
        _cleanup_fixture_runtime(fixture)


def gdcli_json(env: dict, *args: str) -> dict:
    """Run gdcli --json and return parsed response (legacy helper)."""
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


def run_godot_script(
    env: dict,
    script: str,
    *,
    editor: bool = False,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess:
    """Run a Godot GDScript test through --headless --script."""
    command = [env["godot_bin"], "--headless", "--path", str(env["project"])]
    if editor:
        command.append("--editor")
    command += ["--script", script]
    # Use isolated APPDATA/LOCALAPPDATA (same as the live editor) so that
    # Godot can write app_userdata without crashing (SIGSEGV on dir-creation
    # failure in headless mode).
    process_env = build_editor_environment(env["project"])
    process_env.update(extra_env or {})
    return subprocess.run(
        command,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        env=process_env,
        timeout=45,
    )
