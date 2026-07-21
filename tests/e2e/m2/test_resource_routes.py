"""Resource route acceptance tests."""

from __future__ import annotations

import pytest

from .helpers import exec_error, exec_ok, tree_digest


def test_resource_info_returns_class(m2_editor):
    info = exec_ok(m2_editor, "resource/info", {"path": "res://resources/player_data.tres"})
    assert info["class"] == "Resource"


def test_resource_search_finds_player(m2_editor):
    page = exec_ok(m2_editor, "resource/search", {
        "filter": "player", "offset": 0, "limit": 50,
    })
    assert any("player" in p for p in page["items"])


def test_resource_assign_rejects_non_resource_property(m2_editor):
    error = exec_error(m2_editor, "resource/assign", {
        "node_path": "/root/Main/Player",
        "property": "position",
        "path": "res://icon.svg",
    })
    assert error["code"] == "not_found"


def test_resource_overwrite_requires_force(m2_editor):
    error = exec_error(m2_editor, "resource/create", {
        "path": "res://resources/player_data.tres",
        "type": "Resource",
        "properties": {"resource_name": "Other"},
    })
    assert error["code"] == "unsafe_operation"


def test_resource_create_assign_delete_round_trip(m2_editor):
    create_result = exec_ok(m2_editor, "resource/create", {
        "path": "res://resources/generated.tres",
        "type": "Resource",
        "properties": {"resource_name": "Generated"},
        "force": True,
    })
    assert create_result["saved"] is True
    delete_denied = exec_error(m2_editor, "resource/delete", {
        "path": "res://resources/generated.tres"
    })
    assert delete_denied["code"] == "unsafe_operation"
    deleted = exec_ok(m2_editor, "resource/delete", {
        "path": "res://resources/generated.tres", "force": True
    })
    assert deleted["deleted"] is True


def test_resource_files_untouched_on_rejection(m2_editor):
    before = tree_digest(m2_editor["project"])
    exec_error(m2_editor, "resource/delete", {"path": "res://resources/player_data.tres"})
    assert tree_digest(m2_editor["project"]) == before
