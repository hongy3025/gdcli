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


def _clear_undo_state(env: dict[str, Any]) -> None:
    from .helpers import editor_clear_undo
    try:
        editor_clear_undo(env)
    except Exception:
        pass


def _run_gdcli(env: dict[str, Any], *args: str, timeout: float = 10) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(env["gdcli"]), "--json", *args],
        capture_output=True, check=False, timeout=timeout,
    )


def _disconnect_all_signals(env: dict[str, Any]) -> None:
    """Disconnect all signal connections on /root/Main/Player and /root/Main/Target."""
    for node_path in ("/root/Main/Player", "/root/Main/Target"):
        result = _run_gdcli(env, "exec", "node/signal/list",
                            "--project", str(env["project"]),
                            "--data", json.dumps({"node_path": node_path}))
        if result.returncode != 0:
            continue
        try:
            payload = json.loads(result.stdout)
        except (json.JSONDecodeError, KeyError):
            continue
        if not payload.get("ok"):
            continue
        for conn in payload.get("connections", []):
            _run_gdcli(env, "exec", "node/signal/disconnect",
                       "--project", str(env["project"]),
                       "--data", json.dumps({
                           "source_path": f"{node_path}/{conn['source_node']}" if conn.get("source_node") else node_path,
                           "signal": conn["signal"],
                           "target_path": conn["target"],
                           "method": conn["method"],
                       }))


def reset_project_state(env: dict[str, Any]) -> None:
    project = Path(env["project"])
    fixture_root = Path(env["fixture_root"])
    shutil.copytree(fixture_root, project, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns(".godot"))
    _run_gdcli(env, "exec", "project/stop", "--project", str(project))
    # Never close/reopen scene — Godot auto-saves on close, which reintroduces
    # stale in-memory state. Instead, clean up in-memory state explicitly:
    _disconnect_all_signals(env)
    _clear_undo_state(env)
    _run_gdcli(env, "exec", "editor/selection/set", "--project", str(project),
               "--data", json.dumps({"nodes": []}))
    _run_gdcli(env, "exec", "gdapi/audit/clear", "--project", str(project),
               "--data", json.dumps({"force": True}))
    _run_gdcli(env, "install", "--project", str(project), "--force")


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
    yield
    reset_project_state(m2_editor)
