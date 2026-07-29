"""M3 输入模拟 E2E 测试"""

from __future__ import annotations

import json
import time
import subprocess
from pathlib import Path

import pytest

from .conftest import (
    exec_ok,
    exec_error,
    fixture_script_source,
    runtime_route_source,
    runtime_counter,
    wait_for,
    wait_for_connected,
)

INPUT_ROUTES = ("key", "mouse", "gamepad", "touch", "action", "sequence")
COUNTERS = ("input_keys", "input_mouse", "input_gamepad", "input_touch", "input_actions")


def start_exec(env, route, data=None):
    """启动一个 async 路由,不等待完成。"""
    args = ["exec", route, "--project", str(env["project"])]
    if data is not None:
        args += ["--data", json.dumps(data)]
    return env["gdcli"], args


def get_counter(env, name):
    return runtime_counter(env, name)


def counter_snapshot(env):
    return {name: get_counter(env, name) for name in COUNTERS}


@pytest.mark.parametrize("name", INPUT_ROUTES)
def test_input_routes_are_adapter_backed_mutations(name):
    route = f"runtime/input/{name}"
    source = runtime_route_source(route)
    assert 'extends "res://addons/gdapi/runtime/runtime_route.gd"' in source
    assert f'dispatch(req, res, "{route}", true)' in source
    assert "runtime_input_ops.gd" not in source
    assert "load(" not in source


def test_fixture_reset_releases_action_edge_state():
    source = fixture_script_source("probe_input_action.gd")
    assert "func reset_fixture()" in source
    assert "func _process(" in source
    assert "Input.is_action_pressed(\"ui_accept\")" in source
    assert "_previous_pressed = false" in source
    assert 'Input.action_release("ui_accept")' in source


@pytest.mark.parametrize("counter_name", ["input_keys", "input_mouse", "input_gamepad", "input_touch"])
def test_input_key_mouse_gamepad_touch_increments_counter(m3_running, counter_name):
    before = get_counter(m3_running, counter_name)
    route_map = {
        "input_keys": ("runtime/input/key", {"keycode": 32, "pressed": True}),
        "input_mouse": ("runtime/input/mouse", {"kind": "button", "button": 1, "pressed": True, "position": [8, 9]}),
        "input_gamepad": ("runtime/input/gamepad", {"device": 0, "button": 0, "pressed": True}),
        "input_touch": ("runtime/input/touch", {"index": 0, "pressed": True, "position": [12, 14]}),
    }
    route, payload = route_map[counter_name]
    exec_ok(m3_running, route, payload)
    wait_for(lambda: get_counter(m3_running, counter_name) == before + 1, timeout=2.0)


def test_input_action_counts_false_to_true_edges_once(m3_running):
    before = get_counter(m3_running, "input_actions")
    exec_ok(m3_running, "runtime/input/action", {"action": "ui_accept", "pressed": True})
    wait_for(lambda: get_counter(m3_running, "input_actions") == before + 1, timeout=2.0)
    exec_ok(m3_running, "runtime/input/action", {"action": "ui_accept", "pressed": True})
    time.sleep(0.2)
    assert get_counter(m3_running, "input_actions") == before + 1
    exec_ok(m3_running, "runtime/input/action", {"action": "ui_accept", "pressed": False})
    exec_ok(m3_running, "runtime/input/action", {"action": "ui_accept", "pressed": True})
    wait_for(lambda: get_counter(m3_running, "input_actions") == before + 2, timeout=2.0)


def test_zero_delay_action_sequence_observes_release_press_edge(m3_running):
    before = get_counter(m3_running, "input_actions")
    exec_ok(m3_running, "runtime/input/action", {"action": "ui_accept", "pressed": True})
    wait_for(lambda: get_counter(m3_running, "input_actions") == before + 1, timeout=2.0)
    result = exec_ok(m3_running, "runtime/input/sequence", {
        "events": [
            {
                "after_ms": 0,
                "route": "runtime/input/action",
                "data": {"action": "ui_accept", "pressed": True},
            },
            {
                "after_ms": 0,
                "route": "runtime/input/action",
                "data": {"action": "ui_accept", "pressed": False},
            },
            {
                "after_ms": 0,
                "route": "runtime/input/action",
                "data": {"action": "ui_accept", "pressed": True},
            },
        ],
    })
    assert result["events"] == 3
    wait_for(lambda: get_counter(m3_running, "input_actions") == before + 2, timeout=2.0)


@pytest.mark.parametrize("route,payload", [
    ("runtime/input/key", {"keycode": "SPACE", "pressed": True}),
    ("runtime/input/action", {"action": "missing_action_in_input_map", "pressed": True}),
    ("runtime/input/mouse", {"kind": "button", "button": 99, "pressed": True, "position": [0, 0]}),
    ("runtime/input/mouse", {"kind": "motion", "position": [0]}),
    ("runtime/input/gamepad", {"kind": "axis", "axis": 4, "value": 0.5}),
    ("runtime/input/gamepad", {"kind": "axis", "axis": 0, "value": 1.1}),
    ("runtime/input/touch", {"index": -1, "pressed": True, "position": [0, 0]}),
])
def test_input_validation_rejects_without_mutation(m3_running, route, payload):
    before = counter_snapshot(m3_running)
    error = exec_error(m3_running, route, payload)
    assert error["code"] == "invalid_param"
    time.sleep(0.1)
    assert counter_snapshot(m3_running) == before


def test_input_sequence_rejects_too_many_events(m3_running):
    events = [{"after_ms": 0, "route": "runtime/input/action", "data": {"action": "ui_accept", "pressed": True}}] * 101
    error = exec_error(m3_running, "runtime/input/sequence", {"events": events})
    assert error["code"] == "invalid_param"


def test_input_sequence_executes_valid_events_in_game_process(m3_running):
    before_keys = get_counter(m3_running, "input_keys")
    before_mouse = get_counter(m3_running, "input_mouse")
    result = exec_ok(m3_running, "runtime/input/sequence", {"events": [
        {
            "after_ms": 0,
            "route": "runtime/input/key",
            "data": {"keycode": 32, "pressed": True},
        },
        {
            "after_ms": 1,
            "route": "runtime/input/mouse",
            "data": {
                "kind": "button",
                "button": 1,
                "pressed": True,
                "position": [8, 9],
            },
        },
    ]})
    assert result["events"] == 2
    assert result["changed"] is True
    assert result["undoable"] is False
    wait_for(lambda: get_counter(m3_running, "input_keys") == before_keys + 1)
    wait_for(lambda: get_counter(m3_running, "input_mouse") == before_mouse + 1)


def test_input_sequence_over_five_seconds_honors_explicit_timeout(m3_running):
    before = get_counter(m3_running, "input_keys")
    result = exec_ok(m3_running, "runtime/input/sequence", {
        "timeout_ms": 10000,
        "events": [{
            "after_ms": 6000,
            "route": "runtime/input/key",
            "data": {"keycode": 32, "pressed": True},
        }],
    })
    assert result["events"] == 1
    wait_for(lambda: get_counter(m3_running, "input_keys") == before + 1)


def test_input_sequence_rejects_negative_after_ms(m3_running):
    before = counter_snapshot(m3_running)
    events = [{"after_ms": -1, "route": "runtime/input/action", "data": {"action": "ui_accept", "pressed": True}}]
    error = exec_error(m3_running, "runtime/input/sequence", {"events": events})
    assert error["code"] == "invalid_param"
    assert counter_snapshot(m3_running) == before


def test_input_sequence_rejects_cumulative_duration_over_ten_seconds(m3_running):
    before = counter_snapshot(m3_running)
    events = [
        {"after_ms": 5001, "route": "runtime/input/key", "data": {"keycode": 32}},
        {"after_ms": 5000, "route": "runtime/input/key", "data": {"keycode": 32}},
    ]
    started = time.monotonic()
    error = exec_error(m3_running, "runtime/input/sequence", {"events": events})
    assert time.monotonic() - started < 2.0
    assert error["code"] == "invalid_param"
    assert counter_snapshot(m3_running) == before


@pytest.mark.parametrize("invalid_entry", [
    {"after_ms": 0, "route": "runtime/input/unsupported", "data": {}},
    {"after_ms": 0, "route": "runtime/input/key", "data": {"keycode": "SPACE"}},
    {"after_ms": 0, "route": "runtime/input/mouse", "data": {"kind": "button", "button": 99}},
])
def test_input_sequence_prevalidates_every_event_before_execution(m3_running, invalid_entry):
    before = counter_snapshot(m3_running)
    events = [
        {"after_ms": 0, "route": "runtime/input/key", "data": {"keycode": 32, "pressed": True}},
        invalid_entry,
    ]
    error = exec_error(m3_running, "runtime/input/sequence", {"events": events})
    assert error["code"] == "invalid_param"
    time.sleep(0.1)
    assert counter_snapshot(m3_running) == before


def test_input_mutation_audit_is_redacted_and_bounded(m3_running):
    exec_ok(m3_running, "gdapi/audit/clear", {"force": True})
    exec_ok(m3_running, "runtime/input/key", {"keycode": 32, "pressed": True})
    secret = "task11-secret-value"
    error = exec_error(m3_running, "runtime/input/key", {
        "keycode": 0,
        "secret": secret,
        "large_payload": ["x" * 100] * 40,
    })
    assert error["code"] == "invalid_param"
    entries = exec_ok(m3_running, "gdapi/audit/list", {"since": 0, "limit": 100})["entries"]
    input_entries = [entry for entry in entries if entry.get("route") == "runtime/input/key"]
    assert len(input_entries) == 2
    assert input_entries[0]["ok"] is True
    assert input_entries[0]["code"] == ""
    latest = input_entries[-1]
    serialized = json.dumps(latest, sort_keys=True)
    assert latest["ok"] is False
    assert latest["code"] == "invalid_param"
    assert secret not in serialized
    assert "[REDACTED]" in serialized
    assert '"size": 40' in serialized


def test_oversized_mutation_request_is_structured_fast_and_secret_safe(m3_running):
    exec_ok(m3_running, "gdapi/audit/clear", {"force": True})
    secret = "task16-oversized-authorization"
    payload_path = Path(m3_running["project"]) / ".godot" / "task16-oversized.json"
    payload_path.write_text(json.dumps({
        "keycode": 32,
        "pressed": True,
        "authorization": secret,
        "blob": "x" * (4 * 1024 * 1024),
    }), encoding="utf-8")
    command = [
        str(m3_running["gdcli"]),
        "--json",
        "exec",
        "runtime/input/key",
        "--project",
        str(m3_running["project"]),
        "--data",
        f"@{payload_path}",
    ]
    started = time.monotonic()
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=10.0,
        )
    finally:
        payload_path.unlink(missing_ok=True)
    assert result.returncode != 0, result.stdout
    candidate = result.stderr.strip()
    if candidate.startswith("Error (") and ": " in candidate:
        candidate = candidate.split(": ", 1)[1]
    error = json.loads(candidate)
    assert time.monotonic() - started < 5.0
    assert error["code"] == "invalid_param", error
    assert "4 MiB" in error["error"]
    assert exec_ok(m3_running, "runtime/status")["pending"] == 0
    entries = exec_ok(m3_running, "gdapi/audit/list", {"since": 0, "limit": 100})["entries"]
    serialized = json.dumps(
        [entry for entry in entries if entry.get("route") == "runtime/input/key"],
        sort_keys=True,
    )
    assert secret not in serialized
    assert "[REDACTED]" in serialized


def test_stale_generation_file_request_is_removed_without_dispatch(m3_running):
    runtime_root = Path(m3_running["project"]) / ".godot" / "gdapi_runtime"
    hello_paths = list(runtime_root.glob("*/hello.json"))
    assert len(hello_paths) == 1
    probe_root = hello_paths[0].parent
    hello = json.loads(hello_paths[0].read_text(encoding="utf-8"))
    current_generation = hello["result"]["generation"]
    assert current_generation
    before = get_counter(m3_running, "input_keys")
    request_id = 2_000_000_001
    inbox = probe_root / "inbox" / f"{request_id}.json"
    inbox.write_text(json.dumps({
        "version": 1,
        "id": request_id,
        "kind": "request",
        "op": "runtime/input/key",
        "payload": {"keycode": 32, "pressed": True},
        "generation": f"{current_generation}-stale",
    }), encoding="utf-8")
    wait_for(lambda: not inbox.exists(), timeout=2.0, interval=0.02)
    time.sleep(0.1)
    assert get_counter(m3_running, "input_keys") == before
    assert not (probe_root / "outbox" / f"{request_id}.json").exists()
    assert exec_ok(m3_running, "runtime/status")["pending"] == 0


def test_transport_disconnect_completes_sequence_once_with_zero_pending(m3_running):
    executable, args = start_exec(m3_running, "runtime/input/sequence", {
        "timeout_ms": 25000,
        "events": [{
            "after_ms": 500,
            "route": "runtime/input/key",
            "data": {"keycode": 32, "pressed": True},
        }],
    })
    process = subprocess.Popen(
        [str(executable), "--json", *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        encoding="utf-8",
        errors="replace",
    )
    wait_for(
        lambda: exec_ok(m3_running, "runtime/status").get("pending") == 1,
        timeout=3.0,
        interval=0.02,
    )
    runtime_root = Path(m3_running["project"]) / ".godot" / "gdapi_runtime"
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
            exec_ok(m3_running, "runtime/status").get("state") == "stopped"
            and exec_ok(m3_running, "runtime/status").get("pending") == 0
        ),
        timeout=3.0,
        interval=0.02,
    )
    stdout, stderr = process.communicate(timeout=5.0)
    assert process.returncode != 0, stdout
    assert stderr.count("Error (409):") == 1
    (hello_path.parent / "inbox").mkdir(parents=True, exist_ok=True)
    (hello_path.parent / "outbox").mkdir(parents=True, exist_ok=True)
    restored = hello_path.with_suffix(".json.restore")
    restored.write_text(hello_json, encoding="utf-8")
    restored.replace(hello_path)
    wait_for_connected(m3_running, timeout=5.0)
    time.sleep(0.6)
    assert exec_ok(m3_running, "runtime/status")["pending"] == 0
