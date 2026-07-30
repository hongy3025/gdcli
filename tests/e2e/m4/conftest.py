"""Isolated M4 editor fixture — module-scoped with per-test reset."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
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


def project_snapshot(project: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(project.rglob("*")):
        if not path.is_file():
            continue
        rel = str(path.relative_to(project)).replace("\\", "/")
        if rel.startswith(".godot/") or rel.startswith("addons/gdapi/bin/"):
            continue
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def reset_project_state(env: dict[str, Any]) -> None:
    project = Path(env["project"])
    shutil.copytree(M4_FIXTURE_SOURCE, project, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns(".godot"))
    subprocess.run(
        [str(env["gdcli"]), "--json", "exec", "project/stop", "--project", str(project)],
        capture_output=True, check=False,
    )
    subprocess.run(
        [str(env["gdcli"]), "--json", "exec", "editor/selection/set",
         "--project", str(project), "--data", json.dumps({"nodes": []})],
        capture_output=True, check=False,
    )
    subprocess.run(
        [str(env["gdcli"]), "--json", "exec", "gdapi/audit/clear",
         "--project", str(project), "--data", json.dumps({"force": True})],
        capture_output=True, check=False,
    )
    subprocess.run(
        [str(env["gdcli"]), "install", "--project", str(project), "--force"],
        capture_output=True, check=False,
    )


@pytest.fixture(scope="module")
def m4_env(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    """Module-scoped editor for all M4 tests."""
    godot_bin = resolve_godot_bin()
    require_godot_47(godot_bin)
    project = tmp_path_factory.mktemp("m4") / "project"
    shutil.copytree(M4_FIXTURE_SOURCE, project)
    install = subprocess.run(
        [str(gdcli_bin()), "install", "--project", str(project), "--force"],
        capture_output=True, encoding="utf-8", errors="replace",
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


@pytest.fixture(autouse=True)
def isolated_test_state(m4_env):
    yield
    reset_project_state(m4_env)


__all__ = ["command_doc", "exec_error", "exec_ok"]
