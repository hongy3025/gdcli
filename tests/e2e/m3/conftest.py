"""M3 E2E fixtures — runtime probe lifecycle helpers."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path
from typing import Any

import pytest

# Allow importing tests.e2e.m2.helpers regardless of pytest testpath setup.
_THIS_DIR = Path(__file__).resolve().parent
_REPO_ROOT_CANDIDATE = _THIS_DIR.parent.parent
_TESTS_DIR = _THIS_DIR.parent
if str(_REPO_ROOT_CANDIDATE) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT_CANDIDATE))
if str(_TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(_TESTS_DIR))

from e2e.m2.helpers import (  # noqa: E402
    copy_native_library,
    gdcli_exec,
    gdcli_bin,
    repo_root,
    require_godot_47,
    resolve_godot_bin,
    tree_digest,
    wait_for_godot_ready,
    wait_for_metadata,
)

M3_FIXTURE_SOURCE = repo_root() / "tests" / "fixtures" / "m3_project"


def _gdcli_ping(env_root: Path, godot_bin: str) -> bool:
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


def _wait_for(predicate, timeout: float, interval: float = 0.2) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if predicate():
                return True
        except Exception:
            pass
        time.sleep(interval)
    return False


@pytest.fixture
def m3_editor(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    """Create an isolated Godot editor for M3 tests, preloaded with m3_project."""
    root = repo_root()
    godot_bin = resolve_godot_bin()
    require_godot_47(godot_bin)

    build = subprocess.run(
        ["cargo", "build", "--workspace"],
        cwd=root, capture_output=True, encoding="utf-8", errors="replace",
    )
    if build.returncode != 0:
        pytest.skip(f"cargo build failed:\n{build.stderr}")

    base = tmp_path_factory.mktemp("m3_editor") / "project"
    shutil.copytree(M3_FIXTURE_SOURCE, base)

    install = subprocess.run(
        [str(gdcli_bin()), "install", "--project", str(base), "--force"],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    if install.returncode != 0:
        pytest.fail(f"gdcli install failed:\n{install.stderr}")

    godot_dir = base / ".godot"
    godot_dir.mkdir(exist_ok=True)
    (godot_dir / "gdapi.json").unlink(missing_ok=True)
    log_handle = (godot_dir / "godot.log").open("w", encoding="utf-8")

    godot = subprocess.Popen(
        [godot_bin, "--editor", "--headless", "--path", str(base)],
        stdout=log_handle, stderr=subprocess.STDOUT, text=True,
    )

    try:
        meta = wait_for_metadata(base)
    except Exception:
        godot.terminate()
        godot.wait(timeout=10)
        log_handle.close()
        raise

    deadline = time.time() + 60.0
    ready = False
    while time.time() < deadline:
        if godot.poll() is not None:
            log_handle.close()
            raise RuntimeError(f"godot exited prematurely: code {godot.returncode}")
        if _gdcli_ping(base, godot_bin):
            ready = True
            break
        time.sleep(1.0)

    if not ready:
        godot.terminate()
        godot.wait(timeout=10)
        log_handle.close()
        raise RuntimeError("gdapi ping never succeeded")

    wait_for_godot_ready(base)

    env = {
        "root": root,
        "project": base,
        "godot": godot,
        "godot_log": log_handle,
        "godot_bin": godot_bin,
        "meta": meta,
        "gdcli": gdcli_bin(),
        "snapshot_digest": tree_digest(base),
    }

    try:
        yield env
    finally:
        godot.terminate()
        try:
            godot.wait(timeout=10)
        except subprocess.TimeoutExpired:
            godot.kill()
        log_handle.close()


@pytest.fixture
def m3_running(m3_editor: dict[str, Any]) -> Any:
    """Run fixture scene and yield env; tear down by stopping the game."""
    project_run(m3_editor)
    wait_for_connected(m3_editor, timeout=15.0)
    try:
        yield m3_editor
    finally:
        try:
            project_stop(m3_editor)
        except Exception:
            pass
        wait_stopped(m3_editor, timeout=10.0)
        if exec_ok(m3_editor, "runtime/status").get("pending", 0) > 0:
            raise RuntimeError("runtime requests are still pending after stop")


def project_run(env: dict) -> dict:
    """Start the fixture scene via project/run."""
    return exec_ok(env, "project/run")


def project_stop(env: dict) -> dict:
    """Stop the running game via project/stop."""
    return exec_ok(env, "project/stop")


def exec_ok(env: dict, route: str, data: dict | None = None) -> dict[str, Any]:
    args = ["exec", route, "--project", str(env["project"])]
    if data is not None:
        args += ["--data", json.dumps(data)]
    result = subprocess.run(
        [str(env["gdcli"]), "--json", *args],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    if result.returncode != 0:
        print("\n[gdcli failed]", args)
        print("STDOUT:", result.stdout)
        print("STDERR:", result.stderr)
    payload = json.loads(result.stdout)
    assert payload.get("ok") is True, f"{route}: {payload}"
    return payload


def exec_error(env: dict, route: str, data: dict | None = None) -> dict[str, Any]:
    args = ["exec", route, "--project", str(env["project"])]
    if data is not None:
        args += ["--data", json.dumps(data)]
    result = gdcli_exec(env, *args, check=False)
    assert result.returncode != 0, f"expected failure: {route}"
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        try:
            return json.loads(result.stderr.split(": ", 1)[1])
        except Exception:
            return {"code": "unknown", "error": result.stderr or result.stdout}


def command_doc(env: dict, route: str) -> dict[str, Any]:
    result = gdcli_exec(env, "exec", "command/doc", route, "--project", str(env["project"]))
    payload = json.loads(result.stdout)
    assert payload.get("ok") is True, f"command/doc {route}: {payload}"
    return payload["doc"]


def wait_for_connected(env: dict, timeout: float = 30.0) -> None:
    """Wait for runtime probe to reach connected state via either file or EngineDebugger transport.

    M3.1: 默认 30s,既覆盖 250ms hello delay + game startup,又允许 file transport
    在 headless harness 跑通。返回前确认 transport 字段合法。
    """
    deadline = time.time() + timeout
    last_status: dict = {}
    while time.time() < deadline:
        try:
            last_status = exec_ok(env, "runtime/status")
            if last_status.get("state") == "connected":
                if last_status.get("transport") in ("file", "engine_debugger"):
                    return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError(
        f"runtime probe never reached connected state within {timeout}s "
        f"(last status: {last_status})"
    )


def wait_stopped(env: dict, timeout: float = 10.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            status = exec_ok(env, "runtime/status")
            if status.get("state") == "stopped" and status.get("pending", 0) == 0:
                return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError("runtime broker did not return to stopped state")


def runtime_counter(env: dict, name: str) -> int:
    """Read a counter integer from /root/RuntimeMain/ProbeTarget via runtime/node/get."""
    payload = exec_ok(env, "runtime/node/get", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "property": name,
    })
    value = payload.get("value", {})
    if isinstance(value, dict) and value.get("plain") is not None:
        return int(value["plain"])
    if isinstance(value, dict) and "value" in value:
        return int(value["value"])
    return int(value) if not isinstance(value, dict) else 0


def wait_for(predicate, timeout: float = 5.0, interval: float = 0.05) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(interval)
    raise AssertionError("predicate never became true within timeout")
