"""Real property changes retain native undo/redo history in the ongoing editor."""

from __future__ import annotations

from typing import Any

import pytest

from e2e.m2.helpers import editor_redo, editor_undo, exec_ok
from e2e.shared_fixture import wait_for_scene


@pytest.mark.usefixtures("e2e_editor")
def test_edit_action_commit_property_undo_redo(e2e_editor: dict[str, Any]) -> None:
    """Undo restores the live prior value; redo restores the authored value."""
    path = "res://scenes/main.tscn"
    if exec_ok(e2e_editor, "scene/current")["path"] != path:
        exec_ok(e2e_editor, "scene/open", {"path": path})
        assert wait_for_scene(e2e_editor, path)
    # Read a known property on a stable node
    pos = exec_ok(e2e_editor, "node/property/get", {
        "node_path": "/root/Main/Player",
        "property": "position",
    })
    assert pos["value"]["type"] == "Vector2"
    original = pos["value"]

    # Change the property — should be undoable
    new_position = {
        "type": "Vector2",
        "value": [original["value"][0] + 41.0, original["value"][1] + 73.0],
    }
    set_result = exec_ok(e2e_editor, "node/property/set", {
        "node_path": "/root/Main/Player",
        "property": "position",
        "value": new_position,
    })
    assert set_result["undoable"] is True

    # Verify the change took effect
    pos = exec_ok(e2e_editor, "node/property/get", {
        "node_path": "/root/Main/Player",
        "property": "position",
    })["value"]
    assert pos == new_position

    # Undo via the test-plugin command channel
    editor_undo(e2e_editor)
    pos = exec_ok(e2e_editor, "node/property/get", {
        "node_path": "/root/Main/Player",
        "property": "position",
    })["value"]
    assert pos == original, "undo did not restore original value"

    # Redo via the test-plugin command channel
    editor_redo(e2e_editor)
    pos = exec_ok(e2e_editor, "node/property/get", {
        "node_path": "/root/Main/Player",
        "property": "position",
    })["value"]
    assert pos == new_position, "redo did not restore changed value"