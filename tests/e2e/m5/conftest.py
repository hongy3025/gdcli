from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

import pytest

_TESTS_DIR = Path(__file__).resolve().parents[2]
if str(_TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(_TESTS_DIR))

from e2e.m2.helpers import gdcli_bin, repo_root, resolve_godot_bin, tree_digest  # noqa: E402
from e2e.m3.conftest import command_doc, exec_error, exec_ok  # noqa: E402,F401
from e2e.shared_fixture import reset_shared_state, restore_file_state  # noqa: E402
from e2e.shared_fixture import m5_editor as shared_m5_editor  # noqa: E402

M5_FIXTURE_SOURCE = repo_root() / "tests" / "fixtures" / "m5_project"
EXPORT_CLI_TIMEOUT = 180
SNAPSHOT_NAMES = ("project.godot", "export_presets.cfg", "default_bus_layout.tres")


def _snapshot_paths(project: Path) -> list[Path]:
    paths = [project / name for name in SNAPSHOT_NAMES]
    paths.extend(sorted((project / "fixtures").glob("*.gd")))
    paths.extend(sorted(project.rglob("*.uid")))
    return [path for path in paths if path.is_file()]


def project_snapshot(env: dict[str, Any]) -> dict[str, str]:
    project = Path(env["project"])
    return {
        str(path.relative_to(project)).replace("\\", "/"): path.read_bytes().hex()
        for path in _snapshot_paths(project)
    }


def restore_snapshot(env: dict[str, Any]) -> None:
    """Restore M5 files captured when the shared fixture entered the test."""
    project = Path(env["project"])
    before: dict[str, str] = env["m5_file_baseline"]
    current = {
        str(path.relative_to(project)).replace("\\", "/"): path
        for path in _snapshot_paths(project)
    }
    for relative, path in current.items():
        if relative not in before:
            path.unlink(missing_ok=True)
    for relative, encoded in before.items():
        destination = project / Path(relative)
        if relative in current and current[relative].read_bytes().hex() == encoded:
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".m5-restore-", dir=destination.parent)
        os.close(fd)
        temporary_path = Path(temporary)
        try:
            temporary_path.write_bytes(bytes.fromhex(encoded))
            os.replace(temporary_path, destination)
        finally:
            temporary_path.unlink(missing_ok=True)

@pytest.fixture()
def m5_editor(shared_m5_editor: dict[str, Any]):
    """Return the session editor while restoring M5 file state per test."""
    reset_shared_state(shared_m5_editor, reason="m5 setup")
    shared_m5_editor["source_fixture"] = M5_FIXTURE_SOURCE
    shared_m5_editor["source_digest"] = tree_digest(M5_FIXTURE_SOURCE)
    shared_m5_editor["m5_file_baseline"] = project_snapshot(shared_m5_editor)
    try:
        yield shared_m5_editor
    finally:
        restore_snapshot(shared_m5_editor)


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


def assert_snapshot_restored(env: dict[str, Any], before: dict[str, str]) -> None:
    assert project_snapshot(env) == before


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
    "assert_snapshot_restored",
    "command_doc",
    "exec_error",
    "exec_export",
    "exec_ok",
    "m5_editor",
    "project_snapshot",
    "read_only_project_file",
    "restore_snapshot",
    "tree_digest",
]
