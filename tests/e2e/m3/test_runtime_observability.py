"""M3 observability (log / debug) 测试"""

from __future__ import annotations

import pytest

from .conftest import exec_ok, exec_error, runtime_counter


def test_runtime_log_read_returns_initial_empty(m3_running):
    page = exec_ok(m3_running, "runtime/log/read", {"after_cursor": 0})
    assert "items" in page
    assert "next_cursor" in page
    assert isinstance(page["items"], list)


def test_runtime_log_clear_reports_cleared(m3_running):
    exec_ok(m3_running, "runtime/node/call", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "method": "emit_known_logs",
        "args": [],
    })
    first = exec_ok(m3_running, "runtime/log/read", {"after_cursor": 0})
    assert any(item["message"] == "known-info" for item in first["items"])
    clear = exec_ok(m3_running, "runtime/log/clear")
    assert clear["cleared"] >= 1
    second = exec_ok(m3_running, "runtime/log/read", {"after_cursor": 0})
    assert second["items"] == []


def test_runtime_log_incremental_no_duplicate(m3_running):
    exec_ok(m3_running, "runtime/node/call", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "method": "emit_known_logs",
        "args": [],
    })
    first = exec_ok(m3_running, "runtime/log/read", {"after_cursor": 0, "limit": 50})
    second = exec_ok(m3_running, "runtime/log/read", {"after_cursor": first["next_cursor"], "limit": 50})
    for item in second["items"]:
        first_cursors = [it["cursor"] for it in first["items"]]
        assert item["cursor"] not in first_cursors


def test_debug_performance_returns_values(m3_running):
    payload = exec_ok(m3_running, "runtime/debug/performance")
    assert "values" in payload
    assert isinstance(payload["values"], dict)


def test_debug_monitors_returns_known_keys(m3_running):
    payload = exec_ok(m3_running, "runtime/debug/monitors")
    assert "FPS" in payload["monitors"]


def test_debug_breakpoints_returns_not_supported(m3_running):
    error = exec_error(m3_running, "runtime/debug/breakpoints")
    assert error["code"] == "not_supported"
