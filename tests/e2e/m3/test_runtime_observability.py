"""M3 observability (log / debug) 测试"""

from __future__ import annotations

import pytest

from .conftest import exec_ok, exec_error, runtime_route_source


OBSERVABILITY_ROUTES = {
    "runtime/log/read": False,
    "runtime/log/clear": True,
    "runtime/debug/performance": False,
    "runtime/debug/monitors": False,
    "runtime/debug/errors": False,
    "runtime/debug/breakpoints": False,
}


def emit_known_logs(env):
    return exec_ok(env, "runtime/node/call", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "method": "emit_known_logs",
        "args": [],
    })


@pytest.mark.parametrize("route,mutation", OBSERVABILITY_ROUTES.items())
def test_observability_routes_are_adapter_backed(route, mutation):
    source = runtime_route_source(route)
    assert 'extends "res://addons/gdapi/runtime/runtime_route.gd"' in source
    assert f'dispatch(req, res, "{route}", {str(mutation).lower()})' in source
    assert "runtime_probe.gd" not in source
    assert "load(" not in source


def test_runtime_log_read_returns_initial_empty(m3_running):
    page = exec_ok(m3_running, "runtime/log/read", {"after_cursor": 0})
    assert page["items"] == []
    assert page["next_cursor"] == 0
    assert page["dropped"] == 0


def test_runtime_log_read_returns_known_game_logs(m3_running):
    call = emit_known_logs(m3_running)
    assert call["changed"] is True
    first = exec_ok(m3_running, "runtime/log/read", {"after_cursor": 0})
    known = [
        (item["level"], item["message"])
        for item in first["items"]
        if item["message"] in {"known-info", "known-error"}
    ]
    assert known == [("info", "known-info"), ("error", "known-error")]
    assert [item["cursor"] for item in first["items"]] == sorted(
        item["cursor"] for item in first["items"]
    )


def test_runtime_log_clear_reports_mutation_and_empties_buffer(m3_running):
    emit_known_logs(m3_running)
    clear = exec_ok(m3_running, "runtime/log/clear")
    # The unified session shares the runtime broker; other tests may
    # have written additional entries. We only assert that the clear
    # call observed at least the two synthetic logs we just emitted.
    assert clear["cleared"] >= 2
    assert clear["next_cursor"] == 0
    assert clear["changed"] is True
    assert clear["undoable"] is False
    assert clear["operation"] == "runtime/log/clear"
    second = exec_ok(m3_running, "runtime/log/read", {"after_cursor": 0})
    assert second["items"] == []
    assert second["next_cursor"] == 0
    assert second["dropped"] == 0


def test_runtime_log_incremental_no_duplicate(m3_running):
    emit_known_logs(m3_running)
    first = exec_ok(m3_running, "runtime/log/read", {"after_cursor": 0, "limit": 1})
    second = exec_ok(
        m3_running,
        "runtime/log/read",
        {"after_cursor": first["next_cursor"], "limit": 1},
    )
    third = exec_ok(
        m3_running,
        "runtime/log/read",
        {"after_cursor": second["next_cursor"], "limit": 1},
    )
    assert [item["message"] for item in first["items"]] == ["known-info"]
    assert [item["message"] for item in second["items"]] == ["known-error"]
    assert third["items"] == []
    assert first["next_cursor"] < second["next_cursor"] == third["next_cursor"]
    assert first["dropped"] == second["dropped"] == third["dropped"] == 0


def test_debug_performance_returns_values(m3_running):
    payload = exec_ok(m3_running, "runtime/debug/performance")
    assert "values" in payload
    assert isinstance(payload["values"], dict)


def test_debug_monitors_returns_known_keys(m3_running):
    payload = exec_ok(m3_running, "runtime/debug/monitors")
    assert {
        "FPS",
        "PROCESS_TIME",
        "PHYSICS_TIME",
        "OBJECT_COUNT",
        "OBJECT_NODE_COUNT",
        "OBJECT_RESOURCE_COUNT",
        "MEMORY_STATIC",
        "MEMORY_STATIC_MAX",
    } <= payload["monitors"].keys()


def test_debug_errors_preserves_v1_empty_list(m3_running):
    payload = exec_ok(m3_running, "runtime/debug/errors")
    assert payload["items"] == []


def test_debug_breakpoints_returns_not_supported(m3_running):
    error = exec_error(m3_running, "runtime/debug/breakpoints")
    assert error["code"] == "not_supported"
