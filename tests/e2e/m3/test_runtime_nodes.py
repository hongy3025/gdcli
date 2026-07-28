"""M3 runtime scene 和 node 操作 E2E 测试"""

from __future__ import annotations

import pytest

from .conftest import (
    exec_ok,
    exec_error,
    runtime_route_source,
)


def test_runtime_tree_root_name(m3_running):
    tree = exec_ok(m3_running, "runtime/scene/tree", {"max_depth": 3})
    assert tree["root"]["name"] == "RuntimeMain"
    children = tree["root"]["children"]
    names = {child["name"] for child in children}
    assert "ProbeTarget" in names
    assert "ProbeInput" in names


def test_runtime_node_get_set_call(m3_running):
    """Task 7 vertical slice; set/call remain deferred to the node-family migration."""
    path = "/root/RuntimeMain/ProbeTarget"

    # get typed Vector2 from renamed field spawn_position
    payload = exec_ok(m3_running, "runtime/node/get", {
        "node_path": path, "property": "spawn_position",
    })
    assert payload["ok"] is True
    assert payload["value"]["type"] == "Vector2"
    assert payload["value"]["value"] == [10.0, 20.0]
    assert 'load("res://addons/gdapi/runtime/runtime_node_ops.gd")' not in runtime_route_source(
        "runtime/node/get"
    )


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


def test_scene_node_routes_use_runtime_adapter_without_local_ops_load(m3_editor):
    routes = [
        "runtime/scene/tree",
        "runtime/node/info",
        "runtime/node/get",
        "runtime/node/set",
        "runtime/node/call",
        "runtime/node/find",
        "runtime/node/remove",
        "runtime/node/reparent",
        "runtime/node/create",
        "runtime/node/duplicate",
        "runtime/node/rename",
    ]
    for route in routes:
        source = runtime_route_source(route)
        assert 'extends "res://addons/gdapi/runtime/runtime_route.gd"' in source, route
        assert f'dispatch(req, res, "{route}"' in source, route
        assert "runtime_node_ops.gd" not in source, route


def test_runtime_node_create_returns_dedicated_game_node(m3_running):
    created = exec_ok(m3_running, "runtime/node/create", {
        "parent_path": "/root/RuntimeMain",
        "type": "Node2D",
        "name": "Task9Created",
        "properties": {
            "position": {"type": "Vector2", "value": [3, 4]},
        },
    })
    assert created["changed"] is True
    assert created["undoable"] is False
    assert created["node_path"] == "/root/RuntimeMain/Task9Created"
    position = exec_ok(m3_running, "runtime/node/get", {
        "node_path": created["node_path"], "property": "position",
    })
    assert position["value"] == {"type": "Vector2", "value": [3.0, 4.0]}


def test_runtime_node_duplicate_copies_typed_allowlisted_property(m3_running):
    source = "/root/RuntimeMain/ProbeTarget"
    exec_ok(m3_running, "runtime/node/set", {
        "node_path": source,
        "property": "position",
        "value": {"type": "Vector2", "value": [31, 42]},
    })
    duplicate = exec_ok(m3_running, "runtime/node/duplicate", {
        "node_path": source,
        "name": "Task9Duplicate",
    })
    assert duplicate["changed"] is True
    assert duplicate["undoable"] is False
    assert duplicate["node_path"] != source
    copied = exec_ok(m3_running, "runtime/node/get", {
        "node_path": duplicate["node_path"], "property": "position",
    })
    assert copied["value"] == {"type": "Vector2", "value": [31.0, 42.0]}


def test_runtime_node_rename_changes_only_dedicated_node(m3_running):
    source = "/root/RuntimeMain/ProbeTarget"
    duplicate = exec_ok(m3_running, "runtime/node/duplicate", {
        "node_path": source,
        "name": "Task9RenameSource",
    })
    renamed = exec_ok(m3_running, "runtime/node/rename", {
        "node_path": duplicate["node_path"],
        "name": "Task9Renamed",
    })
    assert renamed["changed"] is True
    assert renamed["undoable"] is False
    assert renamed["node_path"] == "/root/RuntimeMain/Task9Renamed"
    assert exec_error(m3_running, "runtime/node/info", {
        "node_path": duplicate["node_path"],
    })["code"] == "not_found"
    assert exec_ok(m3_running, "runtime/node/info", {
        "node_path": renamed["node_path"],
    })["node_path"] == renamed["node_path"]


def test_runtime_node_mutations_reject_unsafe_targets_without_mutation(m3_running):
    source = "/root/RuntimeMain/ProbeTarget"
    invalid_create = exec_error(m3_running, "runtime/node/create", {
        "parent_path": "/root/RuntimeMain/../RuntimeMain",
        "type": "Node2D",
        "name": "Task9Unsafe",
    })
    assert invalid_create["code"] in {"invalid_param", "invalid_path", "not_found"}
    assert exec_error(m3_running, "runtime/node/duplicate", {
        "node_path": source, "name": "ProbeInput",
    })["code"] == "conflict"
    assert exec_error(m3_running, "runtime/node/rename", {
        "node_path": source, "name": "RuntimeMain/Bad",
    })["code"] == "invalid_param"
    cycle = exec_error(m3_running, "runtime/node/reparent", {
        "node_path": source, "new_parent": source,
    })
    assert cycle["code"] == "conflict"
    assert exec_ok(m3_running, "runtime/node/info", {"node_path": source})["node_path"] == source
