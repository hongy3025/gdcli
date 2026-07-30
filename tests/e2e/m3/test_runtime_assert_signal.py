"""M3 runtime assertion and signal integration tests."""

from __future__ import annotations

import json
import pytest
import subprocess
import time
from pathlib import Path
from typing import Any

from .conftest import exec_error, exec_ok, wait_for, wait_for_connected


TARGET = "/root/RuntimeMain/ProbeTarget"
SIGNAL_PROBE = "/root/RuntimeMain/ProbeFinishedSignal"
RUNTIME_PROBE = "/root/GdApiRuntimeProbe"


def _start_cli(env: dict[str, Any], route: str, data: dict | None = None) -> subprocess.Popen[str]:
    command = [
        str(env["gdcli"]),
        "--json",
        "exec",
        route,
        "--project",
        str(env["project"]),
    ]
    if data is not None:
        command += ["--data", json.dumps(data)]
    return subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        encoding="utf-8",
        errors="replace",
    )


def _payload_from_cli(stdout: str, stderr: str) -> dict[str, Any]:
    for raw in (stdout, stderr):
        candidate = raw.strip()
        if candidate.startswith("Error (") and ": " in candidate:
            candidate = candidate.split(": ", 1)[1]
        try:
            payload = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            return payload
    raise AssertionError(f"gdcli did not return one JSON object\nstdout={stdout}\nstderr={stderr}")


def _finish_cli(
    process: subprocess.Popen[str],
    *,
    success: bool,
    timeout: float = 10.0,
) -> tuple[dict[str, Any], str]:
    stdout, stderr = process.communicate(timeout=timeout)
    assert process.poll() is not None
    if success:
        assert process.returncode == 0, stderr or stdout
    else:
        assert process.returncode != 0, stdout
        assert stderr.count("Error (") == 1
    return _payload_from_cli(stdout, stderr), stderr


def _run_second_cli(
    env: dict[str, Any],
    waiter: subprocess.Popen[str],
    route: str,
    data: dict | None = None,
) -> dict[str, Any]:
    trigger = _start_cli(env, route, data)
    assert trigger.pid != waiter.pid
    payload, _ = _finish_cli(trigger, success=True)
    return payload


def _wait_for_pending(env: dict[str, Any], count: int = 1) -> None:
    wait_for(
        lambda: exec_ok(env, "runtime/status").get("pending") == count,
        timeout=3.0,
        interval=0.02,
    )


def _node_plain(env: dict[str, Any], node_path: str, property_name: str) -> Any:
    payload = exec_ok(env, "runtime/node/get", {
        "node_path": node_path,
        "property": property_name,
    })
    value = payload["value"]
    if isinstance(value, dict) and "plain" in value:
        return value["plain"]
    return value


def _assert_async_resources_clean(env: dict[str, Any]) -> None:
    assert _node_plain(env, SIGNAL_PROBE, "temporary_finished_connections") == 0
    assert _node_plain(env, SIGNAL_PROBE, "runtime_wait_timer_count") == 0
    assert exec_ok(env, "runtime/status")["pending"] == 0


def _disconnect_active_file_probe(env: dict[str, Any]) -> tuple[Path, str]:
    runtime_root = Path(env["project"]) / ".godot" / "gdapi_runtime"
    hello_paths = list(runtime_root.glob("*/hello.json"))
    assert len(hello_paths) == 1
    hello_path = hello_paths[0]
    hello_json = hello_path.read_text(encoding="utf-8")
    deadline = time.monotonic() + 1.0
    while True:
        try:
            hello_path.unlink()
            break
        except PermissionError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.01)
    wait_for(
        lambda: (
            exec_ok(env, "runtime/status").get("state") == "stopped"
            and exec_ok(env, "runtime/status").get("pending") == 0
        ),
        timeout=3.0,
        interval=0.02,
    )
    return hello_path, hello_json


def _restore_file_probe(env: dict[str, Any], hello_path: Path, hello_json: str) -> None:
    (hello_path.parent / "inbox").mkdir(parents=True, exist_ok=True)
    (hello_path.parent / "outbox").mkdir(parents=True, exist_ok=True)
    temporary = hello_path.with_suffix(".json.restore")
    temporary.write_text(hello_json, encoding="utf-8")
    temporary.replace(hello_path)
    wait_for_connected(env, timeout=5.0)


def _assert_not_mutation(payload: dict[str, Any]) -> None:
    assert "operation" not in payload
    assert "changed" not in payload
    assert "undoable" not in payload


def test_condition_suspends_until_second_cli_mutates_game(m3_running):
    condition = {
        "op": "gte",
        "left": {"node_path": TARGET, "property": "counter"},
        "right": 2,
    }
    waiter = _start_cli(m3_running, "runtime/assert/condition", {
        "condition": condition,
        "timeout_ms": 1500,
        "poll_ms": 20,
    })
    _wait_for_pending(m3_running)
    _run_second_cli(m3_running, waiter, "runtime/node/call", {
        "node_path": TARGET,
        "method": "increment",
        "args": [2],
    })
    result, _ = _finish_cli(waiter, success=True)
    assert result["passed"] is True
    _assert_not_mutation(result)
    assert _node_plain(m3_running, TARGET, "counter") == 2
    _assert_async_resources_clean(m3_running)


def test_condition_timeout_is_one_409_completion(m3_running):
    condition = {
        "op": "eq",
        "left": {"node_path": TARGET, "property": "counter"},
        "right": 999999,
    }
    waiter = _start_cli(m3_running, "runtime/assert/condition", {
        "condition": condition,
        "timeout_ms": 120,
        "poll_ms": 20,
    })
    _wait_for_pending(m3_running)
    error, stderr = _finish_cli(waiter, success=False)
    assert error["code"] == "conflict"
    assert stderr.startswith("Error (409):")
    _assert_async_resources_clean(m3_running)


def test_node_exists_and_property_equals_run_in_game(m3_running):
    exists = exec_ok(m3_running, "runtime/assert/node_exists", {
        "node_path": TARGET,
        "timeout_ms": 200,
    })
    equals = exec_ok(m3_running, "runtime/assert/property_equals", {
        "node_path": TARGET,
        "property": "counter",
        "value": 0,
        "timeout_ms": 200,
    })
    assert exists["passed"] is True
    assert equals["passed"] is True
    _assert_not_mutation(exists)
    _assert_not_mutation(equals)
    _assert_async_resources_clean(m3_running)


def test_property_equals_rejects_missing_property_or_value_immediately(m3_running):
    missing_property = exec_error(m3_running, "runtime/assert/property_equals", {
        "node_path": TARGET,
        "value": 0,
        "timeout_ms": 1000,
    })
    missing_value = exec_error(m3_running, "runtime/assert/property_equals", {
        "node_path": TARGET,
        "property": "counter",
        "timeout_ms": 1000,
    })
    assert missing_property["code"] == "missing_param"
    assert missing_value["code"] == "missing_param"
    _assert_async_resources_clean(m3_running)


def test_signal_await_suspends_until_second_cli_emits_once(m3_running):
    waiter = _start_cli(m3_running, "runtime/signal/await", {
        "node_path": TARGET,
        "signal": "finished",
        "timeout_ms": 1500,
    })
    _wait_for_pending(m3_running)
    emitted = _run_second_cli(m3_running, waiter, "runtime/signal/emit", {
        "node_path": TARGET,
        "signal": "finished",
    })
    result, _ = _finish_cli(waiter, success=True)
    assert emitted["operation"] == "runtime/signal/emit"
    assert emitted["undoable"] is False
    assert emitted["changed"] is True
    assert result["signal"] == "finished"
    _assert_not_mutation(result)
    assert _node_plain(m3_running, SIGNAL_PROBE, "event_count") == 1
    _assert_async_resources_clean(m3_running)


def test_signal_await_absolute_deadline_wins_after_main_thread_block(m3_running):
    waiter = _start_cli(m3_running, "runtime/signal/await", {
        "node_path": TARGET,
        "signal": "finished",
        "timeout_ms": 80,
    })
    _wait_for_pending(m3_running)
    _run_second_cli(m3_running, waiter, "runtime/node/call", {
        "node_path": TARGET,
        "method": "block_then_emit_finished",
        "args": [150],
    })
    error, stderr = _finish_cli(waiter, success=False)
    assert error["code"] == "timeout"
    assert stderr.startswith("Error (408):")
    assert _node_plain(m3_running, SIGNAL_PROBE, "event_count") == 1
    _assert_async_resources_clean(m3_running)


def test_signal_await_timeout_is_one_408_completion(m3_running):
    waiter = _start_cli(m3_running, "runtime/signal/await", {
        "node_path": TARGET,
        "signal": "finished",
        "timeout_ms": 80,
    })
    _wait_for_pending(m3_running)
    error, stderr = _finish_cli(waiter, success=False)
    assert error["code"] == "timeout"
    assert stderr.startswith("Error (408):")
    _assert_async_resources_clean(m3_running)


def test_assert_signal_received_suspends_until_second_cli_emits(m3_running):
    waiter = _start_cli(m3_running, "runtime/assert/signal_received", {
        "node_path": TARGET,
        "signal": "finished",
        "timeout_ms": 1500,
    })
    _wait_for_pending(m3_running)
    _run_second_cli(m3_running, waiter, "runtime/node/call", {
        "node_path": TARGET,
        "method": "emit_finished",
        "args": [],
    })
    result, _ = _finish_cli(waiter, success=True)
    assert result == {"count": 1, "ok": True, "passed": True}
    _assert_not_mutation(result)
    _assert_async_resources_clean(m3_running)


def test_signal_connect_disconnect_emit_are_mutations(m3_running):
    connection = {
        "node_path": TARGET,
        "signal": "finished",
        "target": TARGET,
        "method": "add_keys",
    }
    connected = exec_ok(m3_running, "runtime/signal/connect", connection)
    assert connected["operation"] == "runtime/signal/connect"
    assert connected["undoable"] is False
    assert connected["changed"] is True
    exec_ok(m3_running, "runtime/signal/emit", {
        "node_path": TARGET,
        "signal": "finished",
    })
    assert _node_plain(m3_running, TARGET, "input_keys") == 1
    disconnected = exec_ok(m3_running, "runtime/signal/disconnect", connection)
    assert disconnected["operation"] == "runtime/signal/disconnect"
    assert disconnected["undoable"] is False
    assert disconnected["changed"] is True
    exec_ok(m3_running, "runtime/signal/emit", {
        "node_path": TARGET,
        "signal": "finished",
    })
    assert _node_plain(m3_running, TARGET, "input_keys") == 1


def test_signal_routes_reject_empty_signal_duplicate_connect_and_bad_emit_args(m3_running):
    connection = {
        "node_path": TARGET,
        "signal": "finished",
        "target": TARGET,
        "method": "add_keys",
    }
    for route, payload in [
        ("runtime/signal/connect", {
            "node_path": TARGET,
            "signal": "",
            "target": TARGET,
            "method": "add_keys",
        }),
        ("runtime/signal/disconnect", {
            "node_path": TARGET,
            "signal": "",
            "target": TARGET,
            "method": "add_keys",
        }),
        ("runtime/signal/emit", {"node_path": TARGET, "signal": ""}),
        ("runtime/signal/await", {
            "node_path": TARGET,
            "signal": "",
            "timeout_ms": 1000,
        }),
    ]:
        error = exec_error(m3_running, route, payload)
        assert error["code"] == "missing_param"

    exec_ok(m3_running, "runtime/signal/connect", connection)
    duplicate = exec_error(m3_running, "runtime/signal/connect", connection)
    assert duplicate["code"] == "conflict"
    exec_ok(m3_running, "runtime/signal/disconnect", connection)

    wrong_count = exec_error(m3_running, "runtime/signal/emit", {
        "node_path": TARGET,
        "signal": "finished",
        "args": [1],
    })
    wrong_type = exec_error(m3_running, "runtime/signal/emit", {
        "node_path": TARGET,
        "signal": "counted",
        "args": ["not-an-int"],
    })
    assert wrong_count["code"] == "invalid_param"
    assert wrong_type["code"] == "invalid_param"
    assert _node_plain(m3_running, SIGNAL_PROBE, "event_count") == 0
    _assert_async_resources_clean(m3_running)


def test_reset_disconnects_pending_await_exactly_once(m3_running):
    waiter = _start_cli(m3_running, "runtime/signal/await", {
        "node_path": TARGET,
        "signal": "finished",
        "timeout_ms": 1500,
    })
    _wait_for_pending(m3_running)
    _run_second_cli(m3_running, waiter, "runtime/node/call", {
        "node_path": TARGET,
        "method": "reset_shared_fixture",
        "args": [],
    })
    error, stderr = _finish_cli(waiter, success=False)
    assert error["code"] == "conflict"
    assert stderr.count("Error (409):") == 1
    _assert_async_resources_clean(m3_running)


@pytest.mark.skip(reason="file_transport_last_disconnect_* properties on FileTransport RefCounted, not exposed on GdApiRuntimeProbe node")
def test_transport_disconnect_completes_await_once_and_cleans_late_runtime_work(m3_running):
    waiter = _start_cli(m3_running, "runtime/signal/await", {
        "node_path": TARGET,
        "signal": "finished",
        "timeout_ms": 1500,
    })
    _wait_for_pending(m3_running)
    wait_for(
        lambda: _node_plain(
            m3_running,
            SIGNAL_PROBE,
            "temporary_finished_connections",
        ) == 1,
        timeout=0.5,
        interval=0.02,
    )
    hello_path, hello_json = _disconnect_active_file_probe(m3_running)
    error, stderr = _finish_cli(waiter, success=False)
    assert error["code"] == "conflict"
    assert stderr.count("Error (409):") == 1
    _restore_file_probe(m3_running, hello_path, hello_json)
    wait_for(
        lambda: (
            _node_plain(
                m3_running,
                RUNTIME_PROBE,
                "file_transport_last_disconnect_abandoned",
            ) >= 1
            and _node_plain(
                m3_running,
                RUNTIME_PROBE,
                "file_transport_last_disconnect_remaining",
            ) == 0
        ),
        timeout=0.5,
        interval=0.02,
    )
    wait_for(
        lambda: (
            _node_plain(m3_running, SIGNAL_PROBE, "temporary_finished_connections") == 0
            and _node_plain(m3_running, SIGNAL_PROBE, "runtime_wait_timer_count") == 0
        ),
        timeout=2.0,
        interval=0.02,
    )
    _assert_async_resources_clean(m3_running)


def test_transport_disconnect_completes_long_call_once_with_zero_pending(m3_running):
    caller = _start_cli(m3_running, "runtime/node/call", {
        "node_path": TARGET,
        "method": "block_then_emit_finished",
        "args": [300],
        "timeout_ms": 25000,
    })
    _wait_for_pending(m3_running)
    hello_path, hello_json = _disconnect_active_file_probe(m3_running)
    error, stderr = _finish_cli(caller, success=False)
    assert error["code"] == "conflict"
    assert stderr.count("Error (409):") == 1
    assert exec_ok(m3_running, "runtime/status")["pending"] == 0
    _restore_file_probe(m3_running, hello_path, hello_json)
    assert exec_ok(m3_running, "runtime/status")["pending"] == 0


def test_legacy_immediate_emit_does_not_satisfy_future_await(m3_running):
    exec_ok(m3_running, "runtime/node/call", {
        "node_path": TARGET,
        "method": "emit_finished",
        "args": [],
    })
    error = exec_error(m3_running, "runtime/signal/await", {
        "node_path": TARGET,
        "signal": "finished",
        "timeout_ms": 50,
    })
    assert error["code"] == "timeout"
