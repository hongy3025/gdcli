"""M3 E2E fixtures — runtime probe lifecycle helpers."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import time
import warnings
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
    gdcli_bin,
    repo_root,
    require_godot_47,
    resolve_godot_bin,
    tree_digest,
    wait_for_godot_ready,
)

M3_FIXTURE_SOURCE = repo_root() / "tests" / "fixtures" / "m3_project"
CLI_TIMEOUT_SECONDS = 35
RECOVERY_RESTART_LIMIT = 1
DIAGNOSTIC_FIELDS = (
    "command",
    "exit_code",
    "stdout",
    "stderr",
    "runtime_status",
    "godot_log_tail",
)


def runtime_route_source(route: str) -> str:
    """Read a runtime route from the addon source tree for source-contract checks."""
    route_path = repo_root() / "gdapi" / "addon" / "routes" / Path(*route.split("/"))
    return route_path.with_suffix(".gd").read_text(encoding="utf-8")


def _gdcli_ping(env_root: Path, godot_bin: str) -> bool:
    try:
        result = subprocess.run(
            [
                str(gdcli_bin()), "--json",
                "exec", "gdapi/health/ping",
                "--project", str(env_root),
            ],
            capture_output=True, encoding="utf-8", errors="replace",
            timeout=CLI_TIMEOUT_SECONDS,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


def _wait_for(predicate, timeout: float, interval: float = 0.2) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if predicate():
                return True
        except Exception:
            pass
        time.sleep(interval)
    return False


def _read_metadata(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def _runtime_root(env: dict[str, Any]) -> Path:
    project = Path(env["project"]).resolve()
    root = (project / ".godot" / "gdapi_runtime").resolve()
    if root.parent != (project / ".godot").resolve() or root.name != "gdapi_runtime":
        raise RuntimeError(f"unexpected runtime root: {root}")
    return root


def cleanup_stale_runtime(env: dict[str, Any]) -> None:
    """Remove only the fixture's known runtime transport root."""
    runtime_root = _runtime_root(env)
    if runtime_root.exists():
        shutil.rmtree(runtime_root)


def _runtime_entries(env: dict[str, Any]) -> list[str]:
    root = _runtime_root(env)
    if not root.exists():
        return []
    return sorted(path.name for path in root.iterdir())


def _record_editor_use(env: dict[str, Any]) -> None:
    godot = env.get("godot")
    if godot is not None and godot.poll() is None:
        env.setdefault("editor_pids", set()).add(godot.pid)


def _command_args(env: dict[str, Any], route: str, data: dict | None) -> list[str]:
    args = ["exec", route, "--project", str(env["project"])]
    if data is not None:
        args += ["--data", json.dumps(data)]
    return args


def _run_cli(
    env: dict[str, Any], args: list[str], *, timeout: float = CLI_TIMEOUT_SECONDS
) -> subprocess.CompletedProcess[str]:
    _record_editor_use(env)
    command = [str(env["gdcli"]), "--json", *args]
    try:
        return subprocess.run(
            command,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout if isinstance(exc.stdout, str) else ""
        stderr = exc.stderr if isinstance(exc.stderr, str) else ""
        return subprocess.CompletedProcess(
            command,
            124,
            stdout=stdout,
            stderr=f"gdcli timed out after {timeout:.1f}s\n{stderr}",
        )
    except OSError as exc:
        return subprocess.CompletedProcess(command, 127, stdout="", stderr=str(exc))


def _read_log_tail(env: dict[str, Any], lines: int = 80) -> str:
    log_path = Path(env.get("godot_log_path", ""))
    if not log_path:
        return "<Godot log path unavailable>"
    try:
        log_handle = env.get("godot_log")
        if log_handle is not None:
            log_handle.flush()
        content = log_path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return f"<unable to read Godot log: {exc}>"
    return "\n".join(content.splitlines()[-lines:])


def _parse_payload(result: subprocess.CompletedProcess[str]) -> dict[str, Any] | None:
    candidates = [result.stdout, result.stderr]
    for raw in candidates:
        if not raw:
            continue
        for candidate in (raw.strip(), raw.split(": ", 1)[-1].strip()):
            try:
                payload = json.loads(candidate)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict):
                return payload
    return None


def _runtime_status_snapshot(env: dict[str, Any], failed_args: list[str]) -> Any:
    if failed_args[:2] == ["exec", "runtime/status"]:
        return {"error": "runtime/status itself failed"}
    status_args = ["exec", "runtime/status", "--project", str(env["project"])]
    status = _run_cli(env, status_args, timeout=5.0)
    payload = _parse_payload(status)
    if payload is not None:
        return payload
    return {
        "exit_code": status.returncode,
        "stdout": status.stdout,
        "stderr": status.stderr,
    }


def _diagnostics(
    env: dict[str, Any], args: list[str], result: subprocess.CompletedProcess[str]
) -> dict[str, Any]:
    return {
        "command": [str(env["gdcli"]), "--json", *args],
        "exit_code": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "runtime_status": _runtime_status_snapshot(env, args),
        "godot_log_tail": _read_log_tail(env),
    }


def _format_diagnostics(diagnostics: dict[str, Any]) -> str:
    return json.dumps(diagnostics, ensure_ascii=False, indent=2, default=str)


def attach_editor(project: Path, godot_bin: str, log_handle) -> tuple[subprocess.Popen, dict[str, Any]]:
    """Start one headless editor and poll until metadata, ping, and layout are ready."""
    godot = subprocess.Popen(
        [godot_bin, "--editor", "--headless", "--path", str(project)],
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        text=True,
    )
    meta_path = project / ".godot" / "gdapi.json"

    try:
        meta = None
        deadline = time.monotonic() + 45.0
        while time.monotonic() < deadline:
            if godot.poll() is not None:
                raise RuntimeError(f"godot exited prematurely: code {godot.returncode}")
            meta = _read_metadata(meta_path)
            if meta is not None:
                break
            time.sleep(0.1)
        if meta is None:
            raise RuntimeError(f"gdapi metadata never appeared at {meta_path}")

        if not _wait_for(lambda: _gdcli_ping(project, godot_bin), timeout=60.0, interval=0.1):
            raise RuntimeError("gdapi ping never succeeded")
        wait_for_godot_ready(project)
        return godot, meta
    except BaseException:
        if godot.poll() is None:
            godot.terminate()
            try:
                godot.wait(timeout=10)
            except subprocess.TimeoutExpired:
                godot.kill()
                godot.wait(timeout=10)
        raise


def detach_editor(env: dict[str, Any]) -> None:
    """Stop game/editor ownership and close the session log without masking test errors."""
    game_error: BaseException | None = None
    if env.get("game_attached"):
        try:
            detach_game(env)
        except BaseException as exc:
            game_error = exc
            _record_recovery(env, "editor teardown", exc)
    godot = env.get("godot")
    if godot is not None and godot.poll() is None:
        godot.terminate()
        try:
            godot.wait(timeout=10)
        except subprocess.TimeoutExpired:
            godot.kill()
            godot.wait(timeout=10)
    try:
        cleanup_stale_runtime(env)
    except OSError as exc:
        _record_recovery(env, "stale runtime cleanup", exc)
    log_handle = env.get("godot_log")
    if log_handle is not None and not log_handle.closed:
        log_handle.close()
    if game_error is not None:
        return


@pytest.fixture(scope="session")
def m3_editor(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    """Build/install once and own one deterministic headless editor for the M3 session."""
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
    runtime_root = godot_dir / "gdapi_runtime"
    if runtime_root.exists():
        shutil.rmtree(runtime_root)
    log_handle = (godot_dir / "godot.log").open("w", encoding="utf-8")

    env = {
        "root": root,
        "project": base,
        "godot_log": log_handle,
        "godot_log_path": godot_dir / "godot.log",
        "godot_bin": godot_bin,
        "gdcli": gdcli_bin(),
        "snapshot_digest": tree_digest(base),
        "build_count": 1,
        "install_count": 1,
        "editor_start_count": 0,
        "editor_pids": set(),
        "game_run_count": 0,
        "game_stop_count": 0,
        "recovery_events": [],
        "game_attached": False,
    }

    try:
        godot, meta = attach_editor(base, godot_bin, log_handle)
        env["godot"] = godot
        env["meta"] = meta
        env["editor_start_count"] = 1
        env["editor_pid"] = godot.pid
        env["editor_pids"].add(godot.pid)
        yield env
    finally:
        detach_editor(env)


@pytest.fixture
def m3_running(m3_editor: dict[str, Any]) -> Any:
    """Attach one isolated game for a test and always detach it explicitly."""
    attach_game(m3_editor)
    original_error: BaseException | None = None
    try:
        yield m3_editor
    except BaseException as exc:
        original_error = exc
        raise
    finally:
        try:
            detach_game(m3_editor)
        except BaseException as cleanup_error:
            _record_recovery(m3_editor, "test cleanup", cleanup_error)
            if original_error is None:
                raise


@pytest.fixture
def m3_lifecycle(m3_editor: dict[str, Any]) -> dict[str, Any]:
    """Run the single status lifecycle scenario: initial stopped, then run/stop twice."""
    initial = exec_ok(m3_editor, "runtime/status")
    cycles: list[dict[str, Any]] = []
    scenario_error: BaseException | None = None
    try:
        for cycle in range(2):
            started = project_run(m3_editor)
            connected = wait_for_connected(m3_editor, timeout=30.0)
            active = exec_ok(m3_editor, "runtime/status")
            stopped = project_stop(m3_editor)
            stopped_status = wait_stopped(m3_editor, timeout=30.0)
            reset_fixture(m3_editor)
            cycles.append({
                "cycle": cycle,
                "started": started,
                "connected": connected,
                "active": active,
                "stopped": stopped,
                "stopped_status": stopped_status,
                "runtime_entries": _runtime_entries(m3_editor),
            })
    except BaseException as exc:
        scenario_error = exc
        raise
    finally:
        try:
            if m3_editor.get("game_attached"):
                detach_game(m3_editor)
            else:
                reset_fixture(m3_editor)
        except BaseException as cleanup_error:
            _record_recovery(m3_editor, "lifecycle cleanup", cleanup_error)
            if scenario_error is None:
                raise
    return {"initial": initial, "cycles": cycles}


def _record_recovery(env: dict[str, Any], phase: str, error: BaseException) -> None:
    message = f"M3 harness recovery ({phase}): {error}"
    env.setdefault("recovery_events", []).append(message)
    warnings.warn(message, RuntimeWarning, stacklevel=2)


def attach_game(env: dict[str, Any], *, recovery_restarts: int = RECOVERY_RESTART_LIMIT) -> None:
    """Start the game and retry readiness at most once after explicit cleanup."""
    last_error: BaseException | None = None
    for attempt in range(recovery_restarts + 1):
        try:
            project_run(env)
            wait_for_connected(env, timeout=30.0)
            env["game_attached"] = True
            return
        except BaseException as exc:
            last_error = exc
            try:
                detach_game(env)
            except BaseException as cleanup_error:
                _record_recovery(env, "readiness cleanup", cleanup_error)
            try:
                cleanup_stale_runtime(env)
            except BaseException as cleanup_error:
                _record_recovery(env, "readiness stale cleanup", cleanup_error)
            if attempt >= recovery_restarts:
                raise
            _record_recovery(env, f"readiness retry {attempt + 1}", exc)
    if last_error is not None:
        raise last_error


def detach_game(env: dict[str, Any]) -> None:
    """Stop the current game, wait for broker detachment, and remove stale transport files."""
    errors: list[BaseException] = []
    try:
        project_stop(env)
    except BaseException as exc:
        errors.append(exc)
    try:
        wait_stopped(env, timeout=15.0)
    except BaseException as exc:
        errors.append(exc)
    env["game_attached"] = False
    try:
        cleanup_stale_runtime(env)
    except BaseException as exc:
        errors.append(exc)
    if errors:
        raise RuntimeError("; ".join(str(error) for error in errors)) from errors[0]


def reset_fixture(env: dict[str, Any]) -> None:
    """Reset session-owned transport state; runtime node state stays game-isolated until Task 10."""
    try:
        status = exec_ok(env, "runtime/status")
    except BaseException:
        status = {"state": "unknown"}
    if status.get("state") != "stopped" or status.get("pending", 0) != 0:
        detach_game(env)
    cleanup_stale_runtime(env)
    entries = _runtime_entries(env)
    if entries:
        raise RuntimeError(f"stale runtime entries remain after reset: {entries}")


def project_run(env: dict) -> dict:
    """Start the fixture scene via project/run."""
    env["game_run_count"] += 1
    return exec_ok(env, "project/run")


def project_stop(env: dict) -> dict:
    """Stop the running game via project/stop."""
    env["game_stop_count"] += 1
    return exec_ok(env, "project/stop")


def exec_ok(env: dict, route: str, data: dict | None = None) -> dict[str, Any]:
    args = _command_args(env, route, data)
    result = _run_cli(env, args)
    if result.returncode != 0:
        diagnostics = _diagnostics(env, args, result)
        pytest.fail(
            f"{route}: expected success (exit {result.returncode})\n"
            f"diagnostics:\n{_format_diagnostics(diagnostics)}"
        )
    payload = _parse_payload(result)
    if payload is None or payload.get("ok") is not True:
        diagnostics = _diagnostics(env, args, result)
        pytest.fail(
            f"{route}: expected ok:true payload\n"
            f"diagnostics:\n{_format_diagnostics(diagnostics)}"
        )
    return payload


def exec_error(env: dict, route: str, data: dict | None = None) -> dict[str, Any]:
    args = _command_args(env, route, data)
    result = _run_cli(env, args)
    diagnostics = _diagnostics(env, args, result)
    if result.returncode == 0:
        pytest.fail(
            f"{route}: expected non-zero exit\n"
            f"diagnostics:\n{_format_diagnostics(diagnostics)}"
        )
    payload = _parse_payload(result) or {
        "code": "unknown",
        "error": result.stderr or result.stdout,
    }
    payload.setdefault("diagnostics", diagnostics)
    return payload


def command_doc(env: dict, route: str) -> dict[str, Any]:
    args = ["exec", "command/doc", route, "--project", str(env["project"])]
    result = _run_cli(env, args)
    payload = _parse_payload(result)
    if result.returncode != 0 or payload is None or payload.get("ok") is not True:
        diagnostics = _diagnostics(env, args, result)
        pytest.fail(
            f"command/doc {route}: expected ok:true payload\n"
            f"diagnostics:\n{_format_diagnostics(diagnostics)}"
        )
    return payload["doc"]


def wait_for_connected(env: dict, timeout: float = 30.0) -> dict[str, Any]:
    """Wait for runtime probe to reach connected state via either file or EngineDebugger transport.

    M3.1: 默认 30s,既覆盖 250ms hello delay + game startup,又允许 file transport
    在 headless harness 跑通。返回前确认 transport 字段合法。
    """
    deadline = time.monotonic() + timeout
    last_status: dict = {}
    while time.monotonic() < deadline:
        try:
            last_status = exec_ok(env, "runtime/status")
            if last_status.get("state") == "connected":
                if last_status.get("transport") in ("file", "engine_debugger"):
                    return last_status
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError(
        f"runtime probe never reached connected state within {timeout}s "
        f"(last status: {last_status})"
    )


def wait_stopped(env: dict, timeout: float = 10.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last_status: dict[str, Any] = {}
    while time.monotonic() < deadline:
        try:
            status = exec_ok(env, "runtime/status")
            last_status = status
            if status.get("state") == "stopped" and status.get("pending", 0) == 0:
                return status
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError(
        f"runtime broker did not return to stopped state: {last_status}"
    )


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
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(interval)
    raise AssertionError("predicate never became true within timeout")
