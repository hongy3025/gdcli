"""T8 editor controls: real state, UndoRedo, persistence and guarded dispatch."""
from __future__ import annotations

import re
from pathlib import Path

import pytest

from .helpers import exec_error, exec_ok


LINKED_SCENE = '''[gd_scene format=3]

[node name="Linked" type="Node2D"]

[node name="Marker" type="Marker2D" parent="."]
position = Vector2(7, 9)
'''


def write_scene(env, path="res://scenes/controls_linked.tscn"):
    exec_ok(env, "filesystem/write", {"path": path, "content": LINKED_SCENE})
    return path


def reopen_main(env):
    exec_ok(env, "scene/close")
    exec_ok(env, "scene/open", {"path": "res://scenes/main.tscn"})


def test_metadata_typed_undo_redo_remove_and_reopen(m2_editor, m2_main):
    target = {"node_path": "/root/Main/Player", "key": "controls_origin"}
    value = {"type": "Vector2", "value": [21, 34]}
    changed = exec_ok(m2_editor, "node/meta/set", {**target, "value": value})
    assert changed["undoable"] is True
    assert exec_ok(m2_editor, "node/meta/get", target)["value"] == value
    exec_ok(m2_editor, "editor/undo")
    assert exec_error(m2_editor, "node/meta/get", target)["code"] == "not_found"
    exec_ok(m2_editor, "editor/redo")
    assert exec_ok(m2_editor, "node/meta/get", target)["value"] == value
    exec_ok(m2_editor, "node/meta/remove", target)
    assert exec_error(m2_editor, "node/meta/get", target)["code"] == "not_found"
    exec_ok(m2_editor, "editor/undo")
    exec_ok(m2_editor, "scene/current/save")
    reopen_main(m2_editor)
    assert exec_ok(m2_editor, "node/meta/get", target)["value"] == value
    exec_ok(m2_editor, "node/meta/remove", target)
    exec_ok(m2_editor, "scene/current/save")
    reopen_main(m2_editor)
    assert exec_error(m2_editor, "node/meta/get", target)["code"] == "not_found"


@pytest.mark.parametrize("key", ["gdapi_callable_methods", "gdapi_runtime_dedicated", "_edit_lock_"])
def test_metadata_cannot_grant_call_authority(m2_editor, m2_main, key):
    data = {"node_path": "/root/Main/Player", "key": key, "value": ["free"]}
    assert exec_error(m2_editor, "node/meta/set", data)["code"] == "permission_denied"
    assert exec_error(m2_editor, "node/meta/remove", data)["code"] == "permission_denied"


def test_scene_instance_link_ownership_undo_and_saved_reopen(m2_editor, m2_main):
    source = write_scene(m2_editor)
    result = exec_ok(m2_editor, "scene/instantiate", {
        "path": source, "parent_path": "/root/Main", "name": "LinkedCopy",
    })
    assert result["node_path"] == "/root/Main/LinkedCopy"
    assert result["scene_file_path"] == source and result["undoable"] is True
    child = {"node_path": "/root/Main/LinkedCopy/Marker", "property": "position"}
    assert exec_ok(m2_editor, "node/property/get", child)["value"] == {
        "type": "Vector2", "value": [7, 9],
    }
    exec_ok(m2_editor, "editor/undo")
    assert exec_error(m2_editor, "node/get", {"node_path": "/root/Main/LinkedCopy"})["code"] == "not_found"
    exec_ok(m2_editor, "editor/redo")
    assert exec_ok(m2_editor, "node/property/get", child)["value"]["value"] == [7, 9]
    exec_ok(m2_editor, "scene/current/save")
    reopen_main(m2_editor)
    tree = exec_ok(m2_editor, "scene/tree")["root"]
    linked = next(n for n in tree["children"] if n["name"] == "LinkedCopy")
    assert linked["scene_file_path"] == source
    assert exec_ok(m2_editor, "node/property/get", child)["value"]["value"] == [7, 9]
    assert exec_error(m2_editor, "scene/delete", {"path": source})["code"] == "conflict"
    preview = exec_ok(m2_editor, "scene/delete", {"path": source, "dry_run": True})
    assert preview["can_delete"] is False
    assert "res://scenes/main.tscn" in preview["references"]
    exec_ok(m2_editor, "node/delete", {"node_path": "/root/Main/LinkedCopy"})
    exec_ok(m2_editor, "scene/current/save")
    deleted = exec_ok(m2_editor, "scene/delete", {"path": source})
    assert deleted["deleted"] is True
    assert not (Path(m2_editor["project"]) / "scenes/controls_linked.tscn").exists()


def test_scene_delete_dry_run_protection_and_open_conflict(m2_editor):
    path = write_scene(m2_editor)
    preview = exec_ok(m2_editor, "scene/delete", {"path": path, "dry_run": True})
    assert preview["changed"] is False and preview["can_delete"] is True
    assert (Path(m2_editor["project"]) / "scenes/controls_linked.tscn").exists()
    assert exec_error(m2_editor, "scene/delete", {"path": "res://addons/gdapi/protected.tscn"})["code"] == "permission_denied"
    exec_ok(m2_editor, "scene/open", {"path": path})
    assert exec_error(m2_editor, "scene/delete", {"path": path})["code"] == "conflict"
    result = exec_ok(m2_editor, "scene/delete", {"path": path, "close_open": True})
    assert result["deleted"] is True and result["closed"] is True
    assert path not in exec_ok(m2_editor, "scene/list_open")["paths"]
    assert not (Path(m2_editor["project"]) / "scenes/controls_linked.tscn").exists()


@pytest.mark.parametrize("reference_form", ["res", "relative", "uid", "raw", "escaped", "load_relative"])
def test_scene_delete_rejects_script_preload_without_executing_script(m2_editor, reference_form):
    project = Path(m2_editor["project"])
    target_path = write_scene(m2_editor, "res://scenes/delete_preload_target.tscn")
    target = project / "scenes/delete_preload_target.tscn"
    exec_ok(m2_editor, "scene/open", {"path": target_path})
    exec_ok(m2_editor, "scene/current/save")
    exec_ok(m2_editor, "scene/close")
    before = target.read_bytes()
    if reference_form == "uid":
        match = re.search(r'uid="([^"]+)"', before.decode("utf-8"))
        assert match is not None, "saved Godot scene must have a UID"
        literal = match[1]
    elif reference_form in ["relative", "raw"]:
        literal = "../scenes/delete_preload_target.tscn"
    elif reference_form == "escaped":
        literal = r"..\u002fscenes/delete_preload_target.tscn"
    elif reference_form == "load_relative":
        literal = "scenes/delete_preload_target.tscn"
    else:
        literal = target_path
    operation = "load" if reference_form == "load_relative" else "preload"
    path_expression = f'r"{literal}"' if reference_form == "raw" else f'"{literal}"'
    script_path = "res://scripts/delete_preload_consumer.gd"
    script = project / "scripts/delete_preload_consumer.gd"
    marker = project / "delete_preload_executed.txt"
    # Do not import the script as fixture setup: the service must inspect a
    # previously unloaded consumer, including its real static-init side effect.
    script.write_text(f'''@tool
extends RefCounted
const TARGET = {operation}(
    {path_expression}
)
static func _static_init() -> void:
    var file := FileAccess.open("res://delete_preload_executed.txt", FileAccess.WRITE)
    file.store_string("executed")
    file.close()
''', encoding="utf-8")
    try:
        preview = exec_ok(m2_editor, "scene/delete", {"path": target_path, "dry_run": True})
        assert preview["can_delete"] is False and script_path in preview["references"]
        assert target.read_bytes() == before and not marker.exists()
        assert exec_error(m2_editor, "scene/delete", {"path": target_path})["code"] == "conflict"
        assert target.read_bytes() == before and not marker.exists()
    finally:
        script.unlink(missing_ok=True)
        marker.unlink(missing_ok=True)
    preview = exec_ok(m2_editor, "scene/delete", {"path": target_path, "dry_run": True})
    assert preview["can_delete"] is True
    assert exec_ok(m2_editor, "scene/delete", {"path": target_path})["deleted"] is True
    assert not target.exists()


@pytest.mark.parametrize("extension", ["tscn", "tres"])
def test_scene_delete_retains_scene_and_resource_dependencies(m2_editor, extension):
    project = Path(m2_editor["project"])
    target_path = write_scene(m2_editor, "res://scenes/delete_resource_target.tscn")
    target = project / "scenes/delete_resource_target.tscn"
    consumer = project / f"scenes/delete_resource_consumer.{extension}"
    if extension == "tscn":
        content = f'''[gd_scene load_steps=2 format=3]
[ext_resource type="PackedScene" path="{target_path}" id="1"]
[node name="Consumer" instance=ExtResource("1")]
'''
    else:
        content = f'''[gd_resource type="Resource" load_steps=2 format=3]
[ext_resource type="PackedScene" path="{target_path}" id="1"]
[resource]
metadata/scene_dependency = ExtResource("1")
'''
    consumer.write_text(content, encoding="utf-8")
    before = target.read_bytes()
    try:
        preview = exec_ok(m2_editor, "scene/delete", {"path": target_path, "dry_run": True})
        assert preview["can_delete"] is False
        assert f"res://scenes/{consumer.name}" in preview["references"]
        assert exec_error(m2_editor, "scene/delete", {"path": target_path})["code"] == "conflict"
        assert target.read_bytes() == before
    finally:
        consumer.unlink(missing_ok=True)


def test_scene_delete_ignores_preload_text_in_comments_and_strings(m2_editor):
    project = Path(m2_editor["project"])
    target_path = write_scene(m2_editor, "res://scenes/delete_unreferenced.tscn")
    script = project / "scripts/delete_not_a_reference.gd"
    script.write_text(f'''extends RefCounted
# preload("{target_path}")
const DESCRIPTION = """preload("{target_path}")"""
''', encoding="utf-8")
    try:
        preview = exec_ok(m2_editor, "scene/delete", {"path": target_path, "dry_run": True})
        assert preview["can_delete"] is True and preview["references"] == []
        assert exec_ok(m2_editor, "scene/delete", {"path": target_path})["deleted"] is True
        assert not (project / "scenes/delete_unreferenced.tscn").exists()
    finally:
        script.unlink(missing_ok=True)


def test_scene_delete_dry_run_and_real_delete_both_reject_unsaved_scene(m2_editor):
    project = Path(m2_editor["project"])
    path = write_scene(m2_editor, "res://scenes/delete_unsaved.tscn")
    target = project / "scenes/delete_unsaved.tscn"
    before = target.read_bytes()
    exec_ok(m2_editor, "scene/open", {"path": path})
    exec_ok(m2_editor, "node/meta/set", {
        "node_path": "/root/Linked", "key": "unsaved_delete_guard", "value": 1,
    })
    assert exec_ok(m2_editor, "scene/current")["edited"] is True
    request = {"path": path, "close_open": True}
    preview = exec_ok(m2_editor, "scene/delete", {**request, "dry_run": True})
    assert preview["open"] is True and preview["can_delete"] is False
    assert exec_error(m2_editor, "scene/delete", request)["code"] == "conflict"
    assert target.read_bytes() == before
    assert exec_ok(m2_editor, "scene/current")["path"] == path
    exec_ok(m2_editor, "scene/current/save")
    assert exec_ok(m2_editor, "scene/delete", {**request, "dry_run": True})["can_delete"] is True
    assert exec_ok(m2_editor, "scene/delete", request)["deleted"] is True
    assert not target.exists()


def test_scene_delete_save_as_dirty_current_scene_is_refused(m2_editor, m2_main):
    project = Path(m2_editor["project"])
    path = "res://scenes/delete_save_as_guard.tscn"
    target = project / "scenes/delete_save_as_guard.tscn"
    assert exec_ok(m2_editor, "scene/current/save", {"path": path})["saved"] is True
    assert target.is_file()
    request = {
        "node_path": "/root/Main/Player",
        "property": "position",
        "value": {"type": "Vector2", "value": [73, 19]},
    }
    exec_ok(m2_editor, "node/property/set", request)
    current = exec_ok(m2_editor, "scene/current")
    assert current["path"] == path and current["edited"] is True
    deletion = {"path": path, "close_open": True}
    preview = exec_ok(m2_editor, "scene/delete", {**deletion, "dry_run": True})
    assert preview["open"] is True and preview["can_delete"] is False
    assert exec_error(m2_editor, "scene/delete", deletion)["code"] == "conflict"
    assert target.is_file()
    assert exec_ok(m2_editor, "scene/current") == current
    assert exec_ok(m2_editor, "node/property/get", {
        "node_path": "/root/Main/Player", "property": "position"
    })["value"] == {"type": "Vector2", "value": [73, 19]}
    # Keep this dirty branch alive while saving the original Main. Save-as tabs
    # can retain the original editor path, but dirty state belongs to a scene root.
    exec_ok(m2_editor, "scene/open", {"path": "res://scenes/main.tscn"})
    assert exec_ok(m2_editor, "scene/current/save")["saved"] is True
    assert exec_ok(m2_editor, "scene/current")["edited"] is False
    exec_ok(m2_editor, "scene/open", {"path": path})
    assert exec_ok(m2_editor, "scene/current") == current
    assert exec_ok(m2_editor, "node/property/get", {
        "node_path": "/root/Main/Player", "property": "position",
    })["value"] == {"type": "Vector2", "value": [73, 19]}


def test_node_call_executes_safe_native_and_validates_arguments(m2_editor, m2_main):
    path = "/root/Main/Player"
    expected = exec_ok(m2_editor, "node/property/get", {"node_path": path, "property": "position"})["value"]
    assert exec_ok(m2_editor, "node/call", {"node_path": path, "method": "get_position"})["result"] == expected
    exec_ok(m2_editor, "node/call", {"node_path": path, "method": "hide"})
    assert exec_ok(m2_editor, "node/call", {"node_path": path, "method": "is_visible"})["result"] is False
    exec_ok(m2_editor, "node/call", {"node_path": path, "method": "show"})
    assert exec_ok(m2_editor, "node/call", {"node_path": path, "method": "is_visible"})["result"] is True
    assert exec_error(m2_editor, "node/call", {"node_path": path, "method": "get_position", "args": [1]})["code"] == "invalid_param"
    assert exec_error(m2_editor, "node/call", {"node_path": path, "method": "is_in_group", "args": [123]})["code"] == "invalid_param"
    assert exec_error(m2_editor, "node/call", {"node_path": "/root/Main/../EditorNode", "method": "get_name"})["code"] == "permission_denied"


@pytest.mark.parametrize("method", ["free", "queue_free", "call", "callv", "set_script", "set_meta", "get_tree", "rpc", "add_child"])
def test_node_call_rejects_native_escape_hatches_and_audits_failure(m2_editor, m2_main, method):
    before = exec_ok(m2_editor, "gdapi/audit/list", {"limit": 1000})["entries"]
    seq = max((entry["seq"] for entry in before), default=0)
    assert exec_error(m2_editor, "node/call", {"node_path": "/root/Main/Player", "method": method})["code"] == "permission_denied"
    entries = exec_ok(m2_editor, "gdapi/audit/list", {"since": seq})["entries"]
    rejected = [entry for entry in entries if entry["route"] == "node/call"]
    assert len(rejected) == 1
    assert rejected[0]["ok"] is False and rejected[0]["code"] == "permission_denied"
    assert exec_ok(m2_editor, "node/get", {"node_path": "/root/Main/Player"})["name"] == "Player"


def test_explicit_tool_method_is_a_real_consumer(m2_editor, m2_main):
    source = '''@tool
extends Node2D
func _init() -> void:
    set_meta("gdapi_callable_methods", PackedStringArray(["bump", "queue_free"]))
func bump(amount: int) -> Vector2:
    position += Vector2(amount, 0)
    return position
func undeclared() -> bool:
    return true
'''
    exec_ok(m2_editor, "script/write", {"path": "res://scripts/controls_callable.gd", "content": source})
    exec_ok(m2_editor, "node/create", {"parent_path": "/root/Main", "type": "Node2D", "name": "DeclaredMethodConsumer"})
    exec_ok(m2_editor, "script/attach", {"node_path": "/root/Main/DeclaredMethodConsumer", "path": "res://scripts/controls_callable.gd"})
    data = {"node_path": "/root/Main/DeclaredMethodConsumer", "method": "bump", "args": [6]}
    assert exec_ok(m2_editor, "node/call", data)["result"] == {"type": "Vector2", "value": [6, 0]}
    assert exec_ok(m2_editor, "node/call", data)["result"]["value"] == [12, 0]
    assert exec_error(m2_editor, "node/call", {**data, "args": ["six"]})["code"] == "invalid_param"
    assert exec_error(m2_editor, "node/call", {"node_path": data["node_path"], "method": "undeclared"})["code"] == "permission_denied"
    assert exec_error(m2_editor, "node/call", {"node_path": data["node_path"], "method": "queue_free"})["code"] == "permission_denied"


def test_inspector_observes_real_node_and_resource(m2_editor, m2_main):
    exec_ok(m2_editor, "editor/inspector/node", {"node_path": "/root/Main/Target"})
    assert exec_ok(m2_editor, "editor/inspector/get")["node_path"] == "/root/Main/Target"
    path = write_scene(m2_editor)
    exec_ok(m2_editor, "editor/inspector/resource", {"path": path})
    target = exec_ok(m2_editor, "editor/inspector/get")
    assert target["path"] == path and target["type"] == "PackedScene"
    assert exec_error(m2_editor, "editor/inspector/node", {"node_path": "/root/Main/Missing"})["code"] == "not_found"
    assert exec_ok(m2_editor, "editor/inspector/get")["path"] == path


def test_editor_settings_persist_readback_and_restore(m2_editor):
    name = "interface/editor/show_internal_errors_in_toast_notifications"
    # Choose a real bool setting, without pinning an engine-version default.
    listing = exec_ok(m2_editor, "editor/settings/list", {"prefix": "interface/editor/"})["settings"]
    choices = [item for item in listing if isinstance(item["value"], bool)]
    name = next((item["name"] for item in choices if "show_internal_errors" in item["name"]), choices[0]["name"])
    original = exec_ok(m2_editor, "editor/settings/get", {"name": name})["value"]
    try:
        result = exec_ok(m2_editor, "editor/settings/set", {"name": name, "value": not original})
        assert result["saved"] is True and result["changed"] is True
        assert Path(result["settings_path"]).is_file()
        assert exec_ok(m2_editor, "editor/settings/get", {"name": name})["value"] is not original
        assert exec_error(m2_editor, "editor/settings/set", {"name": name, "value": "wrong type"})["code"] == "invalid_param"
    finally:
        exec_ok(m2_editor, "editor/settings/set", {"name": name, "value": original})
    assert exec_error(m2_editor, "editor/settings/set", {"name": "text_editor/external/use_external_editor", "value": True})["code"] == "permission_denied"


@pytest.mark.parametrize("operation", ["enable", "disable", "reload"])
def test_api_provider_plugin_is_protected(m2_editor, operation):
    before = exec_ok(m2_editor, "scene/current")
    assert exec_error(m2_editor, "editor/plugins/" + operation, {"plugin": "gdapi"})["code"] == "permission_denied"
    plugins = exec_ok(m2_editor, "editor/plugins/list")["plugins"]
    assert next(plugin for plugin in plugins if plugin["plugin"] == "gdapi")["enabled"] is True
    assert exec_ok(m2_editor, "scene/current") == before


def test_plugin_lifecycle_reloads_a_real_editor_plugin(m2_editor, m2_main):
    script = '''@tool
extends EditorPlugin
func _enter_tree() -> void:
    var root := EditorInterface.get_edited_scene_root()
    root.set_meta("controls_plugin_enter", int(root.get_meta("controls_plugin_enter", 0)) + 1)
func _exit_tree() -> void:
    var root := EditorInterface.get_edited_scene_root()
    root.set_meta("controls_plugin_exit", int(root.get_meta("controls_plugin_exit", 0)) + 1)
'''
    config = '[plugin]\nname="ControlsConsumer"\ndescription="Lifecycle consumer"\nauthor="gdapi tests"\nversion="1"\nscript="plugin.gd"\n'
    exec_ok(m2_editor, "filesystem/write", {"path": "res://addons/controls_consumer/plugin.gd", "content": script})
    exec_ok(m2_editor, "filesystem/write", {"path": "res://addons/controls_consumer/plugin.cfg", "content": config})
    target = {"node_path": "/root/Main"}
    try:
        assert exec_ok(m2_editor, "editor/plugins/enable", {"plugin": "controls_consumer"})["enabled"] is True
        assert exec_ok(m2_editor, "node/meta/get", {**target, "key": "controls_plugin_enter"})["value"] == 1
        assert exec_ok(m2_editor, "editor/plugins/reload", {"plugin": "controls_consumer"})["reloaded"] is True
        assert exec_ok(m2_editor, "node/meta/get", {**target, "key": "controls_plugin_enter"})["value"] == 2
        assert exec_ok(m2_editor, "node/meta/get", {**target, "key": "controls_plugin_exit"})["value"] == 1
    finally:
        exec_ok(m2_editor, "editor/plugins/disable", {"plugin": "controls_consumer"})
    assert exec_ok(m2_editor, "node/meta/get", {**target, "key": "controls_plugin_exit"})["value"] == 2


def test_camera_transform_round_trip_and_release(m2_editor, m2_main):
    value = {"type": "Transform2D", "value": [[2, 0], [0, 2], [120, 90]]}
    try:
        result = exec_ok(m2_editor, "editor/camera/set", {"dimension": "2d", "transform": value})
        assert result["transform"] == value and result["override"] is True
        assert exec_ok(m2_editor, "editor/camera/get", {"dimension": "2d"})["transform"] == value
        error = exec_error(m2_editor, "editor/camera/set", {
            "dimension": "2d", "transform": {"type": "Transform2D", "value": [[0, 0], [0, 0], [0, 0]]},
        })
        assert error["code"] == "invalid_param"
        assert exec_ok(m2_editor, "editor/camera/get", {"dimension": "2d"})["transform"] == value
    finally:
        assert exec_ok(m2_editor, "editor/camera/set", {"dimension": "2d", "release": True})["override"] is False
    assert exec_error(m2_editor, "editor/camera/get", {"dimension": "4d"})["code"] == "invalid_param"


def test_screenshot_captures_the_shared_editor_viewport(m2_editor, m2_main):
    path = Path(m2_editor["project"]) / "controls_viewport.png"
    result = exec_ok(m2_editor, "editor/screenshot/viewport", {"path": "res://controls_viewport.png", "width": 64, "height": 48})
    assert (result["width"], result["height"]) == (64, 48)
    assert path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
    assert result["bytes"] == path.stat().st_size


def test_notification_validation_and_distraction_mode(m2_editor):
    assert exec_error(m2_editor, "editor/notification", {"message": "x", "severity": "fatal"})["code"] == "invalid_param"
    assert exec_ok(m2_editor, "editor/notification", {"message": "T8 consumer notification", "severity": "info"})["changed"] is True
    original = exec_ok(m2_editor, "editor/dock/list")["distraction_free"]
    try:
        assert exec_ok(m2_editor, "editor/dock/distraction_free", {"enabled": not original})["enabled"] is not original
        assert exec_ok(m2_editor, "editor/dock/list")["distraction_free"] is not original
    finally:
        exec_ok(m2_editor, "editor/dock/distraction_free", {"enabled": original})
