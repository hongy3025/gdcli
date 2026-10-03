"""Resource route acceptance tests."""

import pytest

from .helpers import exec_error, exec_ok, tree_digest

MAIN_SCENE = "res://scenes/main.tscn"
PLAYER = "/root/Main/Player"


def _reopen_main_scene(editor) -> None:
    """Save-independent reload: close the edited scene and open it again from disk."""
    exec_ok(editor, "scene/close")
    exec_ok(editor, "scene/open", {"path": MAIN_SCENE})


def _get_property(editor, node_path: str, property_name: str):
    return exec_ok(editor, "node/property/get", {
        "node_path": node_path,
        "property": property_name,
    })["value"]


def test_resource_info_returns_class(m2_editor):
    info = exec_ok(m2_editor, "resource/info", {"path": "res://resources/player_data.tres"})
    assert info["class"] == "Resource"


def test_resource_search_finds_player(m2_editor):
    page = exec_ok(m2_editor, "resource/search", {
        "filter": "player", "offset": 0, "limit": 50,
    })
    assert any("player" in p for p in page["items"])


def test_resource_assign_rejects_non_resource_property(m2_editor):
    """资源必须存在于项目中，失败必须来自「属性不是资源槽位」而非常量路径缺失。"""
    error = exec_error(m2_editor, "resource/assign", {
        "node_path": PLAYER,
        "property": "position",
        "path": "res://resources/player_data.tres",
    })
    assert error["code"] == "invalid_param", error
    assert "position" in error["error"], error


def test_typed_properties_round_trip_and_survive_reopen(m2_editor):
    """Color / NodePath / Resource values must survive a real scene save + reload."""
    color_value = {"type": "Color", "value": [0.25, 0.5, 0.75, 1.0]}
    path_value = {"type": "NodePath", "value": "Player/Child"}
    material_path = "res://resources/typed_material.tres"

    set_color = exec_ok(m2_editor, "node/property/set", {
        "node_path": PLAYER, "property": "modulate", "value": color_value,
    })
    assert set_color["value"] == color_value

    created = exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "AnimationPlayer", "name": "TypedPath",
    })
    typed_node = created["node_path"]
    set_path = exec_ok(m2_editor, "node/property/set", {
        "node_path": typed_node, "property": "root_node", "value": path_value,
    })
    assert set_path["value"] == path_value

    material = exec_ok(m2_editor, "resource/create", {
        "path": material_path,
        "type": "StandardMaterial3D",
        "properties": {"resource_name": "TypedMaterial"},
    })
    assert material["saved"] is True
    resource_value = {"type": "Resource", "value": material_path}
    set_resource = exec_ok(m2_editor, "node/property/set", {
        "node_path": PLAYER, "property": "material", "value": resource_value,
    })
    assert set_resource["value"] == resource_value

    expectations = (
        (PLAYER, "modulate", color_value),
        (typed_node, "root_node", path_value),
        (PLAYER, "material", resource_value),
    )
    for node_path, property_name, expected in expectations:
        assert _get_property(m2_editor, node_path, property_name) == expected

    exec_ok(m2_editor, "scene/current/save")
    _reopen_main_scene(m2_editor)

    for node_path, property_name, expected in expectations:
        assert _get_property(m2_editor, node_path, property_name) == expected


def test_resource_assign_persists_across_save_and_reopen(m2_editor):
    """resource/assign must really write the node property and survive a reload."""
    material_path = "res://resources/assigned_material.tres"
    created = exec_ok(m2_editor, "resource/create", {
        "path": material_path,
        "type": "StandardMaterial3D",
        "properties": {"resource_name": "AssignedMaterial"},
    })
    assert created["saved"] is True

    expected = {"type": "Resource", "value": material_path}
    # A null Object property is encoded as "<Object#null>", never as the resource
    # we are about to assign; this proves `assign` actually changed the property.
    assert _get_property(m2_editor, PLAYER, "material") != expected
    assigned = exec_ok(m2_editor, "resource/assign", {
        "node_path": PLAYER, "property": "material", "path": material_path,
    })
    assert assigned["undoable"] is True
    assert assigned["path"] == material_path

    assert _get_property(m2_editor, PLAYER, "material") == expected

    exec_ok(m2_editor, "scene/current/save")
    _reopen_main_scene(m2_editor)
    assert _get_property(m2_editor, PLAYER, "material") == expected


def test_resource_overwrite_without_force(m2_editor):
    overwritten = exec_ok(m2_editor, "resource/create", {
        "path": "res://resources/player_data.tres",
        "type": "Resource",
        "properties": {"resource_name": "Other"},
    })
    assert overwritten["saved"] is True


def test_resource_create_assign_delete_round_trip(m2_editor):
    create_result = exec_ok(m2_editor, "resource/create", {
        "path": "res://resources/generated.tres",
        "type": "Resource",
        "properties": {"resource_name": "Generated"},
    })
    assert create_result["saved"] is True
    deleted = exec_ok(m2_editor, "resource/delete", {
        "path": "res://resources/generated.tres"
    })
    assert deleted["deleted"] is True


def test_resource_files_untouched_on_rejection(m2_editor):
    before = tree_digest(m2_editor["project"])
    exec_error(m2_editor, "resource/delete", {"path": "res://addons/gdapi/plugin.gd"})
    assert tree_digest(m2_editor["project"]) == before
