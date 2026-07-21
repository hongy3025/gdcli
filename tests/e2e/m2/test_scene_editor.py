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


def test_scene_current_save_rejects_overwrite_without_force(m2_editor):
    # Step 1: save current to a fresh path - should succeed
    first = exec_ok(m2_editor, "scene/current/save", {"path": "res://scenes/main_backup.tscn"})
    assert first["saved"] is True
    # Step 2: try again to the same existing path without force - should fail
    error = exec_error(
        m2_editor,
        "scene/current/save",
        {"path": "res://scenes/main_backup.tscn"},
    )
    assert error["code"] == "unsafe_operation"


def test_scene_close_then_current_is_not_found(m2_editor):
    closed = exec_ok(m2_editor, "scene/close")
    assert closed["changed"] is True
    error = exec_error(m2_editor, "scene/current", {})
    assert error["code"] == "not_found"
