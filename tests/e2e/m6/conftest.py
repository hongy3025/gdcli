from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

_TESTS_DIR = Path(__file__).resolve().parents[2]
if str(_TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(_TESTS_DIR))

from e2e.m2.helpers import gdcli_bin, repo_root, require_godot_47, resolve_godot_bin
from e2e.m3.conftest import attach_editor, command_doc, exec_error, exec_ok, detach_editor

M6_FIXTURE_SOURCE = repo_root() / "tests" / "fixtures" / "m6_project"


@pytest.fixture(scope="module")
def m6_editor(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    godot_bin = resolve_godot_bin()
    require_godot_47(godot_bin)
    project = tmp_path_factory.mktemp("m6_editor") / "project"
    shutil.copytree(M6_FIXTURE_SOURCE, project)
    install = subprocess.run(
        [str(gdcli_bin()), "install", "--project", str(project), "--force"],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    assert install.returncode == 0, install.stderr
    log_path = project / ".godot" / "godot.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_handle = log_path.open("w", encoding="utf-8")
    env: dict[str, Any] = {"project": project, "godot_bin": godot_bin,
                            "gdcli": gdcli_bin(), "godot_log": log_handle,
                            "godot_log_path": log_path}
    godot, meta = attach_editor(project, godot_bin, log_handle)
    env.update({"godot": godot, "meta": meta})
    try:
        yield env
    finally:
        detach_editor(env)
        log_handle.close()


__all__ = ["command_doc", "exec_error", "exec_ok", "m6_editor"]
