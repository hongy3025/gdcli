"""M2 E2E test fixtures — module-scoped editor with per-test reset."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

import pytest

from .helpers import (
    gdcli_bin,
    repo_root,
    require_godot_47,
    resolve_godot_bin,
    wait_for_godot_ready,
    wait_for_metadata,
)


def _gdcli_ping(env_root: Path, godot_bin: str) -> bool:
    """Quick ping via gdcli to confirm Godot is responding."""
    try:
        result = subprocess.run(
            [
                str(gdcli_bin()), "--json",
                "exec", "gdapi/health/ping",
                "--project", str(env_root),
            ],
            capture_output=True, encoding="utf-8", errors="replace",
            timeout=5,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


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
    fixture_root = Path(env["fixture_root"])
    shutil.copytree(fixture_root, project, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns(".godot"))
    subprocess.run(
        [str(env["gdcli"]), "--json", "exec", "project/stop", "--project", str(project)],
        capture_output=True, check=False,
    )
    subprocess.run(
        [str(env["gdcli"]), "--json", "exec", "scene/open",
         "--project", str(project),
         "--data", json.dumps({"scene_path": "res://main.tscn"})],
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
def m2_editor(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    root = repo_root()
    godot_bin = resolve_godot_bin()
    require_godot_47(godot_bin)

    build = subprocess.run(
        ["cargo", "build", "--workspace"],
        cwd=root, capture_output=True, encoding="utf-8", errors="replace",
    )
    if build.returncode != 0:
        pytest.skip(f"cargo build failed:\n{build.stderr}")

    fixture_root = root / "tests" / "fixtures" / "m2_project"
    base = tmp_path_factory.mktemp("m2") / "project"
    shutil.copytree(fixture_root, base)

    install = subprocess.run(
        [str(gdcli_bin()), "install", "--project", str(base), "--force"],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    if install.returncode != 0:
        pytest.fail(f"gdcli install failed:\n{install.stderr}")

    godot_dir = base / ".godot"
    godot_dir.mkdir(exist_ok=True)
    (godot_dir / "gdapi.json").unlink(missing_ok=True)
    godot_log_handle = (godot_dir / "godot.log").open("w", encoding="utf-8")

    godot = subprocess.Popen(
        [godot_bin, "--editor", "--headless", "--path", str(base)],
        stdout=godot_log_handle, stderr=subprocess.STDOUT, text=True,
    )

    try:
        meta = wait_for_metadata(base)
    except Exception:
        godot.terminate()
        godot.wait(timeout=10)
        godot_log_handle.close()
        raise

    deadline = time.time() + 60.0
    ready = False
    last_error = ""
    while time.time() < deadline:
        if godot.poll() is not None:
            godot_log_handle.close()
            raise RuntimeError(f"godot exited prematurely with code {godot.returncode}")
        if _gdcli_ping(base, godot_bin):
            ready = True
            break
        time.sleep(1.0)

    if not ready:
        godot.terminate()
        godot.wait(timeout=10)
        godot_log_handle.close()
        raise RuntimeError(f"gdapi ping never succeeded within 60s: {last_error}")

    wait_for_godot_ready(base)

    env = {
        "root": root,
        "fixture_root": fixture_root,
        "project": base,
        "godot": godot,
        "godot_log": godot_log_handle,
        "godot_bin": godot_bin,
        "meta": meta,
        "gdcli": gdcli_bin(),
    }

    try:
        yield env
    finally:
        godot.terminate()
        try:
            godot.wait(timeout=10)
        except subprocess.TimeoutExpired:
            godot.kill()
        godot_log_handle.close()


@pytest.fixture(autouse=True)
def isolated_test_state(m2_editor):
    before = project_snapshot(Path(m2_editor["project"]))
    yield
    reset_project_state(m2_editor)
    after = project_snapshot(Path(m2_editor["project"]))
    assert after == before, "M2 project state changed after test"
