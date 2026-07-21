"""Script authoring acceptance tests."""

from __future__ import annotations

import pytest

from .helpers import exec_error, exec_ok, tree_digest


def test_script_create_patch_validate_attach(m2_editor):
    path = "res://scripts/generated.gd"
    source = "extends Node2D\nvar speed := 10\n"
    create_result = exec_ok(m2_editor, "script/create", {
        "path": path, "content": source
    })
    assert create_result["written"] is True

    # no force -> unsafe
    denied = exec_error(m2_editor, "script/patch", {
        "path": path, "start_line": 2, "end_line": 2, "text": "var speed := 20"
    })
    assert denied["code"] == "unsafe_operation"

    patched = exec_ok(m2_editor, "script/patch", {
        "path": path, "start_line": 2, "end_line": 2,
        "text": "var speed := 20", "force": True,
    })
    assert patched["saved"] is True

    valid = exec_ok(m2_editor, "script/validate", {"path": path})
    assert valid["valid"] is True

    attached = exec_ok(m2_editor, "script/attach", {
        "node_path": "/root/Main/Player", "path": path
    })
    assert attached["undoable"] is True


def test_invalid_script_returns_valid_false(m2_editor):
    result = exec_ok(m2_editor, "script/validate", {"path": "res://scripts/broken.gd"})
    assert result["valid"] is False
    assert result["errors"]


@pytest.mark.parametrize("route,data,code", [
    ("script/patch", {"path": "res://scripts/player.gd", "start_line": 99, "end_line": 99, "text": "x", "force": True}, "invalid_param"),
    ("script/write", {"path": "res://addons/gdapi/plugin.gd", "content": "x", "force": True}, "permission_denied"),
    ("script/write", {"path": "res://scripts/player.gd", "content": "x"}, "unsafe_operation"),
    ("script/attach", {"node_path": "/root/Main/Missing", "path": "res://scripts/player.gd"}, "not_found"),
])
def test_script_rejections_do_not_change_files(m2_editor, route, data, code):
    before = tree_digest(m2_editor["project"])
    error = exec_error(m2_editor, route, data)
    assert error["code"] == code
    assert tree_digest(m2_editor["project"]) == before
