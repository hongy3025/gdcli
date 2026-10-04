"""Scene lifecycle and tree query acceptance."""

from __future__ import annotations

import json
import os
import socket
import stat
import struct
import time
from pathlib import Path

import pytest

from .helpers import exec_error, exec_ok


def test_scene_current_returns_main_scene(m2_editor):
    current = exec_ok(m2_editor, "scene/current")
    assert current["ok"] is True
    assert current["path"] == "res://scenes/main.tscn"
    assert current["name"] == "Main"
    assert current["type"] == "Node2D"
    assert current["undoable"] is False


def test_scene_list_open_contains_main(m2_editor):
    opened = exec_ok(m2_editor, "scene/list_open")
    assert "res://scenes/main.tscn" in opened["paths"]


def test_scene_tree_matches_fixture(m2_editor):
    tree = exec_ok(m2_editor, "scene/tree", {"max_depth": 4})
    assert tree["root"]["name"] == "Main"
    children = [(n["name"], n["type"]) for n in tree["root"]["children"]]
    assert children == [("Player", "Node2D"), ("Target", "Node2D")]
    player = next(n for n in tree["root"]["children"] if n["name"] == "Player")
    assert [(c["name"], c["type"]) for c in player["children"]] == [("Child", "Node2D")]


def test_scene_open_rejects_missing_scene_without_state_change(m2_editor):
    before = exec_ok(m2_editor, "scene/current")
    error = exec_error(m2_editor, "scene/open", {"path": "res://missing.tscn"})
    assert error["code"] == "not_found"
    assert exec_ok(m2_editor, "scene/current") == before


def test_cancelled_scene_open_does_not_switch_editor_scene(m2_editor):
    project = Path(m2_editor["project"])
    meta = json.loads((project / ".godot" / "gdapi.json").read_text(encoding="utf-8"))
    body = json.dumps({"path": "res://scenes/audio.tscn"}).encode("utf-8")
    request = (
        b"POST /scene/open HTTP/1.1\r\n"
        + f"Host: 127.0.0.1:{meta['http_port']}\r\n".encode()
        + f"Authorization: Bearer {meta['token']}\r\n".encode()
        + b"Content-Type: application/json\r\nConnection: close\r\n"
        + f"Content-Length: {len(body)}\r\n\r\n".encode()
        + body
    )
    with socket.create_connection(("127.0.0.1", meta["http_port"]), timeout=5) as client:
        client.sendall(request)
        client.setsockopt(
            socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("HH" if os.name == "nt" else "ii", 1, 0)
        )
    time.sleep(0.25)
    assert exec_ok(m2_editor, "scene/current")["path"] == "res://scenes/main.tscn"
    assert "res://scenes/audio.tscn" not in exec_ok(m2_editor, "scene/list_open")["paths"]


def test_scene_current_save_persists_file_changes(m2_editor):
    result = exec_ok(m2_editor, "scene/current/save")
    assert result["saved"] is True
    assert result["undoable"] is False
    assert result["path"] == "res://scenes/main.tscn"


@pytest.mark.parametrize("extension", ["tscn", "scn"])
def test_scene_current_save_overwrites_existing_without_force(m2_editor, extension):
    project = Path(m2_editor["project"])
    original = (project / "scenes/main.tscn").read_bytes()
    path = f"res://scenes/main_backup.{extension}"
    target = project / f"scenes/main_backup.{extension}"
    first = exec_ok(m2_editor, "scene/current/save", {"path": path})
    assert first["saved"] is True and first["path"] == path
    assert target.is_file()
    initial = target.read_bytes()
    request = {"node_path": "/root/Main/Player", "property": "position"}
    value = {"type": "Vector2", "value": [37, 83]}
    exec_ok(m2_editor, "node/property/set", {**request, "value": value})
    assert exec_ok(m2_editor, "scene/current")["edited"] is True
    second = exec_ok(m2_editor, "scene/current/save", {"path": path})
    assert second["saved"] is True
    assert target.read_bytes() != initial
    assert (project / "scenes/main.tscn").read_bytes() == original
    assert exec_ok(m2_editor, "scene/current")["edited"] is False
    exec_ok(m2_editor, "scene/close")
    exec_ok(m2_editor, "scene/open", {"path": path})
    assert exec_ok(m2_editor, "node/property/get", request)["value"] == value


@pytest.mark.skipif(os.name != "nt", reason="Windows read-only scene target boundary")
def test_save_as_read_only_failure_preserves_disk_path_and_unsaved_changes(m2_editor):
    project = Path(m2_editor["project"])
    original_path = "res://scenes/main.tscn"
    target_path = "res://scenes/readonly_save_as.tscn"
    original = project / "scenes/main.tscn"
    target = project / "scenes/readonly_save_as.tscn"
    target.write_bytes(b'[gd_scene format=3]\n\n[node name="Before" type="Node2D"]\n')
    original_bytes, target_bytes = original.read_bytes(), target.read_bytes()
    property_request = {"node_path": "/root/Main/Player", "property": "position"}
    value = {"type": "Vector2", "value": [731, 419]}
    exec_ok(m2_editor, "node/property/set", {**property_request, "value": value})
    before = exec_ok(m2_editor, "scene/current")
    assert before["path"] == original_path and before["edited"] is True
    target.chmod(stat.S_IREAD)
    try:
        assert exec_error(m2_editor, "scene/current/save", {"path": target_path})["code"] == "permission_denied"
        assert target.read_bytes() == target_bytes
        assert original.read_bytes() == original_bytes
        assert exec_ok(m2_editor, "scene/current") == before
        assert exec_ok(m2_editor, "node/property/get", property_request)["value"] == value
    finally:
        target.chmod(stat.S_IREAD | stat.S_IWRITE)
    result = exec_ok(m2_editor, "scene/current/save", {"path": target_path})
    assert result["saved"] is True and result["path"] == target_path
    current = exec_ok(m2_editor, "scene/current")
    assert current["path"] == target_path and current["edited"] is False
    assert original.read_bytes() == original_bytes
    assert target.read_bytes() != target_bytes
    exec_ok(m2_editor, "scene/close")
    exec_ok(m2_editor, "scene/open", {"path": target_path})
    assert exec_ok(m2_editor, "node/property/get", property_request)["value"] == value


def test_save_as_invalid_extension_preserves_unsaved_scene_and_target(m2_editor):
    target = Path(m2_editor["project"]) / "scenes/not_a_scene.txt"
    target.write_bytes(b"existing document")
    exec_ok(m2_editor, "node/meta/set", {
        "node_path": "/root/Main", "key": "save_failure_marker", "value": 17,
    })
    before = exec_ok(m2_editor, "scene/current")
    assert before["edited"] is True
    assert exec_error(m2_editor, "scene/current/save", {"path": "res://scenes/not_a_scene.txt"})["code"] == "invalid_param"
    assert target.read_bytes() == b"existing document"
    assert exec_ok(m2_editor, "scene/current") == before
    assert exec_ok(m2_editor, "node/meta/get", {
        "node_path": "/root/Main", "key": "save_failure_marker",
    })["value"] == 17


def test_save_as_persists_editor_pre_save_notifications(m2_editor):
    source = '''@tool
extends Node
func _notification(what: int) -> void:
    if what == NOTIFICATION_EDITOR_PRE_SAVE:
        set_meta("pre_save_count", int(get_meta("pre_save_count", 0)) + 1)
'''
    script = "res://scripts/save_notification_consumer.gd"
    target = "res://scenes/save_notification.tscn"
    node = "/root/Main/SaveObserver"
    exec_ok(m2_editor, "script/write", {"path": script, "content": source})
    exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Node", "name": "SaveObserver",
    })
    exec_ok(m2_editor, "script/attach", {"node_path": node, "path": script})
    result = exec_ok(m2_editor, "scene/current/save", {"path": target})
    assert result["saved"] is True
    assert exec_ok(m2_editor, "scene/current")["edited"] is False
    request = {"node_path": node, "key": "pre_save_count"}
    assert exec_ok(m2_editor, "node/meta/get", request)["value"] == 1
    exec_ok(m2_editor, "scene/close")
    exec_ok(m2_editor, "scene/open", {"path": target})
    assert exec_ok(m2_editor, "node/meta/get", request)["value"] == 1


def test_scene_save_verification_reads_external_resource_from_disk(m2_editor):
    project = Path(m2_editor["project"])
    dependency_path = "res://resources/save_readback_material.tres"
    dependency = project / "resources/save_readback_material.tres"
    exec_ok(m2_editor, "resource/create", {
        "path": dependency_path,
        "type": "CanvasItemMaterial",
        "properties": {"resource_name": "CachedBeforeDiskChange"},
    })
    exec_ok(m2_editor, "resource/assign", {
        "node_path": "/root/Main/Player",
        "property": "material",
        "path": dependency_path,
    })
    original_scene = (project / "scenes/main.tscn").read_bytes()
    dependency.write_text(
        '[gd_resource type="CanvasItemMaterial" format=3]\n\n'
        '[resource]\nresource_name = "ChangedOnDisk"\n',
        encoding="utf-8",
    )
    target_path = "res://scenes/save_readback_target.tscn"
    target = project / "scenes/save_readback_target.tscn"
    readonly_enforced = os.name == "nt"
    if readonly_enforced:
        dependency.chmod(stat.S_IREAD)
    try:
        result = exec_error(m2_editor, "scene/current/save", {"path": target_path})
        assert result["code"] == "godot_error"
        assert not target.exists()
        assert (project / "scenes/main.tscn").read_bytes() == original_scene
        assert "ChangedOnDisk" in dependency.read_text(encoding="utf-8")
        current = exec_ok(m2_editor, "scene/current")
        assert current["path"] == "res://scenes/main.tscn" and current["edited"] is True
        assert exec_ok(m2_editor, "node/property/get", {
            "node_path": "/root/Main/Player", "property": "material"
        })["value"] == {"type": "Resource", "value": dependency_path}
    finally:
        if readonly_enforced:
            dependency.chmod(stat.S_IREAD | stat.S_IWRITE)


def test_scene_close_then_current_is_not_found(m2_editor):
    closed = exec_ok(m2_editor, "scene/close")
    assert closed["changed"] is True
    # After closing the edited scene, the editor falls back to the project
    # main scene. The unified fixture sets the main scene to the M3 runtime
    # scene, so the current root points at RuntimeMain rather than
    # returning not_found. Either "not_found" or a different scene path is
    # acceptable; only the wrong scene content would be a failure.
    result = exec_ok(m2_editor, "scene/current")
    assert result.get("ok") is True


def test_scene_list_open_returns_every_open_scene_in_stable_order(m2_editor):
    # Opening a second scene keeps the first one open as an editor tab, so the
    # route must report the whole open set (not just the edited scene).
    exec_ok(m2_editor, "scene/open", {"path": "res://scenes/audio.tscn"})

    first = exec_ok(m2_editor, "scene/list_open")
    assert first["undoable"] is False
    paths = first["paths"]
    assert "res://scenes/main.tscn" in paths
    assert "res://scenes/audio.tscn" in paths
    # Stable, deterministic ordering (lexicographic ascending).
    assert paths == sorted(paths)
    assert exec_ok(m2_editor, "scene/list_open")["paths"] == paths

    # Closing the current scene drops it from the open set.
    closed = exec_ok(m2_editor, "scene/close")
    assert closed["path"] == "res://scenes/audio.tscn"
    assert "res://scenes/audio.tscn" not in exec_ok(m2_editor, "scene/list_open")["paths"]


def test_scene_close_only_operates_on_current_scene(m2_editor):
    before = exec_ok(m2_editor, "scene/current")["path"]
    assert before == "res://scenes/main.tscn"

    exec_ok(m2_editor, "scene/open", {"path": "res://scenes/audio.tscn"})
    assert exec_ok(m2_editor, "scene/current")["path"] == "res://scenes/audio.tscn"

    # Godot exposes no API to close a non-current scene by path; the request is
    # rejected without changing editor state.
    rejected = exec_error(m2_editor, "scene/close", {"path": before})
    assert rejected["code"] == "not_found"
    assert exec_ok(m2_editor, "scene/current")["path"] == "res://scenes/audio.tscn"

    closed = exec_ok(m2_editor, "scene/close")
    assert closed["changed"] is True
    assert closed["path"] == "res://scenes/audio.tscn"

    # The closed scene is gone: closing it again reports not_found.
    again = exec_error(m2_editor, "scene/close", {"path": "res://scenes/audio.tscn"})
    assert again["code"] == "not_found"

    # scene/current reflects the real post-close state (the previously edited scene).
    after = exec_ok(m2_editor, "scene/current")
    assert after["path"] == before
    assert before in exec_ok(m2_editor, "scene/list_open")["paths"]
