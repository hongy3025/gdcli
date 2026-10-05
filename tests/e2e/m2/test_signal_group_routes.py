"""Signal and group route acceptance tests."""

from __future__ import annotations

import pytest

from .helpers import exec_error, exec_ok

MAIN_SCENE = "res://scenes/main.tscn"
CONNECT_PERSIST = 2  # Object.CONNECT_PERSIST

PLAYER = "/root/Main/Player"
TARGET = "/root/Main/Target"
CONNECTION = {
    "source_path": PLAYER,
    "signal": "health_changed",
    "target_path": TARGET,
    "method": "_on_health_changed",
}


def _reopen_main_scene(editor) -> None:
    """Save-independent reload: close the edited scene and open it again from disk."""
    exec_ok(editor, "scene/close")
    exec_ok(editor, "scene/open", {"path": MAIN_SCENE})


def _connections(editor, node_path: str) -> list[dict]:
    return exec_ok(editor, "node/signal/list", {"node_path": node_path})["connections"]


def _find_connection(editor, node_path: str, target: str = TARGET) -> dict | None:
    for connection in _connections(editor, node_path):
        if (
            connection["signal"] == "health_changed"
            and connection["target"] == target
            and connection["method"] == "_on_health_changed"
        ):
            return connection
    return None


def _owned_connection(editor, name):
    target = exec_ok(editor, "node/create", {
        "parent_path": "/root/Main", "type": "Node2D", "name": name,
    })["node_path"]
    exec_ok(editor, "script/attach", {"node_path": target, "path": "res://scripts/target.gd"})
    return {**CONNECTION, "target_path": target}


def _group_nodes(editor, group: str) -> list[str]:
    return exec_ok(editor, "node/group/nodes", {"group": group})["node_paths"]


def test_signal_and_group_persist(m2_editor, m2_main):
    connection = _owned_connection(m2_editor, "SignalPersistenceTarget")
    target = connection["target_path"]
    connect_result = exec_ok(m2_editor, "node/signal/connect", connection)
    assert connect_result["undoable"] is True

    group_add = exec_ok(m2_editor, "node/group/add", {
        "node_path": target,
        "group": "signal_persistence_actors",
        "persistent": True,
    })
    assert group_add["undoable"] is True

    exec_ok(m2_editor, "scene/current/save")

    listed = _find_connection(m2_editor, PLAYER, target)
    assert listed is not None
    assert target in _group_nodes(m2_editor, "signal_persistence_actors")

    # Both mutations use CONNECT_PERSIST / persistent=true, so they must come
    # back from the scene file after a real close + reopen of the edited scene.
    _reopen_main_scene(m2_editor)

    reopened = _find_connection(m2_editor, PLAYER, target)
    assert reopened is not None, _connections(m2_editor, PLAYER)
    assert reopened["flags"] & CONNECT_PERSIST, reopened
    assert target in _group_nodes(m2_editor, "signal_persistence_actors")
    assert "signal_persistence_actors" in exec_ok(m2_editor, "node/group/list", {"node_path": target})["groups"]


def test_signal_disconnect_and_group_remove_persist(m2_editor, m2_main):
    connection = _owned_connection(m2_editor, "SignalRemovalTarget")
    target = connection["target_path"]
    exec_ok(m2_editor, "node/signal/connect", connection)
    exec_ok(m2_editor, "node/group/add", {
        "node_path": target,
        "group": "signal_removal_actors",
        "persistent": True,
    })
    exec_ok(m2_editor, "scene/current/save")

    # Sanity check on the persisted state before removing it again.
    _reopen_main_scene(m2_editor)
    assert _find_connection(m2_editor, PLAYER, target) is not None
    assert target in _group_nodes(m2_editor, "signal_removal_actors")

    disconnected = exec_ok(m2_editor, "node/signal/disconnect", connection)
    assert disconnected["undoable"] is True
    removed = exec_ok(m2_editor, "node/group/remove", {"node_path": target, "group": "signal_removal_actors"})
    assert removed["undoable"] is True

    assert _find_connection(m2_editor, PLAYER, target) is None
    assert target not in _group_nodes(m2_editor, "signal_removal_actors")

    exec_ok(m2_editor, "scene/current/save")
    _reopen_main_scene(m2_editor)

    assert _find_connection(m2_editor, PLAYER, target) is None
    assert target not in _group_nodes(m2_editor, "signal_removal_actors")
    assert "signal_removal_actors" not in exec_ok(m2_editor, "node/group/list", {"node_path": target})["groups"]


@pytest.mark.parametrize("route,data,code", [
    ("node/signal/connect", {
        "source_path": PLAYER,
        "signal": "health_changed",
        "target_path": TARGET,
        "method": "missing",
    }, "not_found"),
    ("node/signal/connect", {
        "source_path": PLAYER,
        "signal": "missing_signal",
        "target_path": TARGET,
        "method": "_on_health_changed",
    }, "not_found"),
    ("node/group/add", {
        "node_path": TARGET,
        "group": "",
        "persistent": True,
    }, "missing_param"),
])
def test_signal_group_rejections(m2_editor, m2_main, route, data, code):
    error = exec_error(m2_editor, route, data)
    assert error["code"] == code


def test_duplicate_signal_is_conflict(m2_editor, m2_main):
    connection = _owned_connection(m2_editor, "SignalDuplicateTarget")
    target = connection["target_path"]
    exec_ok(m2_editor, "node/signal/connect", connection)
    error = exec_error(m2_editor, "node/signal/connect", connection)
    assert error["code"] == "conflict"
