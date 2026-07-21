"""Real editor UndoRedo acceptance test using a fixture-only plugin."""

import os
import shutil
import subprocess
import sys
from pathlib import Path

from conftest import _repo_root, _gdcli_bin, require_godot_47


def _copy_native_library(root: Path, project: Path) -> None:
    if sys.platform == "win32":
        source = root / "target" / "debug" / "gdapi.dll"
        destination = project / "addons" / "gdapi" / "bin" / "windows" / "gdapi.dll"
    elif sys.platform == "darwin":
        source = root / "target" / "debug" / "libgdapi.dylib"
        destination = project / "addons" / "gdapi" / "bin" / "macos" / "libgdapi.dylib"
    else:
        source = root / "target" / "debug" / "libgdapi.so"
        destination = project / "addons" / "gdapi" / "bin" / "linux" / "libgdapi.so"
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def _isolated_project(tmp_path: Path) -> Path:
    root = _repo_root()
    build = subprocess.run(
        ["cargo", "build", "--workspace"],
        cwd=root,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    assert build.returncode == 0, build.stdout + build.stderr
    source = root / "tests" / "fixture_project"
    project = tmp_path / "fixture_project"
    shutil.copytree(
        source,
        project,
        ignore=shutil.ignore_patterns(".godot", "gdapi"),
    )
    install = subprocess.run(
        [str(_gdcli_bin()), "install", "--project", str(project), "--force"],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    assert install.returncode == 0, install.stdout + install.stderr
    _copy_native_library(root, project)
    return project


def test_real_editor_undo_redo(tmp_path):
    godot_bin = os.environ.get("GODOT_BIN", "godot")
    require_godot_47(godot_bin)
    project = _isolated_project(tmp_path)
    process_env = os.environ.copy()
    process_env["GDAPI_RUN_EDITOR_TESTS"] = "1"
    result = subprocess.run(
        [godot_bin, "--editor", "--headless", "--path", str(project)],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        env=process_env,
        timeout=45,
    )
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "GDAPI_EDITOR_TEST_PASS" in output