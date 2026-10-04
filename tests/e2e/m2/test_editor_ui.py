"""Selection and main-screen route acceptance tests."""

from __future__ import annotations

import pytest

from .helpers import exec_error, exec_ok


def test_selection_round_trip(m2_editor):
    result = exec_ok(m2_editor, "editor/selection/set", {
        "node_paths": ["/root/Main/Player", "/root/Main/Target"]
    })
    assert result["changed"] is True and result["undoable"] is False
    assert sorted(result["node_paths"]) == sorted(
        ["/root/Main/Player", "/root/Main/Target"]
    )
    sel = exec_ok(m2_editor, "editor/selection/get")
    assert sorted(sel["node_paths"]) == sorted(
        ["/root/Main/Player", "/root/Main/Target"]
    )


def test_selection_atomically_rejects_missing(m2_editor):
    exec_ok(m2_editor, "editor/selection/set", {
        "node_paths": ["/root/Main/Player"]
    })
    error = exec_error(m2_editor, "editor/selection/set", {
        "node_paths": ["/root/Main/Player", "/root/Main/Missing"]
    })
    assert error["code"] == "not_found"
    sel = exec_ok(m2_editor, "editor/selection/get")
    assert sel["node_paths"] == ["/root/Main/Player"]


def test_main_screen_allowlist(m2_editor):
    result = exec_ok(m2_editor, "editor/main_screen/set", {"screen": "Script"})
    assert result["screen"] == "Script"
    assert result["changed"] is True
    assert exec_error(
        m2_editor,
        "editor/main_screen/set",
        {"screen": "Debugger"},
    )["code"] == "invalid_param"


def test_node_select_routes_through_selection_service(m2_editor):
    result = exec_ok(m2_editor, "node/select", {
        "node_paths": ["/root/Main/Player"]
    })
    assert result["changed"] is True
    assert result["node_paths"] == ["/root/Main/Player"]
