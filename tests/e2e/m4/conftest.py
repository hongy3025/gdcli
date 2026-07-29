"""Isolated M4 editor fixture and common command helpers."""

from __future__ import annotations

import shutil
import sys
from pathlib import Path
from typing import Any

import pytest

_THIS_DIR = Path(__file__).resolve().parent
_REPO_ROOT = _THIS_DIR.parent.parent.parent
_TESTS_DIR = _REPO_ROOT / "tests"
if str(_TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(_TESTS_DIR))

from e2e.m3.conftest import (
    attach_editor,
    command_doc,
    detach_editor,
    exec_error,
    exec_ok,
    gdcli_bin,
    repo_root,
    require_godot_47,
    resolve_godot_bin,
)


M4_FIXTURE_SOURCE = repo_root() / "tests" / "fixtures" / "m4_project"


@pytest.fixture()
def m4_env(tmp_path: Path) -> dict[str, Any]:
    """Run one editor against a private M4 fixture copy."""
    godot_bin = resolve_godot_bin()
    require_godot_47(godot_bin)
    project = tmp_path / "project"
    shutil.copytree(M4_FIXTURE_SOURCE, project)
    install = __import__("subprocess").run(
        [str(gdcli_bin()), "install", "--project", str(project), "--force"],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    assert install.returncode == 0, install.stderr
    godot_dir = project / ".godot"
    godot_dir.mkdir(exist_ok=True)
    log_handle = (godot_dir / "godot.log").open("w", encoding="utf-8")
    env: dict[str, Any] = {
        "project": project,
        "gdcli": gdcli_bin(),
        "godot_log": log_handle,
        "godot_log_path": godot_dir / "godot.log",
        "game_attached": False,
    }
    godot, meta = attach_editor(project, godot_bin, log_handle)
    env.update({"godot": godot, "meta": meta})
    try:
        yield env
    finally:
        detach_editor(env)


__all__ = ["command_doc", "exec_error", "exec_ok"]
