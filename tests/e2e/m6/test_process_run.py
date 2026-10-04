from __future__ import annotations

import concurrent.futures
import json
import os
import socket
import struct
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


def test_process_run_json_preserves_non_nul_c0_controls(
    m6_editor_process: dict[str, Any],
) -> None:
    intended = "".join(chr(codepoint) for codepoint in range(1, 0x20))
    script = "import sys; sys.stdout.buffer.write(bytes(range(1, 32)))"
    result = exec_ok(m6_editor_process, "process/run", {
        "executable": sys.executable,
        "args": ["-c", script],
    })
    assert [ord(character) for character in result["stdout"]] == [
        ord(character) for character in intended
    ]


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


def test_process_timeout_is_enforced_during_editor_main_thread_stall(
    m6_editor_process: dict[str, Any],
) -> None:
    project = Path(m6_editor_process["project"])
    scene_path = "res://scenes/process_deadline_blocker.tscn"
    scene = project / "scenes" / "process_deadline_blocker.tscn"
    script = project / "tools" / "process_deadline_blocker.gd"
    started = project / "tools" / "deadline_started.txt"
    late = project / "tools" / "deadline_late.txt"
    original_scene = exec_ok(m6_editor_process, "scene/current")["path"]
    script.write_text(
        "@tool\nextends Node\n\nfunc _ready() -> void:\n\tOS.delay_msec(2500)\n",
        encoding="utf-8",
    )
    scene.write_text(
        '[gd_scene load_steps=2 format=3]\n\n'
        '[ext_resource type="Script" path="res://tools/process_deadline_blocker.gd" id="1"]\n\n'
        '[node name="ProcessDeadlineBlocker" type="Node"]\n'
        'script = ExtResource("1")\n',
        encoding="utf-8",
    )
    process_script = (
        "import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text('started'); "
        "time.sleep(1.5); pathlib.Path(sys.argv[2]).write_text('late')"
    )
    before = audit_for_route(m6_editor_process, "process/run")
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            process = executor.submit(
                exec_error,
                m6_editor_process,
                "process/run",
                {
                    "executable": sys.executable,
                    "args": ["-c", process_script, str(started), str(late)],
                    "cwd": "res://tools",
                    "timeout_ms": 500,
                },
            )
            deadline = time.monotonic() + 5
            while not started.exists():
                assert time.monotonic() < deadline, "timed process did not start"
                time.sleep(0.01)
            opened = exec_ok(m6_editor_process, "scene/open", {"path": scene_path})
            assert opened["path"] == scene_path
            error = process.result(timeout=10)
        assert error["code"] == "timeout", error
        assert not late.exists(), "process made a side effect after timeout while editor was stalled"
        events = audit_for_route(m6_editor_process, "process/run")[len(before):]
        assert len(events) == 1, events
        assert events[0].get("ok") is False and events[0].get("code") == "timeout", events
    finally:
        current = exec_ok(m6_editor_process, "scene/current").get("path")
        if current != original_scene:
            exec_ok(m6_editor_process, "scene/open", {"path": original_scene})
        for path in (scene, scene.with_suffix(".tscn.uid"), script, script.with_suffix(".gd.uid"), started, late):
            path.unlink(missing_ok=True)


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
        client.setsockopt(
            socket.SOL_SOCKET,
            socket.SO_LINGER,
            struct.pack("HH" if os.name == "nt" else "ii", 1, 0),
        )
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
