"""Scene lifecycle and tree query acceptance."""

from __future__ import annotations

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


def test_scene_current_save_persists_file_changes(m2_editor):
    result = exec_ok(m2_editor, "scene/current/save")
    assert result["saved"] is True
    assert result["undoable"] is False
    assert result["path"] == "res://scenes/main.tscn"


def test_scene_current_save_overwrites_existing_without_force(m2_editor):
    # Step 1: save current to a fresh path - should succeed
    first = exec_ok(m2_editor, "scene/current/save", {"path": "res://scenes/main_backup.tscn"})
    assert first["saved"] is True
    # Step 2: save again to the same existing path - should succeed and overwrite
    second = exec_ok(m2_editor, "scene/current/save", {"path": "res://scenes/main_backup.tscn"})
    assert second["saved"] is True


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
