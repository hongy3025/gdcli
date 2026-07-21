"""Filesystem route acceptance tests."""

from __future__ import annotations

import pytest

from .helpers import exec_error, exec_ok, tree_digest


def test_filesystem_query_contract(m2_editor):
    listing = exec_ok(m2_editor, "filesystem/list", {"path": "res://scripts", "limit": 50})
    assert sorted([it["path"] for it in listing["items"]]) == [it["path"] for it in listing["items"]]
    grep = exec_ok(m2_editor, "filesystem/grep", {
        "root": "res://scripts",
        "pattern": "speed",
        "glob": "*.gd",
    })
    assert grep["items"]
    paths = [m["path"] for m in grep["items"]]
    assert all(p.endswith(".gd") for p in paths)
    assert grep["items"][0]["line"] >= 1


def test_filesystem_write_requires_force(m2_editor):
    path = "res://scripts/player.gd"
    before = exec_ok(m2_editor, "filesystem/read", {"path": path})
    error = exec_error(m2_editor, "filesystem/write", {
        "path": path, "content": "broken"
    })
    assert error["code"] == "unsafe_operation"
    after = exec_ok(m2_editor, "filesystem/read", {"path": path})
    assert after["content"] == before["content"]


def test_filesystem_search_and_read_round_trip(m2_editor):
    listed = exec_ok(m2_editor, "filesystem/search", {
        "root": "res://scripts", "glob": "*.gd", "limit": 50
    })
    assert listed["items"]
    target = listed["items"][0]
    read_back = exec_ok(m2_editor, "filesystem/read", {"path": target})
    assert read_back["bytes"] > 0


def test_filesystem_write_atomic_with_force(m2_editor):
    target = "res://notes/test.md"
    write1 = exec_ok(m2_editor, "filesystem/write", {
        "path": target, "content": "first"
    })
    assert write1["written"] is True
    error = exec_error(m2_editor, "filesystem/write", {
        "path": target, "content": "second"
    })
    assert error["code"] == "unsafe_operation"
    after = exec_ok(m2_editor, "filesystem/read", {"path": target})
    assert after["content"] == "first"


@pytest.mark.parametrize("route,data,code", [
    ("filesystem/read", {"path": "res://notes/../../outside.txt"}, "invalid_path"),
    ("filesystem/read", {"path": "/etc/passwd"}, "invalid_path"),
    ("filesystem/write", {"path": "res://addons/gdapi/plugin.gd", "content": "x", "force": True}, "permission_denied"),
    ("filesystem/reimport", {"paths": ["res://addons/gdapi/plugin.gd"]}, "permission_denied"),
])
def test_filesystem_rejections(m2_editor, route, data, code):
    error = exec_error(m2_editor, route, data)
    assert error["code"] == code
