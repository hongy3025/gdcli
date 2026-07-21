"""Node and property edit acceptance tests."""

from __future__ import annotations

import pytest

from .helpers import editor_redo, editor_undo, exec_error, exec_ok, tree_digest


def test_node_create_then_rename_set_round_trip(m2_editor):
    created = exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Sprite2D", "name": "Icon"
    })
    assert created["undoable"] is True
    renamed = exec_ok(m2_editor, "node/rename", {
        "node_path": "/root/Main/Icon", "name": "Avatar"
    })
    assert renamed["node_path"] == "/root/Main/Avatar"
    set_result = exec_ok(m2_editor, "node/property/set", {
        "node_path": "/root/Main/Avatar",
        "property": "position",
        "value": {"type": "Vector2", "value": [24, 32]},
    })
    assert set_result["undoable"] is True
    prop = exec_ok(m2_editor, "node/property/get", {
        "node_path": "/root/Main/Avatar",
        "property": "position",
    })
    assert prop["value"] == {"type": "Vector2", "value": [24.0, 32.0]}


def test_node_property_round_trip_uses_codec(m2_editor):
    exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Node2D", "name": "T"
    })
    exec_ok(m2_editor, "node/property/set", {
        "node_path": "/root/Main/T",
        "property": "position",
        "value": {"type": "Vector2", "value": [11, 22]},
    })
    result = exec_ok(m2_editor, "node/property/get", {
        "node_path": "/root/Main/T",
        "property": "position",
    })
    assert result["value"] == {"type": "Vector2", "value": [11.0, 22.0]}


def test_node_mutations_are_stepwise_undoable(m2_editor):
    """Insert three actions and step through undo/redo via the test plugin."""
    exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Sprite2D", "name": "Icon"
    })
    exec_ok(m2_editor, "node/rename", {
        "node_path": "/root/Main/Icon", "name": "Avatar"
    })
    exec_ok(m2_editor, "node/property/set", {
        "node_path": "/root/Main/Avatar",
        "property": "position",
        "value": {"type": "Vector2", "value": [24, 32]},
    })
    editor_undo(m2_editor)
    pos = exec_ok(m2_editor, "node/property/get", {
        "node_path": "/root/Main/Avatar", "property": "position"
    })["value"]
    assert pos == {"type": "Vector2", "value": [0.0, 0.0]}
    editor_undo(m2_editor)
    info = exec_ok(m2_editor, "node/get", {"node_path": "/root/Main/Icon"})
    assert info["name"] == "Icon"
    editor_undo(m2_editor)
    error = exec_error(m2_editor, "node/get", {"node_path": "/root/Main/Icon"})
    assert error["code"] == "not_found"
    editor_redo(m2_editor)
    editor_redo(m2_editor)
    editor_redo(m2_editor)
    info = exec_ok(m2_editor, "node/get", {"node_path": "/root/Main/Avatar"})
    assert info["name"] == "Avatar"


@pytest.mark.parametrize("route,data,code", [
    ("node/get", {"node_path": "/root/Main/Missing"}, "not_found"),
    ("node/create", {"parent_path": "/root/Main", "type": "MissingClass", "name": "Bad"}, "invalid_param"),
    ("node/delete", {"node_path": "/root/Main"}, "permission_denied"),
    ("node/reparent", {"node_path": "/root/Main/Player", "parent_path": "/root/Main/Player/Child"}, "conflict"),
    ("node/property/set", {"node_path": "/root/Main/Player", "property": "script/source_code", "value": "x"}, "permission_denied"),
    ("node/property/set", {"node_path": "/root/Main/Player", "property": "position", "value": {"type": "Vector2", "value": [1]}}, "invalid_param"),
])
def test_node_rejections_are_atomic(m2_editor, route, data, code):
    before = exec_ok(m2_editor, "scene/tree")
    error = exec_error(m2_editor, route, data)
    assert error["code"] == code
    assert exec_ok(m2_editor, "scene/tree") == before


def test_node_set_rejects_invalid_property_before_mutation(m2_editor):
    exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Sprite2D", "name": "H"
    })
    before = exec_ok(m2_editor, "node/property/get", {
        "node_path": "/root/Main/H", "property": "position"
    })
    assert before["value"] == {"type": "Vector2", "value": [0.0, 0.0]}
    error = exec_error(m2_editor, "node/set", {
        "node_path": "/root/Main/H",
        "properties": {"script": "x"},
    })
    assert error["code"] == "permission_denied"
    after = exec_ok(m2_editor, "node/property/get", {
        "node_path": "/root/Main/H", "property": "position"
    })
    assert after == before


def test_node_list_and_property_list(m2_editor):
    children = exec_ok(m2_editor, "node/list", {"node_path": "/root/Main"})
    assert {(c["name"], c["type"]) for c in children["children"]} >= {("Player", "Node2D"), ("Target", "Node2D")}
    props = exec_ok(m2_editor, "node/property/list", {"node_path": "/root/Main/Player"})
    names = [p["name"] for p in props["properties"]]
    assert "position" in names
