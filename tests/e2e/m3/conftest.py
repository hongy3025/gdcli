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


class HarnessFailure(RuntimeError):
    """A harness failure that keeps the complete command/runtime/log evidence."""

    def __init__(self, message: str, diagnostics: dict[str, Any]):
        self.diagnostics = diagnostics
        super().__init__(f"{message}\ndiagnostics:\n{_format_diagnostics(diagnostics)}")


def runtime_route_source(route: str) -> str:
    """Read a runtime route from the addon source tree for source-contract checks."""
    route_path = repo_root() / "gdapi" / "addon" / "routes" / Path(*route.split("/"))
    return route_path.with_suffix(".gd").read_text(encoding="utf-8")


def fixture_script_source(name: str) -> str:
    """Read one checked-in M3 fixture script for narrow reset source contracts."""
    if Path(name).name != name or not name.endswith(".gd"):
        raise ValueError(f"invalid fixture script name: {name}")
    return (M3_FIXTURE_SOURCE / "scripts" / name).read_text(encoding="utf-8")


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


def _fixture_hook_reset_once(env: dict[str, Any]) -> dict[str, Any]:
    """Reset through the broker-owned node/call route for every transport."""
    call = exec_ok(env, "runtime/node/call", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "method": "reset_shared_fixture",
        "args": [],
    })
    if call.get("method") != "reset_shared_fixture":
        raise RuntimeError(f"fixture reset hook method mismatch: {call}")
    result = call.get("result", {})
    if not isinstance(result, dict) or result.get("changed") is not True:
        raise RuntimeError(f"fixture reset hook returned invalid result: {call}")
    return {"ok": True, **result}


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


def attach_editor(
    project: Path, godot_bin: str, log_handle, *, on_start=None
) -> tuple[subprocess.Popen, dict[str, Any]]:
    """Start one headless editor and poll until metadata, ping, and layout are ready."""
    godot = subprocess.Popen(
        [godot_bin, "--editor", "--headless", "--path", str(project)],
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if on_start is not None:
        on_start()
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
    if env.get("game_attached"):
        for attempt in range(2):
            try:
                detach_game(env)
                break
            except BaseException as exc:
                _record_recovery(env, f"editor teardown attempt {attempt + 1}", exc)
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
    except BaseException as exc:
        _record_recovery(env, "stale runtime cleanup", exc)
    log_handle = env.get("godot_log")
    if log_handle is not None and not log_handle.closed:
        log_handle.close()


def assert_session_budget(env: dict[str, Any]) -> None:
    """Enforce process and recovery budgets after all M3 tests have run."""
    violations = []
    editor_starts = int(env.get("editor_start_count", 0))
    game_starts = int(env.get("game_run_count", 0))
    reset_restarts = int(env.get("fixture_reset_restarts", 0))
    recovery_markers = env.get("recovery_markers", [])
    recovery_events = env.get("recovery_events", [])
    if editor_starts != 1:
        violations.append(f"editor starts: expected 1, got {editor_starts}")
    if game_starts > 3:
        violations.append(f"game starts: expected at most 3, got {game_starts}")
    if reset_restarts != 0:
        violations.append(f"fixture reset restarts: expected 0, got {reset_restarts}")
    if recovery_markers:
        violations.append(f"recovery markers: {recovery_markers}")
    if recovery_events:
        violations.append(f"recovery events: {recovery_events}")
    if violations:
        raise AssertionError("M3 session budget violated: " + "; ".join(violations))


def finalize_m3_session(env: dict[str, Any]) -> None:
    """Run cleanup and budget checks without replacing either failure."""
    errors = []
    try:
        detach_editor(env)
    except BaseException as exc:
        errors.append(exc)
    try:
        assert_session_budget(env)
    except BaseException as exc:
        errors.append(exc)
    if len(errors) == 1:
        raise errors[0]
    if errors:
        raise ExceptionGroup("M3 session teardown failures", errors)


@pytest.fixture(scope="session")
def m3_editor(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    """Build/install once and own one deterministic headless editor for the M3 session."""
    root = repo_root()
    godot_bin = resolve_godot_bin()
    require_godot_47(godot_bin)

    setup_events: list[str] = []
    build = subprocess.run(
        ["cargo", "build", "--workspace"],
        cwd=root, capture_output=True, encoding="utf-8", errors="replace",
    )
    if build.returncode != 0:
        pytest.skip(f"cargo build failed:\n{build.stderr}")
    setup_events.append("build")

    base = tmp_path_factory.mktemp("m3_editor") / "project"
    shutil.copytree(M3_FIXTURE_SOURCE, base)

    install = subprocess.run(
        [str(gdcli_bin()), "install", "--project", str(base), "--force"],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    if install.returncode != 0:
        pytest.fail(f"gdcli install failed:\n{install.stderr}")
    setup_events.append("install")

    godot_dir = base / ".godot"
    godot_dir.mkdir(exist_ok=True)
    (godot_dir / "gdapi.json").unlink(missing_ok=True)
    runtime_root = godot_dir / "gdapi_runtime"
    if runtime_root.exists():
        shutil.rmtree(runtime_root)
    stale_before_attach = runtime_root / "stale-before-attach" / "outbox" / "reply.json"
    stale_before_attach.parent.mkdir(parents=True, exist_ok=True)
    stale_before_attach.write_text("stale", encoding="utf-8")
    pre_attach_env = {"project": base}
    cleanup_stale_runtime(pre_attach_env)
    log_handle = (godot_dir / "godot.log").open("w", encoding="utf-8")

    env = {
        "root": root,
        "project": base,
        "godot_log": log_handle,
        "godot_log_path": godot_dir / "godot.log",
        "godot_bin": godot_bin,
        "gdcli": gdcli_bin(),
        "snapshot_digest": tree_digest(base),
        "build_count": setup_events.count("build"),
        "install_count": setup_events.count("install"),
        "editor_start_count": 0,
        "setup_events": setup_events,
        "pre_attach_stale_removed": not runtime_root.exists(),
        "editor_pids": set(),
        "game_run_count": 0,
        "game_stop_count": 0,
        "fixture_reset_count": 0,
        "fixture_reset_restarts": 0,
        "recovery_markers": [],
        "recovery_events": [],
        "game_attached": False,
    }

    def record_editor_start() -> None:
        env["editor_start_count"] += 1
        env["setup_events"].append("editor_start")

    try:
        godot, meta = attach_editor(
            base, godot_bin, log_handle, on_start=record_editor_start
        )
        env["godot"] = godot
        env["meta"] = meta
        env["editor_start_count"] = 1
        env["editor_pid"] = godot.pid
        env["editor_pids"].add(godot.pid)
        yield env
    finally:
        finalize_m3_session(env)


@pytest.fixture(scope="session")
def m3_running(m3_editor: dict[str, Any], m3_lifecycle: dict[str, Any]) -> Any:
    """Own one shared data-plane game for all fixture-state E2E tests."""
    assert len(m3_lifecycle["cycles"]) == 2
    attach_game(m3_editor)
    try:
        yield m3_editor
    finally:
        if m3_editor.get("game_attached"):
            detach_game(m3_editor)


@pytest.fixture(autouse=True)
def reset_shared_m3_data_plane(request: pytest.FixtureRequest):
    """Reset the shared game before each test that requests m3_running."""
    if "m3_running" in request.fixturenames:
        env = request.getfixturevalue("m3_running")
        reset_fixture(env)
    yield


@pytest.fixture(scope="session")
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
            stale = (
                _runtime_root(m3_editor)
                / f"stale-lifecycle-{cycle}"
                / "reply.json"
            )
            stale.parent.mkdir(parents=True, exist_ok=True)
            stale.write_text("stale", encoding="utf-8")
            stopped_status = detach_game(m3_editor)
            stopped = {"ok": True, "runtime_state": stopped_status["state"]}
            cycles.append({
                "cycle": cycle,
                "started": started,
                "connected": connected,
                "active": active,
                "stopped": stopped,
                "stopped_status": stopped_status,
                "runtime_entries": _runtime_entries(m3_editor),
                "stale_removed": not stale.exists(),
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
    diagnostics = getattr(error, "diagnostics", None)
    if not isinstance(diagnostics, dict):
        diagnostics = env.get("last_diagnostics")
    if not isinstance(diagnostics, dict):
        fallback_args = ["exec", "runtime/status", "--project", str(env.get("project", ""))]
        fallback_result = subprocess.CompletedProcess(
            [str(env.get("gdcli", "gdcli")), "--json", *fallback_args],
            1,
            stdout="",
            stderr=str(error),
        )
        diagnostics = _diagnostics(env, fallback_args, fallback_result)
    message = (
        f"M3 harness recovery ({phase}): {error}\n"
        f"diagnostics:\n{_format_diagnostics(diagnostics)}"
    )
    env["last_recovery_diagnostics"] = diagnostics
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


def detach_game(env: dict[str, Any]) -> dict[str, Any] | None:
    """Stop the current game, wait for broker detachment, and remove stale transport files."""
    errors: list[BaseException] = []
    stopped_status: dict[str, Any] | None = None
    try:
        project_stop(env)
    except BaseException as exc:
        errors.append(exc)
    try:
        stopped_status = wait_stopped(env, timeout=15.0)
    except BaseException as exc:
        errors.append(exc)
    try:
        cleanup_stale_runtime(env)
    except BaseException as exc:
        errors.append(exc)
    if errors:
        diagnostics = next(
            (
                getattr(error, "diagnostics")
                for error in errors
                if isinstance(getattr(error, "diagnostics", None), dict)
            ),
            None,
        )
        if diagnostics is None:
            fallback_args = ["exec", "project/stop", "--project", str(env["project"])]
            fallback_result = subprocess.CompletedProcess(
                [str(env.get("gdcli", "gdcli")), "--json", *fallback_args],
                1,
                stdout="",
                stderr="; ".join(str(error) for error in errors),
            )
            diagnostics = _diagnostics(env, fallback_args, fallback_result)
        raise HarnessFailure("game teardown failed", diagnostics) from errors[0]
    env["game_attached"] = False
    return stopped_status


def reset_fixture(env: dict[str, Any]) -> dict[str, Any]:
    """Reset known fixture state without restarting the shared data-plane game."""
    if not env.get("game_attached", False):
        status = exec_ok(env, "runtime/status")
        if status.get("state") != "stopped" or status.get("pending", 0) != 0:
            return detach_game(env)
        cleanup_stale_runtime(env)
        entries = _runtime_entries(env)
        if entries:
            raise RuntimeError(f"stale runtime entries remain after reset: {entries}")
        return status

    try:
        exec_ok(env, "runtime/status")
        result = _fixture_hook_reset_once(env)
        env["fixture_reset_count"] = int(env.get("fixture_reset_count", 0)) + 1
        return result
    except BaseException as original_error:
        args = ["exec", "runtime/fixture/reset", "--project", str(env["project"])]
        original_diagnostics = getattr(original_error, "diagnostics", None)
        if isinstance(original_diagnostics, dict):
            diagnostics = dict(original_diagnostics)
        else:
            failed = subprocess.CompletedProcess(
                [str(env.get("gdcli", "gdcli")), "--json", *args],
                1,
                stdout="",
                stderr=str(original_error),
            )
            diagnostics = _diagnostics(env, args, failed)
        diagnostics["recovery_marker"] = {
            "operation": "runtime/fixture/reset",
            "restart_allowed": RECOVERY_RESTART_LIMIT,
            "original_error": str(original_error),
        }
        env["last_reset_diagnostics"] = diagnostics
        env.setdefault("recovery_markers", []).append(diagnostics["recovery_marker"])
        _record_recovery(env, "fixture reset failed; preserving original diagnostics", original_error)
        env["fixture_reset_restarts"] = int(env.get("fixture_reset_restarts", 0)) + 1
        detach_game(env)
        attach_game(env, recovery_restarts=0)
        try:
            exec_ok(env, "runtime/status")
            _fixture_hook_reset_once(env)
            env["fixture_reset_count"] = int(env.get("fixture_reset_count", 0)) + 1
            diagnostics["recovery_succeeded"] = True
            raise HarnessFailure(
                "fixture reset failed; environment recovered for later tests",
                diagnostics,
            ) from original_error
        except BaseException as recovery_error:
            if (
                isinstance(recovery_error, HarnessFailure)
                and diagnostics.get("recovery_succeeded") is True
            ):
                raise
            diagnostics["recovery_error"] = str(recovery_error)
            raise HarnessFailure("fixture reset recovery failed", diagnostics) from recovery_error


def project_run(env: dict) -> dict:
    """Start the fixture scene via project/run."""
    result = exec_ok(env, "project/run")
    env["game_run_count"] += 1
    return result


def project_stop(env: dict) -> dict:
    """Stop the running game via project/stop."""
    result = exec_ok(env, "project/stop")
    env["game_stop_count"] += 1
    return result


def exec_ok(env: dict, route: str, data: dict | None = None) -> dict[str, Any]:
    args = _command_args(env, route, data)
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
    return payload


def exec_error(env: dict, route: str, data: dict | None = None) -> dict[str, Any]:
    args = _command_args(env, route, data)
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
    return args, result, _parse_payload(result)


def wait_for_connected(env: dict, timeout: float = 30.0) -> dict[str, Any]:
    """Wait for runtime probe to reach connected state via either file or EngineDebugger transport.

    M3.1: 默认 30s,既覆盖 250ms hello delay + game startup,又允许 file transport
    在 headless harness 跑通。返回前确认 transport 字段合法。
    """
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


def wait_stopped(env: dict, timeout: float = 10.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last_status: dict[str, Any] = {}
    last_args: list[str] = []
    last_result: subprocess.CompletedProcess[str] | None = None
    while time.monotonic() < deadline:
        last_args, last_result, payload = _poll_runtime_status(env)
        if payload is not None:
            last_status = payload
            if payload.get("ok") is True and payload.get("state") == "stopped" and payload.get("pending", 0) == 0:
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
