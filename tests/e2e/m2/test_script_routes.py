"""Script authoring acceptance tests."""

from __future__ import annotations

import re
import stat
import sys
from pathlib import Path

import pytest

from .helpers import exec_error, exec_ok, tree_digest

MAIN_SCENE = "res://scenes/main.tscn"
PLAYER = "/root/Main/Player"
PLAYER_SCRIPT = "res://scripts/player.gd"
# `Child` is parented to `Player` in scenes/main.tscn.
CHILD = "/root/Main/Player/Child"


def _reopen_main_scene(editor) -> None:
    """Save-independent reload: close the edited scene and open it again from disk."""
    exec_ok(editor, "scene/close")
    exec_ok(editor, "scene/open", {"path": MAIN_SCENE})


def _scene_text(editor) -> str:
    return exec_ok(editor, "filesystem/read", {"path": MAIN_SCENE})["content"]


def _script_ext_resources(scene_text: str) -> dict[str, str]:
    mapping: dict[str, str] = {}
    for line in scene_text.splitlines():
        if line.startswith("[ext_resource") and 'type="Script"' in line:
            resource_id = re.search(r'\bid="([^"]+)"', line)
            path = re.search(r'\bpath="([^"]+)"', line)
            if resource_id and path:
                mapping[resource_id.group(1)] = path.group(1)
    return mapping


def _node_stanza(scene_text: str, node_name: str) -> str:
    """Return the `[node ...]` stanza for `node_name` plus its property lines."""
    lines = scene_text.splitlines()
    start = next(
        (index for index, line in enumerate(lines)
         if line.startswith("[node ") and f'[node name="{node_name}"' in line),
        None,
    )
    if start is None:
        return ""
    end = start + 1
    while end < len(lines) and not lines[end].startswith("[node "):
        end += 1
    return "\n".join(lines[start:end])


def _node_script_path(scene_text: str, node_name: str) -> str | None:
    """Resolve the `script` property persisted for a node stanza in the scene file."""
    match = re.search(r'script = ExtResource\("([^"]+)"\)', _node_stanza(scene_text, node_name))
    if not match:
        return None
    return _script_ext_resources(scene_text).get(match.group(1))


def _node_signals(editor) -> list[str]:
    return exec_ok(editor, "node/signal/list", {"node_path": CHILD})["signals"]


def test_script_attach_survives_reopen(m2_editor):
    """Attaching a script must be observable on the node and persist to the scene file."""
    assert "health_changed" not in _node_signals(m2_editor)
    assert _node_script_path(_scene_text(m2_editor), "Child") is None

    attached = exec_ok(m2_editor, "script/attach", {
        "node_path": CHILD, "path": PLAYER_SCRIPT,
    })
    assert attached["undoable"] is True
    assert attached["script_path"] == PLAYER_SCRIPT
    # `health_changed` is declared by player.gd, so it proves the script is mounted.
    assert "health_changed" in _node_signals(m2_editor)

    exec_ok(m2_editor, "scene/current/save")
    assert _node_script_path(_scene_text(m2_editor), "Child") == PLAYER_SCRIPT

    _reopen_main_scene(m2_editor)
    assert "health_changed" in _node_signals(m2_editor)
    assert _node_script_path(_scene_text(m2_editor), "Child") == PLAYER_SCRIPT


def test_script_detach_survives_reopen(m2_editor):
    exec_ok(m2_editor, "script/attach", {"node_path": CHILD, "path": PLAYER_SCRIPT})
    exec_ok(m2_editor, "scene/current/save")

    _reopen_main_scene(m2_editor)
    assert "health_changed" in _node_signals(m2_editor)
    assert _node_script_path(_scene_text(m2_editor), "Child") == PLAYER_SCRIPT

    detached = exec_ok(m2_editor, "script/detach", {"node_path": CHILD})
    assert detached["undoable"] is True
    assert "health_changed" not in _node_signals(m2_editor)

    exec_ok(m2_editor, "scene/current/save")
    assert _node_script_path(_scene_text(m2_editor), "Child") is None

    _reopen_main_scene(m2_editor)
    assert "health_changed" not in _node_signals(m2_editor)
    assert _node_script_path(_scene_text(m2_editor), "Child") is None
    error = exec_error(m2_editor, "script/detach", {"node_path": CHILD})
    assert error["code"] == "not_found"


def test_script_create_patch_validate_attach(m2_editor):
    path = "res://scripts/generated.gd"
    source = "extends Node2D\nvar speed := 10\n"
    create_result = exec_ok(m2_editor, "script/create", {
        "path": path, "content": source
    })
    assert create_result["written"] is True

    patched = exec_ok(m2_editor, "script/patch", {
        "path": path, "start_line": 2, "end_line": 2,
        "text": "var speed := 20",
    })
    assert patched["saved"] is True

    valid = exec_ok(m2_editor, "script/validate", {"path": path})
    assert valid["valid"] is True

    attached = exec_ok(m2_editor, "script/attach", {
        "node_path": PLAYER, "path": path
    })
    assert attached["undoable"] is True


def test_script_writes_preserve_existing_temp_name(m2_editor):
    project = Path(m2_editor["project"])
    target = project / "scripts" / "temp_collision.gd"
    old_temp_name = Path(str(target) + ".tmp")
    path = "res://scripts/temp_collision.gd"
    old_temp_name.write_bytes(b"unrelated user data")

    try:
        created = exec_ok(
            m2_editor,
            "script/create",
            {"path": path, "content": "extends Node\nvar value := 1\n"},
        )
        assert created["written"] is True
        patched = exec_ok(
            m2_editor,
            "script/patch",
            {"path": path, "start_line": 2, "end_line": 2, "text": "var value := 2"},
        )
        assert patched["saved"] is True
        assert target.read_text(encoding="utf-8") == "extends Node\nvar value := 2\n"
        assert old_temp_name.read_bytes() == b"unrelated user data"
    finally:
        target.unlink(missing_ok=True)
        old_temp_name.unlink(missing_ok=True)


@pytest.mark.skipif(sys.platform != "win32", reason="read-only replacement semantics are Windows-specific")
@pytest.mark.parametrize("route,data", [
    ("script/create", {"path": "res://scripts/read_only_create.gd", "content": "extends Node\nvar replacement := true\n"}),
    ("script/write", {"path": "res://scripts/read_only_write.gd", "content": "extends Node\nvar replacement := true\n"}),
    ("script/patch", {"path": "res://scripts/read_only_patch.gd", "start_line": 2, "end_line": 2, "text": "var value := 2"}),
])
def test_script_writes_read_only_targets_fail_cleanly(m2_editor, route, data):
    path = data["path"]
    target = Path(m2_editor["project"]) / path.removeprefix("res://")
    exec_ok(m2_editor, "script/create", {
        "path": path,
        "content": "extends Node\nvar value := 1\n",
    })
    original = target.read_bytes()
    target.chmod(stat.S_IREAD)
    try:
        exec_ok(m2_editor, "gdapi/audit/clear")
        error = exec_error(m2_editor, route, data)
        assert error["code"] == "godot_error", error
        assert target.read_bytes() == original
        assert not Path(str(target) + ".tmp").exists()
        entries = [
            entry for entry in exec_ok(m2_editor, "gdapi/audit/list", {"limit": 1000})["entries"]
            if entry.get("route") == route
        ]
        assert len(entries) == 1, entries
        assert entries[0]["ok"] is False, entries
        assert entries[0]["code"] == "godot_error", entries
    finally:
        target.chmod(stat.S_IREAD | stat.S_IWRITE)





def test_invalid_script_returns_valid_false(m2_editor):
    result = exec_ok(m2_editor, "script/validate", {"path": "res://scripts/broken.gd"})
    assert result["valid"] is False
    assert result["errors"]

@pytest.mark.parametrize("route,data,code", [
    ("script/patch", {"path": "res://scripts/player.gd", "start_line": 99, "end_line": 99, "text": "x"}, "invalid_param"),
    ("script/write", {"path": "res://addons/gdapi/plugin.gd", "content": "x"}, "permission_denied"),
    ("script/attach", {"node_path": "/root/Main/Missing", "path": "res://scripts/player.gd"}, "not_found"),
])
def test_script_rejections_do_not_change_files(m2_editor, route, data, code):
    before = tree_digest(m2_editor["project"])
    error = exec_error(m2_editor, route, data)
    assert error["code"] == code
    assert tree_digest(m2_editor["project"]) == before
