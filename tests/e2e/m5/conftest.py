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

from e2e.m2.helpers import gdcli_bin, repo_root, require_godot_47, resolve_godot_bin, tree_digest
from e2e.m3.conftest import attach_editor, command_doc, detach_editor, exec_error, exec_ok

M5_FIXTURE_SOURCE = repo_root() / "tests" / "fixtures" / "m5_project"
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
    project = Path(env["project"])
    before: dict[str, str] = env["initial_snapshot"]
    current = {
        str(path.relative_to(project)).replace("\\", "/"): path
        for path in _snapshot_paths(project)
    }
    for relative, path in current.items():
        if relative not in before:
            path.unlink(missing_ok=True)
    for relative, encoded in before.items():
        destination = project / Path(relative)
        destination.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".m5-restore-", dir=destination.parent)
        os.close(fd)
        temporary_path = Path(temporary)
        try:
            temporary_path.write_bytes(bytes.fromhex(encoded))
            os.replace(temporary_path, destination)
        finally:
            temporary_path.unlink(missing_ok=True)


def assert_snapshot_restored(env: dict[str, Any], before: dict[str, str]) -> None:
    assert project_snapshot(env) == before


@pytest.fixture()
def m5_editor(tmp_path: Path) -> dict[str, Any]:
    godot_bin = resolve_godot_bin()
    require_godot_47(godot_bin)
    project = tmp_path / "project"
    shutil.copytree(M5_FIXTURE_SOURCE, project)
    source_digest = tree_digest(M5_FIXTURE_SOURCE)
    install = subprocess.run(
        [str(gdcli_bin()), "install", "--project", str(project), "--force"],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    assert install.returncode == 0, install.stderr
    log_path = project / ".godot" / "godot.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_handle = log_path.open("w", encoding="utf-8")
    env: dict[str, Any] = {
        "project": project, "source_fixture": M5_FIXTURE_SOURCE,
        "source_digest": source_digest, "gdcli": gdcli_bin(),
        "godot_log": log_handle, "godot_log_path": log_path,
    }
    godot, meta = attach_editor(project, godot_bin, log_handle)
    env.update({"godot": godot, "meta": meta})
    env["initial_snapshot"] = project_snapshot(env)
    try:
        yield env
    finally:
        restore_snapshot(env)
        detach_editor(env)
        (Path(env["project"]) / ".godot" / "gdapi.json").unlink(missing_ok=True)


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
    "assert_snapshot_restored", "command_doc", "exec_error", "exec_ok",
    "m5_editor", "project_snapshot", "read_only_project_file", "restore_snapshot",
    "tree_digest",
]
