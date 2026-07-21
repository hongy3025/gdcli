"""M2 E2E test fixtures — isolated Godot editor per test."""

from __future__ import annotations

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


@pytest.fixture
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

    # Wait until the gdcli HTTP round-trip succeeds. Metadata appears before the
    # server becomes fully responsive so we need to actively probe.
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

    # Wait for EditorUndoRedoManager to be fully initialized before proceeding.
    # Writes (node/property/set, script/create, filesystem/write, etc.) hang if
    # called before the editor finishes loading its docks and layout.
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
