"""M3 输入模拟 E2E 测试"""

from __future__ import annotations

import json
import time
import subprocess

import pytest

from .conftest import exec_ok, exec_error, runtime_counter, wait_for, start_exec


def start_exec(env, route, data=None):
    """启动一个 async 路由,不等待完成。"""
    args = ["exec", route, "--project", str(env["project"])]
    if data is not None:
        args += ["--data", json.dumps(data)]
    return env["gdcli"], args


def get_counter(env, name):
    return runtime_counter(env, name)


@pytest.mark.parametrize("counter_name", ["input_keys", "input_mouse", "input_gamepad", "input_touch"])
def test_input_key_mouse_gamepad_touch_increments_counter(m3_running, counter_name):
    path = "/root/RuntimeMain/ProbeTarget"
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


def test_input_action_increments_actions(m3_running):
    before = get_counter(m3_running, "input_actions")
    exec_ok(m3_running, "runtime/input/action", {"action": "ui_accept", "pressed": True})
    wait_for(lambda: get_counter(m3_running, "input_actions") == before + 1, timeout=2.0)


@pytest.mark.parametrize("route,payload", [
    ("runtime/input/action", {"action": "missing_action_in_input_map", "pressed": True}),
    ("runtime/input/mouse", {"kind": "button", "button": 99, "pressed": True, "position": [0, 0]}),
])
def test_input_validation_rejects_invalid_params(m3_running, route, payload):
    error = exec_error(m3_running, route, payload)
    assert error["code"] == "invalid_param"


def test_input_sequence_rejects_too_many_events(m3_running):
    events = [{"after_ms": 0, "route": "runtime/input/action", "data": {"action": "ui_accept", "pressed": True}}] * 101
    error = exec_error(m3_running, "runtime/input/sequence", {"events": events})
    assert error["code"] == "invalid_param"


def test_input_sequence_rejects_negative_after_ms(m3_running):
    events = [{"after_ms": -1, "route": "runtime/input/action", "data": {"action": "ui_accept", "pressed": True}}]
    error = exec_error(m3_running, "runtime/input/sequence", {"events": events})
    assert error["code"] == "invalid_param"
