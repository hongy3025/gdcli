"""Real editor UndoRedo acceptance test — migrated to shared editor.

The original test created its own Godot editor process with a standalone
fixture project. This version uses the session-scoped shared editor and
exercises the same EditableAction contract through gdcli routes and the
test-plugin command channel.
"""

from __future__ import annotations

from typing import Any

import pytest

from e2e.m2.helpers import editor_redo, editor_undo, exec_ok


@pytest.mark.usefixtures("e2e_editor")
def test_edit_action_commit_property_undo_redo(e2e_editor: dict[str, Any]) -> None:
    """EditAction.commit_property produces undoable/redoable actions.

    Uses the shared editor's test-plugin command channel to exercise
    the same UndoRedo contract as the original standalone test.
    """
    # Read a known property on a stable node
    pos = exec_ok(e2e_editor, "node/property/get", {
        "node_path": "/root/Main/Player",
        "property": "position",
    })
    assert pos["value"]["type"] == "Vector2"
    original = pos["value"]

    # Change the property — should be undoable
    new_position = {"type": "Vector2", "value": [41.0, 73.0]}
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