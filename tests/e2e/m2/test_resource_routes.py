"""Resource route acceptance tests."""

import pytest

from .helpers import editor_redo, editor_undo, exec_error, exec_ok, tree_digest

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
        "type": "CanvasItemMaterial",
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
        "type": "CanvasItemMaterial",
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



def test_resource_overwrite_refreshes_cache_for_assign_and_read(m2_editor):
    path = "res://resources/overwrite_cache_material.tres"
    exec_ok(m2_editor, "resource/create", {
        "path": path,
        "type": "CanvasItemMaterial",
        "properties": {"resource_name": "BeforeOverwrite"},
    })
    assert exec_ok(m2_editor, "resource/info", {"path": path})["properties"][
        "resource_name"
    ] == "BeforeOverwrite"

    overwritten = exec_ok(m2_editor, "resource/create", {
        "path": path,
        "type": "CanvasItemMaterial",
        "properties": {"resource_name": "AfterOverwrite"},
    })
    assert overwritten["saved"] is True
    assert exec_ok(m2_editor, "resource/info", {"path": path})["properties"][
        "resource_name"
    ] == "AfterOverwrite"

    expected = {"type": "Resource", "value": path}
    exec_ok(m2_editor, "resource/assign", {
        "node_path": PLAYER, "property": "material", "path": path,
    })
    assert _get_property(m2_editor, PLAYER, "material") == expected
    exec_ok(m2_editor, "resource/delete", {"path": path})

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


def test_resource_assign_checks_subclass_and_preserves_undo_redo_on_rejection(m2_editor):
    material = "res://resources/assign_wrong_material.tres"
    texture = "res://resources/assign_texture.tres"
    exec_ok(m2_editor, "resource/create", {"path": material, "type": "StandardMaterial3D"})
    exec_ok(m2_editor, "resource/create", {"path": texture, "type": "GradientTexture2D"})
    target = exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Sprite2D", "name": "AssignmentSprite",
    })["node_path"]
    original_texture = _get_property(m2_editor, target, "texture")
    marker = {"type": "Vector2", "value": [17, 23]}
    exec_ok(m2_editor, "node/property/set", {
        "node_path": target, "property": "position", "value": marker,
    })
    editor_undo(m2_editor)
    error = exec_error(m2_editor, "resource/assign", {
        "node_path": target, "property": "texture", "path": material,
    })
    assert error["code"] == "invalid_param", error
    assert _get_property(m2_editor, target, "texture") == original_texture
    editor_redo(m2_editor)
    assert _get_property(m2_editor, target, "position") == marker

    result = exec_ok(m2_editor, "resource/assign", {
        "node_path": target, "property": "texture", "path": texture,
    })
    assert result["changed"] is True and result["undoable"] is True
    expected = {"type": "Resource", "value": texture}
    assert _get_property(m2_editor, target, "texture") == expected
    error = exec_error(m2_editor, "resource/assign", {
        "node_path": target, "property": "texture", "path": material,
    })
    assert error["code"] == "invalid_param", error
    assert _get_property(m2_editor, target, "texture") == expected
    editor_undo(m2_editor)
    assert _get_property(m2_editor, target, "texture") == original_texture
    editor_redo(m2_editor)
    assert _get_property(m2_editor, target, "texture") == expected


def test_resource_assign_custom_script_inheritance_multiple_hints_and_setter_rejection(m2_editor):
    base_script = "res://scripts/assignment_data.gd"
    child_script = "res://scripts/assignment_child.gd"
    holder_script = "res://scripts/assignment_holder.gd"
    sources = {
        base_script: (
            "@tool\nclass_name AssignmentIntegrityResource\nextends Resource\n"
            "@export var score: int = 7\n"
        ),
        child_script: (
            '@tool\nextends "res://scripts/assignment_data.gd"\n'
            "@export var extra: int = 11\n"
        ),
        holder_script: (
            "@tool\nextends Node2D\n"
            'const Data = preload("res://scripts/assignment_data.gd")\n'
            "@export var data: Data\n"
            '@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "Texture2D,Material")\n'
            "var flexible: Resource\n"
            "@export var texture: Texture2D:\n"
            "\tset(value):\n"
            '\t\tif value != null and value.resource_name == "BlockedTexture":\n'
            "\t\t\treturn\n"
            "\t\ttexture = value\n"
        ),
    }
    for path, source in sources.items():
        exec_ok(m2_editor, "script/write", {"path": path, "content": source})
    child = "res://resources/assignment_child.tres"
    exec_ok(m2_editor, "filesystem/write", {
        "path": child,
        "content": (
            '[gd_resource type="Resource" script_class="AssignmentIntegrityResource" '
            'load_steps=2 format=3]\n'
            f'[ext_resource type="Script" path="{child_script}" id="1"]\n'
            '[resource]\nscript = ExtResource("1")\nscore = 19\nextra = 23\n'
        ),
    })
    material = "res://resources/assignment_flexible_material.tres"
    texture = "res://resources/assignment_flexible_texture.tres"
    blocked = "res://resources/assignment_blocked_texture.tres"
    for path, kind, properties in (
        (material, "StandardMaterial3D", {}),
        (texture, "GradientTexture2D", {}),
        (blocked, "GradientTexture2D", {"resource_name": "BlockedTexture"}),
    ):
        exec_ok(m2_editor, "resource/create", {
            "path": path, "type": kind, "properties": properties,
        })
    target = exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Node2D", "name": "AssignmentHolder",
    })["node_path"]
    exec_ok(m2_editor, "script/attach", {"node_path": target, "path": holder_script})

    original_data = _get_property(m2_editor, target, "data")
    error = exec_error(m2_editor, "resource/assign", {
        "node_path": target, "property": "data", "path": material,
    })
    assert error["code"] == "invalid_param", error
    assert _get_property(m2_editor, target, "data") == original_data
    exec_ok(m2_editor, "resource/assign", {
        "node_path": target, "property": "data", "path": child,
    })
    assert _get_property(m2_editor, target, "data") == {"type": "Resource", "value": child}
    editor_undo(m2_editor)
    assert _get_property(m2_editor, target, "data") == original_data
    editor_redo(m2_editor)
    for path in (texture, material):
        exec_ok(m2_editor, "resource/assign", {
            "node_path": target, "property": "flexible", "path": path,
        })
        assert _get_property(m2_editor, target, "flexible") == {"type": "Resource", "value": path}

    original_texture = _get_property(m2_editor, target, "texture")
    exec_ok(m2_editor, "resource/assign", {
        "node_path": target, "property": "texture", "path": texture,
    })
    editor_undo(m2_editor)
    error = exec_error(m2_editor, "resource/assign", {
        "node_path": target, "property": "texture", "path": blocked,
    })
    assert error["code"] == "godot_error", error
    assert _get_property(m2_editor, target, "texture") == original_texture
    editor_redo(m2_editor)
    assert _get_property(m2_editor, target, "texture") == {"type": "Resource", "value": texture}
    exec_ok(m2_editor, "scene/current/save")
    _reopen_main_scene(m2_editor)
    assert _get_property(m2_editor, target, "data") == {"type": "Resource", "value": child}
    assert _get_property(m2_editor, target, "flexible") == {"type": "Resource", "value": material}
    assert _get_property(m2_editor, target, "texture") == {"type": "Resource", "value": texture}
