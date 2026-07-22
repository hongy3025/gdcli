"""M3 runtime scene 和 node 操作 E2E 测试"""

from __future__ import annotations

import pytest

from .conftest import (
    exec_ok,
    exec_error,
    runtime_counter,
    wait_for,
)


def test_runtime_tree_root_name(m3_running):
    tree = exec_ok(m3_running, "runtime/scene/tree", {"max_depth": 3})
    assert tree["root"]["name"] == "RuntimeMain"
    children = tree["root"]["children"]
    names = {child["name"] for child in children}
    assert "ProbeTarget" in names
    assert "ProbeInput" in names


def test_runtime_node_get_set_call(m3_running):
    path = "/root/RuntimeMain/ProbeTarget"

    # get typed Vector2
    payload = exec_ok(m3_running, "runtime/node/get", {
        "node_path": path, "property": "position",
    })
    assert payload["value"]["type"] == "Vector2"
    assert payload["value"]["value"] == [10.0, 20.0]

    # set 与 readback
    changed = exec_ok(m3_running, "runtime/node/set", {
        "node_path": path, "property": "position",
        "value": {"type": "Vector2", "value": [30, 40]},
    })
    assert changed["undoable"] is False
    payload2 = exec_ok(m3_running, "runtime/node/get", {
        "node_path": path, "property": "position",
    })
    assert payload2["value"]["value"] == [30.0, 40.0]

    # call allowlisted method "increment"
    called = exec_ok(m3_running, "runtime/node/call", {
        "node_path": path, "method": "increment", "args": [3],
    })
    assert called["result"]["plain"] == 3


def test_runtime_node_call_allowlist(m3_running):
    error = exec_error(m3_running, "runtime/node/call", {
        "node_path": "/root/RuntimeMain/ProbeTarget", "method": "queue_free",
    })
    assert error["code"] == "permission_denied"


def test_runtime_node_find_by_name(m3_running):
    found = exec_ok(m3_running, "runtime/node/find", {"name": "ProbeTarget"})
    assert found["total"] >= 1
    assert any("ProbeTarget" in node["path"] for node in found["nodes"])


def test_runtime_node_info(m3_running):
    info = exec_ok(m3_running, "runtime/node/info", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
    })
    assert info["type"] == "Node2D"
    assert "counter" in info["properties"]
    assert "position" in info["properties"]


def test_runtime_node_get_unknown_property(m3_running):
    error = exec_error(m3_running, "runtime/node/get", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "property": "nonexistent",
    })
    assert error["code"] == "not_found"
