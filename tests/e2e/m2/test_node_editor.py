"""Node and property edit acceptance tests."""

from __future__ import annotations

from pathlib import Path

import pytest

from .helpers import editor_redo, editor_undo, exec_error, exec_ok


def test_node_create_then_rename_set_round_trip(m2_editor, m2_main):
    created = exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Sprite2D", "name": "RoundTripIcon"
    })
    assert created["undoable"] is True
    renamed = exec_ok(m2_editor, "node/rename", {
        "node_path": "/root/Main/RoundTripIcon", "name": "RoundTripAvatar"
    })
    assert renamed["node_path"] == "/root/Main/RoundTripAvatar"
    set_result = exec_ok(m2_editor, "node/property/set", {
        "node_path": "/root/Main/RoundTripAvatar",
        "property": "position",
        "value": {"type": "Vector2", "value": [24, 32]},
    })
    assert set_result["undoable"] is True
    prop = exec_ok(m2_editor, "node/property/get", {
        "node_path": "/root/Main/RoundTripAvatar",
        "property": "position",
    })
    assert prop["value"] == {"type": "Vector2", "value": [24.0, 32.0]}


def test_node_property_round_trip_uses_codec(m2_editor, m2_main):
    exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Node2D", "name": "CodecRoundTrip"
    })
    exec_ok(m2_editor, "node/property/set", {
        "node_path": "/root/Main/CodecRoundTrip",
        "property": "position",
        "value": {"type": "Vector2", "value": [11, 22]},
    })
    result = exec_ok(m2_editor, "node/property/get", {
        "node_path": "/root/Main/CodecRoundTrip",
        "property": "position",
    })
    assert result["value"] == {"type": "Vector2", "value": [11.0, 22.0]}


def test_node_mutations_are_stepwise_undoable(m2_editor, m2_main):
    """Insert three actions and step through undo/redo via the test plugin."""
    exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Sprite2D", "name": "UndoIcon"
    })
    exec_ok(m2_editor, "node/rename", {
        "node_path": "/root/Main/UndoIcon", "name": "UndoAvatar"
    })
    exec_ok(m2_editor, "node/property/set", {
        "node_path": "/root/Main/UndoAvatar",
        "property": "position",
        "value": {"type": "Vector2", "value": [24, 32]},
    })
    editor_undo(m2_editor)
    pos = exec_ok(m2_editor, "node/property/get", {
        "node_path": "/root/Main/UndoAvatar", "property": "position"
    })["value"]
    assert pos == {"type": "Vector2", "value": [0.0, 0.0]}
    editor_undo(m2_editor)
    info = exec_ok(m2_editor, "node/get", {"node_path": "/root/Main/UndoIcon"})
    assert info["name"] == "UndoIcon"
    editor_undo(m2_editor)
    error = exec_error(m2_editor, "node/get", {"node_path": "/root/Main/UndoIcon"})
    assert error["code"] == "not_found"
    editor_redo(m2_editor)
    editor_redo(m2_editor)
    editor_redo(m2_editor)
    info = exec_ok(m2_editor, "node/get", {"node_path": "/root/Main/UndoAvatar"})
    assert info["name"] == "UndoAvatar"


@pytest.mark.parametrize("route,data,code", [
    ("node/get", {"node_path": "/root/Main/Missing"}, "not_found"),
    ("node/create", {"parent_path": "/root/Main", "type": "MissingClass", "name": "Bad"}, "invalid_param"),
    ("node/delete", {"node_path": "/root/Main"}, "permission_denied"),
    ("node/reparent", {"node_path": "/root/Main/Player", "parent_path": "/root/Main/Player/Child"}, "conflict"),
    ("node/property/set", {"node_path": "/root/Main/Player", "property": "script/source_code", "value": "x"}, "permission_denied"),
    ("node/property/set", {"node_path": "/root/Main/Player", "property": "position", "value": {"type": "Vector2", "value": [1]}}, "invalid_param"),
])
def test_node_rejections_are_atomic(m2_editor, m2_main, route, data, code):
    before = exec_ok(m2_editor, "scene/tree")
    error = exec_error(m2_editor, route, data)
    assert error["code"] == code
    assert exec_ok(m2_editor, "scene/tree") == before


def test_node_set_rejects_invalid_property_before_mutation(m2_editor, m2_main):
    exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Sprite2D", "name": "AtomicPropertySet"
    })
    before = exec_ok(m2_editor, "node/property/get", {
        "node_path": "/root/Main/AtomicPropertySet", "property": "position"
    })
    assert before["value"] == {"type": "Vector2", "value": [0.0, 0.0]}
    error = exec_error(m2_editor, "node/set", {
        "node_path": "/root/Main/AtomicPropertySet",
        "properties": {"script": "x"},
    })
    assert error["code"] == "permission_denied"
    after = exec_ok(m2_editor, "node/property/get", {
        "node_path": "/root/Main/AtomicPropertySet", "property": "position"
    })
    assert after == before


def _write_static_init_resource(editor: dict, token: str) -> tuple[str, Path]:
    """Create a first-load user:// script whose static initializer leaves evidence."""
    project = Path(editor["project"])
    user_dir = (
        project / ".godot" / "appdata" / "Godot" / "app_userdata" / "gdcli_e2e_fixture"
    )
    user_dir.mkdir(parents=True, exist_ok=True)
    script_name = f"gdapi_forbidden_{token}.gd"
    marker_name = f"gdapi_forbidden_{token}.marker"
    (user_dir / script_name).write_text(
        "extends RefCounted\n"
        "static func _static_init() -> void:\n"
        f'\tvar marker := FileAccess.open("user://{marker_name}", FileAccess.WRITE)\n'
        '\tmarker.store_string("loaded")\n'
        "\tmarker.close()\n",
        encoding="utf-8",
    )
    return f"user://{script_name}", user_dir / marker_name


def test_node_metadata_rejects_resource_before_first_load(m2_editor, m2_main):
    import uuid

    resource, marker = _write_static_init_resource(m2_editor, uuid.uuid4().hex)
    assert not marker.exists()
    error = exec_error(m2_editor, "node/meta/set", {
        "node_path": "/root/Main",
        "key": "unsafe",
        "value": {"type": "Resource", "value": resource},
    })
    assert error["code"] == "invalid_param"
    assert error["error"] == "metadata requires a non-null serializable value"
    assert not marker.exists()


def test_node_call_rejects_resource_before_first_load(m2_editor, m2_main):
    import uuid

    resource, marker = _write_static_init_resource(m2_editor, uuid.uuid4().hex)
    assert not marker.exists()
    error = exec_error(m2_editor, "node/call", {
        "node_path": "/root/Main",
        "method": "is_in_group",
        "args": [{"type": "Resource", "value": resource}],
    })
    assert error["code"] == "permission_denied"
    assert error["error"] == "object/callable/signal arguments are forbidden"
    assert not marker.exists()


def test_node_non_object_consumers_reject_nested_object_tags(m2_editor, m2_main):
    import uuid

    resource, marker = _write_static_init_resource(m2_editor, uuid.uuid4().hex)
    for tag in ("Resource", "Object"):
        nested = {"items": [{"nested": {"type": tag, "value": resource}}]}
        meta_error = exec_error(m2_editor, "node/meta/set", {
            "node_path": "/root/Main", "key": f"unsafe_nested_{tag.lower()}", "value": nested,
        })
        call_error = exec_error(m2_editor, "node/call", {
            "node_path": "/root/Main", "method": "is_in_group", "args": [nested],
        })
        assert meta_error["code"] == "invalid_param"
        assert meta_error["error"] == "metadata requires a non-null serializable value"
        assert call_error["code"] == "permission_denied"
        assert call_error["error"] == "object/callable/signal arguments are forbidden"
    assert not marker.exists()

def test_node_non_object_consumers_keep_valid_values(m2_editor, m2_main):
    result = exec_ok(m2_editor, "node/meta/set", {
        "node_path": "/root/Main", "key": "safe_value", "value": {"answer": 42},
    })
    assert result["value"] == {"answer": 42}
    called = exec_ok(m2_editor, "node/call", {
        "node_path": "/root/Main", "method": "is_in_group", "args": ["unused_group"],
    })
    assert called["result"] is False


def test_node_list_and_property_list(m2_editor, m2_main):
    children = exec_ok(m2_editor, "node/list", {"node_path": "/root/Main"})
    assert {(c["name"], c["type"]) for c in children["children"]} >= {("Player", "Node2D"), ("Target", "Node2D")}
    props = exec_ok(m2_editor, "node/property/list", {"node_path": "/root/Main/Player"})
    names = [p["name"] for p in props["properties"]]
    assert "position" in names


def _child_names(editor: dict, node_path: str) -> list[str]:
    return [child["name"] for child in exec_ok(editor, "node/list", {"node_path": node_path})["children"]]


def test_node_delete_undo_restores_parent_and_index(m2_editor, m2_main):
    """delete detaches the node; undo re-attaches it to the same parent at the same index."""
    exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Node2D", "name": "DeleteIndexAlpha"
    })
    exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Node2D", "name": "DeleteIndexBeta"
    })
    before = _child_names(m2_editor, "/root/Main")
    assert before[-2:] == ["DeleteIndexAlpha", "DeleteIndexBeta"]

    deleted = exec_ok(m2_editor, "node/delete", {"node_path": "/root/Main/DeleteIndexAlpha"})
    assert deleted["undoable"] is True
    assert _child_names(m2_editor, "/root/Main") == [name for name in before if name != "DeleteIndexAlpha"]
    assert exec_error(m2_editor, "node/get", {"node_path": "/root/Main/DeleteIndexAlpha"})["code"] == "not_found"

    editor_undo(m2_editor)
    restored = exec_ok(m2_editor, "node/get", {"node_path": "/root/Main/DeleteIndexAlpha"})
    assert restored["name"] == "DeleteIndexAlpha"
    # Parent is correct because the path resolves under /root/Main again.
    assert restored["node_path"] == "/root/Main/DeleteIndexAlpha"
    # Sibling order proves the original index was restored, not appended.
    assert _child_names(m2_editor, "/root/Main") == before


def test_node_delete_redo_removes_node_again(m2_editor, m2_main):
    """Redo of a delete re-applies remove_child so the node is unreachable again."""
    exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Node2D", "name": "DeleteRedoAlpha"
    })
    exec_ok(m2_editor, "node/delete", {"node_path": "/root/Main/DeleteRedoAlpha"})
    editor_undo(m2_editor)
    assert exec_ok(m2_editor, "node/get", {"node_path": "/root/Main/DeleteRedoAlpha"})["name"] == "DeleteRedoAlpha"

    editor_redo(m2_editor)
    assert exec_error(m2_editor, "node/get", {"node_path": "/root/Main/DeleteRedoAlpha"})["code"] == "not_found"
    assert "DeleteRedoAlpha" not in _child_names(m2_editor, "/root/Main")


def test_node_delete_two_step_undo_redo_keeps_scene_tree_consistent(m2_editor, m2_main):
    """Two consecutive delete/undo/redo cycles restore the tree exactly, with no orphans."""
    exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Node2D", "name": "DeleteCycleAlpha"
    })
    exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Node2D", "name": "DeleteCycleBeta"
    })
    baseline = exec_ok(m2_editor, "scene/tree")
    names = _child_names(m2_editor, "/root/Main")
    remaining = [name for name in names if name not in {"DeleteCycleAlpha", "DeleteCycleBeta"}]

    exec_ok(m2_editor, "node/delete", {"node_path": "/root/Main/DeleteCycleAlpha"})
    exec_ok(m2_editor, "node/delete", {"node_path": "/root/Main/DeleteCycleBeta"})
    assert _child_names(m2_editor, "/root/Main") == remaining

    editor_undo(m2_editor)
    editor_undo(m2_editor)
    # scene/tree only lists children with an owner, so equality also proves no orphan node.
    assert exec_ok(m2_editor, "scene/tree") == baseline
    assert _child_names(m2_editor, "/root/Main") == names
    for name in ("DeleteCycleAlpha", "DeleteCycleBeta"):
        assert exec_ok(m2_editor, "node/get", {"node_path": "/root/Main/" + name})["name"] == name

    editor_redo(m2_editor)
    editor_redo(m2_editor)
    assert _child_names(m2_editor, "/root/Main") == remaining
    for name in ("DeleteCycleAlpha", "DeleteCycleBeta"):
        error = exec_error(m2_editor, "node/get", {"node_path": "/root/Main/" + name})
        assert error["code"] == "not_found"
