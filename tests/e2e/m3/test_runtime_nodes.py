"""M3 runtime scene 和 node 操作 E2E 测试"""

from __future__ import annotations

import time

import pytest

from .conftest import (
    exec_ok,
    exec_error,
    reset_fixture,
    runtime_route_source,
    wait_for,
)


def test_runtime_tree_root_name(m3_running):
    tree = exec_ok(m3_running, "runtime/scene/tree", {"max_depth": 3})
    assert tree["root"]["name"] == "RuntimeMain"
    children = tree["root"]["children"]
    names = {child["name"] for child in children}
    assert "ProbeTarget" in names
    assert "ProbeInput" in names


def test_shared_data_plane_stays_within_process_and_recovery_budget(m3_running):
    assert m3_running["editor_start_count"] == 1
    assert m3_running["game_run_count"] == 3  # two lifecycle cycles + one shared game
    assert m3_running["fixture_reset_restarts"] == 0
    assert m3_running["recovery_markers"] == []


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


def test_runtime_node_call_then_get_continuous_request(m3_running):
    path = "/root/RuntimeMain/ProbeTarget"
    call = exec_ok(m3_running, "runtime/node/call", {
        "node_path": path, "method": "increment", "args": [0],
    })
    assert call["result"] == 0.0
    current = exec_ok(m3_running, "runtime/node/get", {
        "node_path": path, "property": "counter",
    })
    assert current["value"] == 0


def test_fixture_reset_restores_shared_runtime_state(m3_running):
    path = "/root/RuntimeMain/ProbeTarget"
    exec_ok(m3_running, "runtime/node/set", {
        "node_path": path, "property": "position",
        "value": {"type": "Vector2", "value": [31, 42]},
    })
    exec_ok(m3_running, "runtime/node/call", {
        "node_path": path, "method": "increment", "args": [3],
    })
    exec_ok(m3_running, "runtime/node/call", {
        "node_path": path, "method": "increment_later", "args": [9, 100],
    })
    exec_ok(m3_running, "runtime/node/set", {
        "node_path": path, "property": "process_mode", "value": 4,
    })
    for route, payload in [
        ("runtime/input/key", {"keycode": 32, "pressed": True}),
        ("runtime/input/mouse", {"kind": "button", "button": 1, "pressed": True}),
        ("runtime/input/gamepad", {"device": 0, "button": 0, "pressed": True}),
        ("runtime/input/touch", {"index": 0, "pressed": True, "position": [1, 2]}),
    ]:
        exec_ok(m3_running, route, payload)
    exec_ok(m3_running, "runtime/input/action", {"action": "ui_accept", "pressed": True})
    exec_ok(m3_running, "runtime/node/call", {
        "node_path": path, "method": "emit_known_logs", "args": [],
    })
    created = exec_ok(m3_running, "runtime/node/create", {
        "parent_path": "/root/RuntimeMain", "type": "Node2D", "name": "Task10Created",
    })
    assert created["node_path"] == "/root/RuntimeMain/Task10Created"

    reset = reset_fixture(m3_running)
    assert reset["changed"] is True
    assert reset["undoable"] is False
    assert exec_ok(m3_running, "runtime/node/get", {
        "node_path": path, "property": "position",
    })["value"] == {"type": "Vector2", "value": [0.0, 0.0]}
    assert exec_ok(m3_running, "runtime/node/get", {
        "node_path": path, "property": "spawn_position",
    })["value"] == {"type": "Vector2", "value": [10.0, 20.0]}
    for name in ["counter", "input_keys", "input_mouse", "input_gamepad", "input_touch", "input_actions"]:
        assert exec_ok(m3_running, "runtime/node/get", {
            "node_path": path, "property": name,
        })["value"] == 0
    assert exec_ok(m3_running, "runtime/node/get", {
        "node_path": path, "property": "process_mode",
    })["value"] == 0
    time.sleep(0.2)
    assert exec_ok(m3_running, "runtime/node/get", {
        "node_path": path, "property": "counter",
    })["value"] == 0
    assert exec_error(m3_running, "runtime/node/info", {
        "node_path": "/root/RuntimeMain/Task10Created",
    })["code"] == "not_found"
    for dedicated in ["ProbeInput", "ProbeInputAction", "ProbeFinishedSignal"]:
        dedicated_path = f"/root/RuntimeMain/{dedicated}"
        assert exec_ok(m3_running, "runtime/node/info", {
            "node_path": dedicated_path,
        })["node_path"] == dedicated_path
    exec_ok(m3_running, "runtime/node/call", {
        "node_path": path, "method": "emit_finished", "args": [],
    })
    assert exec_ok(m3_running, "runtime/node/get", {
        "node_path": "/root/RuntimeMain/ProbeFinishedSignal",
        "property": "event_count",
    })["value"] == 1


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
    created = exec_ok(m3_running, "runtime/node/create", {
        "parent_path": "/root/RuntimeMain",
        "type": "Node2D",
        "name": "Task9DuplicateSource",
        "properties": {
            "position": {"type": "Vector2", "value": [31, 42]},
        },
    })
    source = created["node_path"]
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
    created = exec_ok(m3_running, "runtime/node/create", {
        "parent_path": "/root/RuntimeMain",
        "type": "Node2D",
        "name": "Task9RenameSource",
    })
    renamed = exec_ok(m3_running, "runtime/node/rename", {
        "node_path": created["node_path"],
        "name": "Task9Renamed",
    })
    assert renamed["changed"] is True
    assert renamed["undoable"] is False
    assert renamed["node_path"] == "/root/RuntimeMain/Task9Renamed"
    assert exec_error(m3_running, "runtime/node/info", {
        "node_path": created["node_path"],
    })["code"] == "not_found"
    assert exec_ok(m3_running, "runtime/node/info", {
        "node_path": renamed["node_path"],
    })["node_path"] == renamed["node_path"]


def test_runtime_node_mutations_reject_unsafe_targets_without_mutation(m3_running):
    source = exec_ok(m3_running, "runtime/node/create", {
        "parent_path": "/root/RuntimeMain",
        "type": "Node2D",
        "name": "Task9UnsafeSource",
    })["node_path"]
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
    assert exec_ok(m3_running, "runtime/node/info", {"node_path": source})["node_path"] == source


def test_runtime_reparent_rejects_self_after_game_dispatch_without_mutation(m3_running):
    source = exec_ok(m3_running, "runtime/node/create", {
        "parent_path": "/root/RuntimeMain", "type": "Node", "name": "Task15SelfSource",
    })["node_path"]
    before = exec_ok(m3_running, "runtime/scene/tree", {"max_depth": 4})

    # Both paths identify a live game node, so the stable cycle message can only
    # come from RuntimeProbe's NodeOps.reparent rather than route validation.
    error = exec_error(m3_running, "runtime/node/reparent", {
        "node_path": source, "new_parent": source,
    })
    assert error["code"] == "conflict"
    assert error["error"] == "reparent would create a cycle"

    after = exec_ok(m3_running, "runtime/scene/tree", {"max_depth": 4})
    assert after == before
    assert exec_ok(m3_running, "runtime/node/info", {"node_path": source})["node_path"] == source


def test_runtime_reparent_rejects_scene_root_after_game_dispatch_without_mutation(m3_running):
    new_parent = exec_ok(m3_running, "runtime/node/create", {
        "parent_path": "/root/RuntimeMain", "type": "Node", "name": "Task15RootDestination",
    })["node_path"]
    before = exec_ok(m3_running, "runtime/scene/tree", {"max_depth": 4})

    # A live dedicated destination and the NodeOps-specific error demonstrate
    # that this valid CLI/broker request reached the game-side operation.
    error = exec_error(m3_running, "runtime/node/reparent", {
        "node_path": "/root/RuntimeMain", "new_parent": new_parent,
    })
    assert error["code"] == "permission_denied"
    assert error["error"] == "node is not a reparentable fixture node"

    after = exec_ok(m3_running, "runtime/scene/tree", {"max_depth": 4})
    assert after == before
    assert exec_ok(m3_running, "runtime/node/info", {"node_path": new_parent})["node_path"] == new_parent


def test_runtime_reparent_rejects_descendant_cycle_after_game_dispatch(m3_running):
    parent = exec_ok(m3_running, "runtime/node/create", {
        "parent_path": "/root/RuntimeMain", "type": "Node", "name": "Task15CycleParent",
    })["node_path"]
    child = exec_ok(m3_running, "runtime/node/create", {
        "parent_path": "/root/RuntimeMain", "type": "Node", "name": "Task15CycleChild",
    })["node_path"]
    nested = exec_ok(m3_running, "runtime/node/reparent", {
        "node_path": child, "new_parent": parent,
    })
    child = nested["new_parent"] + "/Task15CycleChild"
    before = exec_ok(m3_running, "runtime/scene/tree", {"max_depth": 4})
    error = exec_error(m3_running, "runtime/node/reparent", {
        "node_path": parent, "new_parent": child,
    })
    assert error["code"] == "conflict"
    after = exec_ok(m3_running, "runtime/scene/tree", {"max_depth": 4})
    assert after == before


def test_runtime_infrastructure_nodes_reject_mutations(m3_running):
    infrastructure_nodes = ["ProbeInput", "ProbeInputAction", "ProbeFinishedSignal"]
    cases = []
    for index, name in enumerate(infrastructure_nodes):
        infrastructure = f"/root/RuntimeMain/{name}"
        cases.extend([
            ("runtime/node/set", {
                "node_path": infrastructure,
                "property": "process_mode",
                "value": 0,
            }),
            ("runtime/node/call", {
                "node_path": infrastructure,
                "method": "queue_free",
            }),
            ("runtime/node/duplicate", {
                "node_path": infrastructure,
                "name": f"Task9InfrastructureDuplicate{index}",
            }),
            ("runtime/node/rename", {
                "node_path": infrastructure,
                "name": f"Task9InfrastructureRenamed{index}",
            }),
            ("runtime/node/reparent", {
                "node_path": infrastructure,
                "new_parent": "/root/RuntimeMain/ProbeTarget",
            }),
            ("runtime/node/remove", {"node_path": infrastructure}),
        ])
    for route, payload in cases:
        error = exec_error(m3_running, route, payload)
        assert error["code"] == "permission_denied", (route, error)
    for name in infrastructure_nodes:
        infrastructure = f"/root/RuntimeMain/{name}"
        assert exec_ok(m3_running, "runtime/node/info", {"node_path": infrastructure})["node_path"] == infrastructure


@pytest.mark.parametrize(("route", "payload"), [
    ("runtime/node/duplicate", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "name": "Task10ProtectedDuplicate",
    }),
    ("runtime/node/rename", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "name": "Task10ProtectedRename",
    }),
    ("runtime/node/reparent", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "new_parent": "/root/RuntimeMain",
    }),
    ("runtime/node/remove", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
    }),
])
def test_runtime_fixed_fixture_identity_rejects_destructive_mutations(
    m3_running, route, payload
):
    error = exec_error(m3_running, route, payload)
    assert error["code"] == "permission_denied"
    target = "/root/RuntimeMain/ProbeTarget"
    assert exec_ok(m3_running, "runtime/node/info", {"node_path": target})["node_path"] == target


def test_runtime_created_node_can_reparent_and_remove(m3_running):
    created = exec_ok(m3_running, "runtime/node/create", {
        "parent_path": "/root/RuntimeMain",
        "type": "Node2D",
        "name": "Task9Mutable",
    })
    created_path = created["node_path"]
    moved = exec_ok(m3_running, "runtime/node/reparent", {
        "node_path": created_path,
        "new_parent": "/root/RuntimeMain/ProbeTarget",
    })
    assert moved["changed"] is True
    assert moved["undoable"] is False
    nested_path = "/root/RuntimeMain/ProbeTarget/Task9Mutable"
    moved_back = exec_ok(m3_running, "runtime/node/reparent", {
        "node_path": nested_path,
        "new_parent": "/root/RuntimeMain",
    })
    assert moved_back["changed"] is True
    removed = exec_ok(m3_running, "runtime/node/remove", {
        "node_path": created_path,
    })
    assert removed["changed"] is True
    assert removed["undoable"] is False
    assert exec_error(m3_running, "runtime/node/info", {"node_path": created_path})["code"] == "not_found"


def test_nested_runtime_node_named_like_fixture_remains_mutable(m3_running):
    collision = exec_ok(m3_running, "runtime/node/create", {
        "parent_path": "/root/RuntimeMain",
        "type": "Node2D",
        "name": "Task10Collision",
    })["node_path"]
    exec_ok(m3_running, "runtime/node/reparent", {
        "node_path": collision,
        "new_parent": "/root/RuntimeMain/ProbeTarget",
    })
    renamed = exec_ok(m3_running, "runtime/node/rename", {
        "node_path": "/root/RuntimeMain/ProbeTarget/Task10Collision",
        "name": "ProbeTarget",
    })
    nested_collision = "/root/RuntimeMain/ProbeTarget/ProbeTarget"
    assert renamed["node_path"] == nested_collision

    duplicate = exec_ok(m3_running, "runtime/node/duplicate", {
        "node_path": nested_collision,
        "name": "Task10CollisionCopy",
    })
    assert duplicate["node_path"] == "/root/RuntimeMain/ProbeTarget/Task10CollisionCopy"

    renamed_again = exec_ok(m3_running, "runtime/node/rename", {
        "node_path": nested_collision,
        "name": "Task10CollisionRenamed",
    })
    assert renamed_again["node_path"] == "/root/RuntimeMain/ProbeTarget/Task10CollisionRenamed"
    exec_ok(m3_running, "runtime/node/rename", {
        "node_path": renamed_again["node_path"],
        "name": "ProbeTarget",
    })

    container = exec_ok(m3_running, "runtime/node/create", {
        "parent_path": "/root/RuntimeMain",
        "type": "Node",
        "name": "Task10Container",
    })["node_path"]
    moved = exec_ok(m3_running, "runtime/node/reparent", {
        "node_path": nested_collision,
        "new_parent": container,
    })
    assert moved["new_parent"] == container

    moved_collision = "/root/RuntimeMain/Task10Container/ProbeTarget"
    removed = exec_ok(m3_running, "runtime/node/remove", {
        "node_path": moved_collision,
    })
    assert removed["removed"] == moved_collision
    assert exec_error(m3_running, "runtime/node/info", {
        "node_path": moved_collision,
    })["code"] == "not_found"
