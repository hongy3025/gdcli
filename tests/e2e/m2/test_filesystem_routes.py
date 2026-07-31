"""Filesystem route acceptance tests."""

from __future__ import annotations

import pytest

from .helpers import exec_error, exec_ok


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


def test_filesystem_search_and_read_round_trip(m2_editor):
    listed = exec_ok(m2_editor, "filesystem/search", {
        "root": "res://scripts", "glob": "*.gd", "limit": 50
    })
    assert listed["items"]
    target = listed["items"][0]
    read_back = exec_ok(m2_editor, "filesystem/read", {"path": target})
    assert read_back["bytes"] > 0


def test_filesystem_write_overwrites_without_force(m2_editor):
    path = "res://notes/test.md"
    exec_ok(m2_editor, "filesystem/write", {"path": path, "content": "first"})
    written = exec_ok(m2_editor, "filesystem/write", {"path": path, "content": "second"})
    assert written["written"] is True
    assert exec_ok(m2_editor, "filesystem/read", {"path": path})["content"] == "second"


def test_filesystem_write_atomic(m2_editor):
    target = "res://notes/test.md"
    write1 = exec_ok(m2_editor, "filesystem/write", {
        "path": target, "content": "first"
    })
    assert write1["written"] is True
    write2 = exec_ok(m2_editor, "filesystem/write", {
        "path": target, "content": "second"
    })
    assert write2["written"] is True
    after = exec_ok(m2_editor, "filesystem/read", {"path": target})
    assert after["content"] == "second"


@pytest.mark.parametrize("route,data,code", [
    ("filesystem/read", {"path": "res://notes/../../outside.txt"}, "invalid_path"),
    ("filesystem/read", {"path": "/etc/passwd"}, "invalid_path"),
    ("filesystem/write", {"path": "res://addons/gdapi/plugin.gd", "content": "x"}, "permission_denied"),
    ("filesystem/reimport", {"paths": ["res://addons/gdapi/plugin.gd"]}, "permission_denied"),
])
def test_filesystem_rejections(m2_editor, route, data, code):
    error = exec_error(m2_editor, route, data)
    assert error["code"] == code
