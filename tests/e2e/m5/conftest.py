from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any
from uuid import uuid4

import pytest

_TESTS_DIR = Path(__file__).resolve().parents[2]
if str(_TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(_TESTS_DIR))

from e2e.m3.conftest import command_doc, exec_error, exec_ok  # noqa: E402,F401
from e2e.shared_fixture import m5_editor as shared_m5_editor  # noqa: E402

EXPORT_CLI_TIMEOUT = 180


@pytest.fixture()
def m5_editor(shared_m5_editor: dict[str, Any]) -> dict[str, Any]:
    """Use the ongoing editor/project without restoring unrelated state."""
    return shared_m5_editor


@pytest.fixture()
def uid_workspace(m5_editor):
    """Create resources owned by one UID scenario, not a project baseline."""
    work = Path(m5_editor["project"]) / "uid_cases" / uuid4().hex
    work.mkdir(parents=True)
    try:
        yield work
    finally:
        shutil.rmtree(work)


def exec_export(env: dict[str, Any], route: str, data: dict | None = None) -> dict[str, Any]:
    import json
    args = ["exec", route, "--project", str(env["project"])]
    if data is not None:
        args += ["--data", json.dumps(data)]
    result = subprocess.run(
        [str(env["gdcli"]), "--json", *args, "--timeout", str(EXPORT_CLI_TIMEOUT)],
        capture_output=True, encoding="utf-8", errors="replace",
        timeout=EXPORT_CLI_TIMEOUT,
    )
    if result.returncode != 0:
        from e2e.m3.conftest import _harness_failure, _command_args
        raise _harness_failure(env, _command_args(env, route, data), result, f"{route}: expected success")
    payload = json.loads(result.stdout)
    assert payload.get("ok") is True, f"{route}: {payload}"
    return payload


@pytest.fixture()
def read_only_project_file(m5_editor: dict[str, Any]):
    path = Path(m5_editor["project"]) / "project.godot"
    mode = path.stat().st_mode
    path.chmod(mode & ~0o222)
    try:
        yield path
    finally:
        path.chmod(mode)


__all__ = [
    "command_doc",
    "exec_error",
    "exec_export",
    "exec_ok",
    "m5_editor",
    "read_only_project_file",
    "uid_workspace",
]
