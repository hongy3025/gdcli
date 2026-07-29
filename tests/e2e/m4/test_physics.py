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

