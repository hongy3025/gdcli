"""2D physics construction M4 route contracts."""

from .helpers import command_doc, editor_undo, exec_error, exec_ok


PHYSICS_ROUTES = {"physics/body/create", "physics/shape/create", "physics/layer/set", "physics/raycast", "physics/joint/create"}


def test_physics_routes_are_discoverable_and_documented(m4_env):
    routes = set(exec_ok(m4_env, "gdapi/routes")["routes"])
    for route in sorted(PHYSICS_ROUTES):
        assert route in routes
        assert command_doc(m4_env, route)["summary"]


def test_physics_body_and_shape_are_undoable_and_3d_is_rejected(m4_env):
    exec_ok(m4_env, "scene/open", {"path": "res://scenes/physics.tscn"})
    body = exec_ok(m4_env, "physics/body/create", {"parent_path": "PhysicsDomain", "name": "Body", "type": "StaticBody2D"})
    assert body["undoable"] is True
    shape = exec_ok(m4_env, "physics/shape/create", {"body_path": "Body", "shape": "rectangle", "size": {"x": 10, "y": 10}})
    assert shape["undoable"] is True
    editor_undo(m4_env)
    assert exec_error(m4_env, "physics/body/create", {"parent_path": "PhysicsDomain", "name": "Bad", "type": "StaticBody3D"})["code"] == "not_supported"


def _property(m4_env, node_path: str, property_name: str):
    return exec_ok(
        m4_env,
        "node/property/get",
        {"node_path": node_path, "property": property_name},
    )["value"]


def test_physics_layer_set_reads_back_and_undo_restores(m4_env):
    """A faked layer write must not survive a read-back or an editor undo."""
    exec_ok(m4_env, "scene/open", {"path": "res://scenes/physics.tscn"})
    created = exec_ok(
        m4_env,
        "physics/body/create",
        {"parent_path": "PhysicsDomain", "name": "Layered", "type": "StaticBody2D"},
    )
    node_path = created["node_path"]
    assert node_path == "/root/PhysicsDomain/Layered"
    assert _property(m4_env, node_path, "collision_layer") == 1
    changed = exec_ok(
        m4_env,
        "physics/layer/set",
        {"node_path": "Layered", "property": "collision_layer", "value": 5},
    )
    assert changed["undoable"] is True
    assert _property(m4_env, node_path, "collision_layer") == 5
    editor_undo(m4_env)
    assert _property(m4_env, node_path, "collision_layer") == 1


def test_physics_joint_create_reads_back_and_undo_removes_node(m4_env):
    """A no-op joint creation must fail the node/parameter read-back and the undo check."""
    exec_ok(m4_env, "scene/open", {"path": "res://scenes/physics.tscn"})
    created = exec_ok(
        m4_env,
        "physics/joint/create",
        {"parent_path": "PhysicsDomain", "type": "PinJoint2D", "name": "Pivot"},
    )
    assert created["undoable"] is True
    assert created["type"] == "PinJoint2D"
    node_path = created["node_path"]
    assert exec_ok(m4_env, "node/get", {"node_path": node_path})["type"] == "PinJoint2D"
    assert _property(m4_env, node_path, "softness") == 0.0
    editor_undo(m4_env)
    assert exec_error(m4_env, "node/get", {"node_path": node_path})["code"] == "not_found"

