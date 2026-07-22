"""M3 assertions and signal tests"""

from __future__ import annotations

import threading
import time

import pytest

from .conftest import exec_ok, exec_error, runtime_counter, wait_for


def _start_helper(env, route, data):
    """Start an async route call in a background thread, return result holder."""
    result_holder = {}

    def runner():
        from .conftest import exec_error as _err
        try:
            res = exec_ok(env, route, data)
            result_holder["ok"] = res
        except Exception as exc:
            result_holder["error"] = exc

    t = threading.Thread(target=runner, daemon=True)
    t.start()
    return result_holder


def test_condition_waits_until_true(m3_running):
    # Trigger increment_later(2, 100ms) so counter reaches 2 after 100ms.
    exec_ok(m3_running, "runtime/node/call", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "method": "increment_later",
        "args": [2, 100],
    })
    condition = {
        "op": "gte",
        "left": {"node_path": "/root/RuntimeMain/ProbeTarget", "property": "counter"},
        "right": 2,
    }
    result = exec_ok(m3_running, "runtime/assert/condition", {
        "condition": condition,
        "timeout_ms": 1000,
        "poll_ms": 20,
    })
    assert result["passed"] is True


def test_condition_times_out_returns_conflict(m3_running):
    condition = {
        "op": "eq",
        "left": {"node_path": "/root/RuntimeMain/ProbeTarget", "property": "counter"},
        "right": 999999,
    }
    error = exec_error(m3_running, "runtime/assert/condition", {
        "condition": condition,
        "timeout_ms": 200,
        "poll_ms": 20,
    })
    assert error["code"] == "conflict"


def test_signal_emit_and_await(m3_running):
    # emit finished immediately, then await with shorter timeout.
    exec_ok(m3_running, "runtime/node/call", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "method": "emit_finished",
        "args": [],
    })
    result = exec_ok(m3_running, "runtime/signal/await", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "signal": "finished",
        "timeout_ms": 500,
    })
    assert "signal" in result


def test_signal_await_timeout(m3_running):
    error = exec_error(m3_running, "runtime/signal/await", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "signal": "finished",
        "timeout_ms": 50,
    })
    assert error["code"] == "timeout"


def test_assert_signal_received(m3_running):
    exec_ok(m3_running, "runtime/node/call", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "method": "emit_finished",
        "args": [],
    })
    result = exec_ok(m3_running, "runtime/assert/signal_received", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "signal": "finished",
        "timeout_ms": 500,
    })
    assert result["passed"] is True
