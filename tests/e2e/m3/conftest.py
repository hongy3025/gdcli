"""M3 E2E fixtures — runtime probe helpers and the shared `m3_editor` alias.

The single Godot editor and unified project live in `tests/e2e/shared_fixture.py`,
re-exported through the root `tests/e2e/conftest.py` as `m3_editor` and friends.
The functions below are kept for M3's existing tests; they talk to the
shared editor through the env returned by the alias fixtures.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


# Allow importing tests.e2e.m2.helpers regardless of pytest testpath setup.
_THIS_DIR = Path(__file__).resolve().parent
_REPO_ROOT_CANDIDATE = _THIS_DIR.parent.parent
_TESTS_DIR = _THIS_DIR.parent
if str(_REPO_ROOT_CANDIDATE) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT_CANDIDATE))
if str(_TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(_TESTS_DIR))

from e2e.shared_fixture import m3_editor, m3_running, wait_for_scene  # noqa: E402,F401
from e2e.timing import positive_seconds, successful_wait

CLI_TIMEOUT_SECONDS = 35
DIAGNOSTIC_FIELDS = (
    "command",
    "exit_code",
    "stdout",
    "stderr",
    "runtime_status",
    "godot_log_tail",
)


class HarnessFailure(RuntimeError):
    """A harness failure that keeps the complete command/runtime/log evidence."""

    def __init__(self, message: str, diagnostics: dict[str, Any]):
        self.diagnostics = diagnostics
        super().__init__(f"{message}\ndiagnostics:\n{_format_diagnostics(diagnostics)}")






def _command_args(env: dict[str, Any], route: str, data: dict | None) -> list[str]:
    args = ["exec", route, "--project", str(env["project"])]
    if data is not None:
        args += ["--data", json.dumps(data)]
    return args


def _run_cli(
    env: dict[str, Any], args: list[str], *, timeout: float = CLI_TIMEOUT_SECONDS
) -> subprocess.CompletedProcess[str]:
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
    raw_log_path = env.get("godot_log_path")
    if raw_log_path is None:
        return "<Godot log path unavailable>"
    log_path = Path(raw_log_path)
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


def _runtime_status_snapshot(
    env: dict[str, Any],
    failed_args: list[str],
    failed_result: subprocess.CompletedProcess[str] | None = None,
) -> Any:
    if failed_args[:2] == ["exec", "runtime/status"]:
        if failed_result is not None:
            payload = _parse_payload(failed_result)
            if payload is not None:
                return payload
            return {
                "exit_code": failed_result.returncode,
                "stdout": failed_result.stdout,
                "stderr": failed_result.stderr,
            }
        return {"error": "runtime/status result unavailable"}
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
    diagnostics = {
        "command": [str(env.get("gdcli", "gdcli")), "--json", *args],
        "exit_code": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "runtime_status": _runtime_status_snapshot(env, args, result),
        "godot_log_tail": _read_log_tail(env),
    }
    env["last_diagnostics"] = diagnostics
    return diagnostics


def _format_diagnostics(diagnostics: dict[str, Any]) -> str:
    return json.dumps(diagnostics, ensure_ascii=False, indent=2, default=str)


def _harness_failure(
    env: dict[str, Any], args: list[str], result: subprocess.CompletedProcess[str], message: str
) -> HarnessFailure:
    return HarnessFailure(message, _diagnostics(env, args, result))


def attach_game(env: dict[str, Any]) -> None:
    """Start the real game once; readiness failures retain their diagnostics."""
    project_run(env)
    wait_for_editor_playing(env)
    wait_for_connected(env)


def ensure_running(env: dict[str, Any]) -> None:
    """Resume after an explicit stop, never recover an unexpectedly lost probe."""
    if not env.get("game_attached", False):
        attach_game(env)
        return
    status = exec_ok(env, "runtime/status")
    if status.get("state") != "connected":
        args = _command_args(env, "runtime/status", None)
        result = subprocess.CompletedProcess(
            [str(env["gdcli"]), "--json", *args], 0,
            stdout=json.dumps(status), stderr="",
        )
        raise _harness_failure(env, args, result, "running game lost runtime connection")


def detach_game(env: dict[str, Any]) -> dict[str, Any]:
    """Exercise the real stop and wait for broker detachment."""
    project_stop(env)
    return wait_stopped(env, timeout=15.0)




def project_run(env: dict) -> dict:
    """Start the fixture scene via project/run."""
    result = exec_ok(env, "project/run")
    env["game_run_count"] = int(env.get("game_run_count", 0)) + 1
    env["game_attached"] = True
    return result


def project_stop(env: dict) -> dict:
    """Stop the running game via project/stop."""
    result = exec_ok(env, "project/stop")
    env["game_stop_count"] = int(env.get("game_stop_count", 0)) + 1
    env["game_attached"] = False
    return result


def exec_ok(env: dict, route: str, data: dict | None = None, extra_args: list[str] | None = None) -> dict[str, Any]:
    args = _command_args(env, route, data)
    if extra_args:
        args.extend(extra_args)
    result = _run_cli(env, args)
    if result.returncode != 0:
        raise _harness_failure(
            env, args, result, f"{route}: expected success (exit {result.returncode})"
        )
    payload = _parse_payload(result)
    if payload is None or payload.get("ok") is not True:
        raise _harness_failure(
            env, args, result, f"{route}: expected ok:true payload"
        )
    if route == "scene/open" and isinstance(data, dict) and data.get("path"):
        # `scene/open` 由编辑器延迟生效：不等切换完成就继续，后续 mutation 会把
        # UndoRedo 绑到旧场景的 history（表现为 history.undo() 偶发返回 false）。
        expected = str(data["path"])
        if not wait_for_scene(env, expected):
            raise _harness_failure(
                env,
                args,
                result,
                f"scene/open: editor never switched to {expected}",
            )
    return payload


def exec_error(env: dict, route: str, data: dict | None = None, extra_args: list[str] | None = None) -> dict[str, Any]:
    args = _command_args(env, route, data)
    if extra_args:
        args.extend(extra_args)
    result = _run_cli(env, args)
    diagnostics = _diagnostics(env, args, result)
    if result.returncode == 0:
        raise HarnessFailure(
            f"{route}: expected non-zero exit", diagnostics
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
        raise HarnessFailure(
            f"command/doc {route}: expected ok:true payload",
            _diagnostics(env, args, result),
        )
    return payload["doc"]


def _poll_runtime_status(
    env: dict[str, Any]
) -> tuple[list[str], subprocess.CompletedProcess[str], dict[str, Any] | None]:
    args = ["exec", "runtime/status", "--project", str(env["project"])]
    result = _run_cli(env, args, timeout=5.0)
    payload = _parse_payload(result)
    if result.returncode != 0 or payload is None or payload.get("ok") is not True:
        raise _harness_failure(env, args, result, "runtime/status polling failed")
    return args, result, payload


@successful_wait("runtime_playing")
def wait_for_editor_playing(env: dict, timeout: float = 15.0) -> dict[str, Any]:
    timeout = positive_seconds("GDAPI_E2E_PLAY_TIMEOUT_SECONDS", timeout)
    deadline = time.monotonic() + timeout
    last_status: dict[str, Any] = {}
    last_args: list[str] = []
    last_result: subprocess.CompletedProcess[str] | None = None
    while time.monotonic() < deadline:
        last_args, last_result, payload = _poll_runtime_status(env)
        if payload is not None:
            last_status = payload
            if payload.get("ok") is True and payload.get("editor_playing") is True:
                return payload
        time.sleep(0.1)
    if last_result is None:
        last_args, last_result, _ = _poll_runtime_status(env)
    raise _harness_failure(
        env,
        last_args,
        last_result,
        f"editor never entered playing state within {timeout}s "
        f"(last status: {last_status})",
    )


@successful_wait("runtime_connect")
def wait_for_connected(env: dict, timeout: float = 60.0) -> dict[str, Any]:
    timeout = positive_seconds("GDAPI_E2E_CONNECT_TIMEOUT_SECONDS", timeout)
    deadline = time.monotonic() + timeout
    last_status: dict = {}
    last_args: list[str] = []
    last_result: subprocess.CompletedProcess[str] | None = None
    while time.monotonic() < deadline:
        last_args, last_result, payload = _poll_runtime_status(env)
        if payload is not None:
            last_status = payload
            if payload.get("ok") is True and payload.get("state") == "connected":
                if payload.get("transport") in ("file", "engine_debugger"):
                    return payload
        time.sleep(0.1)
    if last_result is None:
        last_args, last_result, _ = _poll_runtime_status(env)
    raise _harness_failure(
        env,
        last_args,
        last_result,
        f"runtime probe never reached connected state within {timeout}s "
        f"(last status: {last_status})",
    )


@successful_wait("runtime_stop")
def wait_stopped(env: dict, timeout: float = 10.0) -> dict[str, Any]:
    timeout = positive_seconds("GDAPI_E2E_STOP_TIMEOUT_SECONDS", timeout)
    deadline = time.monotonic() + timeout
    last_status: dict[str, Any] = {}
    last_args: list[str] = []
    last_result: subprocess.CompletedProcess[str] | None = None
    while time.monotonic() < deadline:
        last_args, last_result, payload = _poll_runtime_status(env)
        if payload is not None:
            last_status = payload
            if (
                payload.get("ok") is True
                and payload.get("state") == "stopped"
                and payload.get("pending", 0) == 0
                and not payload.get("editor_playing", True)
            ):
                return payload
        time.sleep(0.1)
    if last_result is None:
        last_args, last_result, _ = _poll_runtime_status(env)
    raise _harness_failure(
        env,
        last_args,
        last_result,
        f"runtime broker did not return to stopped state: {last_status}",
    )


def runtime_counter(env: dict, name: str) -> int:
    payload = exec_ok(env, "runtime/node/get", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "property": name,
    })
    value = payload["value"]
    if isinstance(value, dict) and "plain" in value:
        value = value["plain"]
    elif isinstance(value, dict) and "value" in value:
        value = value["value"]
    assert isinstance(value, (int, float)) and not isinstance(value, bool), payload
    return int(value)


@successful_wait("predicate")
def wait_for(predicate, timeout: float = 15.0, interval: float = 0.05) -> None:
    """Wait for observable game state; record only successful waits."""
    timeout = positive_seconds("GDAPI_E2E_WAIT_TIMEOUT_SECONDS", timeout)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(interval)
    raise AssertionError("predicate never became true within timeout")


