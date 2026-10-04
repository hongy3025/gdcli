from __future__ import annotations

import json
import os
import socket
import sys
import time
from pathlib import Path


from e2e.m6.conftest import audit_for_route, exec_error, exec_ok


def test_process_run_no_shell_preserves_argv(m6_editor_process: dict[str, Any]) -> None:
    result = exec_ok(m6_editor_process, "process/run", {
        "executable": "echo_args.cmd", "args": ["a;b", "$(whoami)"],
        "cwd": "res://tools",
    })
    assert result["exit_code"] == 0
    assert '"a;b"' in result["stdout"]
    assert '"$(whoami)"' in result["stdout"]


def test_process_run_timeout_has_one_failed_terminal_audit(
    m6_editor_process: dict[str, Any],
) -> None:
    started = time.monotonic()
    error = exec_error(m6_editor_process, "process/run", {
        "executable": "sleep.cmd", "args": ["10"], "cwd": "res://tools",
        "timeout_ms": 200,
    })
    assert error["code"] == "timeout"
    assert time.monotonic() - started < 5.0
    events = audit_for_route(m6_editor_process, "process/run")
    timeout_events = [e for e in events if e.get("code") == "timeout"]
    assert len(timeout_events) == 1


def test_process_run_default_handler_deadline_prevents_late_side_effect_and_success_audit(
    m6_editor_process: dict[str, Any],
) -> None:
    """Exercise the real production 30s HTTP limit, not an enlarged test limit."""
    assert "GDAPI_HANDLER_TIMEOUT_MS" not in os.environ
    project = Path(m6_editor_process["project"])
    marker = project / "tools" / "default_timeout_late.txt"
    before = audit_for_route(m6_editor_process, "process/run")
    script = (
        "import pathlib,sys,time; print('started',flush=True); time.sleep(32); "
        "pathlib.Path(sys.argv[1]).write_text('late side effect')"
    )
    started = time.monotonic()
    error = exec_error(
        m6_editor_process,
        "process/run",
        {"executable": sys.executable, "args": ["-c", script, str(marker)], "timeout_ms": 60000},
        extra_args=["--timeout", "34"],
    )
    elapsed = time.monotonic() - started
    assert error.get("code") == "timeout", error
    assert 28.5 <= elapsed < 32, elapsed
    assert not marker.exists()
    time.sleep(max(0, started + 33.5 - time.monotonic()))
    assert not marker.exists(), "process continued after its HTTP handler expired"
    events = audit_for_route(m6_editor_process, "process/run")[len(before):]
    assert len(events) == 1, events
    assert events[0].get("ok") is False and events[0].get("code") == "timeout", events


def test_process_run_client_disconnect_cancels_and_audits_failure(
    m6_editor_process: dict[str, Any],
) -> None:
    project = Path(m6_editor_process["project"])
    ready = project / "tools" / "disconnect_ready.txt"
    marker = project / "tools" / "disconnect_late.txt"
    before = audit_for_route(m6_editor_process, "process/run")
    script = (
        "import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text('ready'); "
        "time.sleep(1.5); pathlib.Path(sys.argv[2]).write_text('late side effect')"
    )
    data = json.dumps({
        "executable": sys.executable, "args": ["-c", script, str(ready), str(marker)],
        "timeout_ms": 60000,
    }).encode()
    meta = m6_editor_process["meta"]
    with socket.create_connection(("127.0.0.1", meta["http_port"]), timeout=5) as client:
        headers = (
            "POST /process/run HTTP/1.1\r\nHost: localhost\r\n"
            f"Authorization: Bearer {meta['token']}\r\n"
            f"Content-Length: {len(data)}\r\nContent-Type: application/json\r\n\r\n"
        )
        client.sendall(headers.encode() + data)
        deadline = time.monotonic() + 3
        while not ready.exists():
            assert time.monotonic() < deadline, "actual subprocess never started"
            time.sleep(0.01)
        ready_at = time.monotonic()
    deadline = time.monotonic() + 1
    events: list[dict[str, Any]] = []
    while time.monotonic() < deadline:
        events = audit_for_route(m6_editor_process, "process/run")[len(before):]
        if events:
            break
        time.sleep(0.01)
    assert len(events) == 1, events
    assert events[0].get("ok") is False and events[0].get("code") == "conflict", events
    time.sleep(max(0, ready_at + 1.8 - time.monotonic()))
    assert not marker.exists(), "disconnected process continued producing side effects"


def test_process_spawn_failure_is_audited_as_failure(
    m6_editor_process: dict[str, Any],
) -> None:
    error = exec_error(m6_editor_process, "process/run", {
        "executable": "definitely-not-a-real-binary-xyz", "args": [], "cwd": "res://tools",
    })
    assert error.get("code"), error
    events = audit_for_route(m6_editor_process, "process/run")
    failures = [e for e in events if e.get("ok") is False and e.get("code")]
    assert failures, events
