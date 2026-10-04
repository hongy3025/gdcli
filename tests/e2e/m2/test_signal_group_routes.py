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


def _find_connection(editor, node_path: str) -> dict | None:
    for connection in _connections(editor, node_path):
        if (
            connection["signal"] == "health_changed"
            and connection["target"] == TARGET
            and connection["method"] == "_on_health_changed"
        ):
            return connection
    return None


def _group_nodes(editor, group: str) -> list[str]:
    return exec_ok(editor, "node/group/nodes", {"group": group})["node_paths"]


def test_signal_and_group_persist(m2_editor):
    connect_result = exec_ok(m2_editor, "node/signal/connect", CONNECTION)
    assert connect_result["undoable"] is True

    group_add = exec_ok(m2_editor, "node/group/add", {
        "node_path": TARGET,
        "group": "actors",
        "persistent": True,
    })
    assert group_add["undoable"] is True

    exec_ok(m2_editor, "scene/current/save")

    listed = _find_connection(m2_editor, PLAYER)
    assert listed is not None
    assert TARGET in _group_nodes(m2_editor, "actors")

    # Both mutations use CONNECT_PERSIST / persistent=true, so they must come
    # back from the scene file after a real close + reopen of the edited scene.
    _reopen_main_scene(m2_editor)

    reopened = _find_connection(m2_editor, PLAYER)
    assert reopened is not None, _connections(m2_editor, PLAYER)
    assert reopened["flags"] & CONNECT_PERSIST, reopened
    assert TARGET in _group_nodes(m2_editor, "actors")
    assert "actors" in exec_ok(m2_editor, "node/group/list", {"node_path": TARGET})["groups"]


def test_signal_disconnect_and_group_remove_persist(m2_editor):
    exec_ok(m2_editor, "node/signal/connect", CONNECTION)
    exec_ok(m2_editor, "node/group/add", {
        "node_path": TARGET,
        "group": "actors",
        "persistent": True,
    })
    exec_ok(m2_editor, "scene/current/save")

    # Sanity check on the persisted state before removing it again.
    _reopen_main_scene(m2_editor)
    assert _find_connection(m2_editor, PLAYER) is not None
    assert TARGET in _group_nodes(m2_editor, "actors")

    disconnected = exec_ok(m2_editor, "node/signal/disconnect", CONNECTION)
    assert disconnected["undoable"] is True
    removed = exec_ok(m2_editor, "node/group/remove", {"node_path": TARGET, "group": "actors"})
    assert removed["undoable"] is True

    assert _find_connection(m2_editor, PLAYER) is None
    assert TARGET not in _group_nodes(m2_editor, "actors")

    exec_ok(m2_editor, "scene/current/save")
    _reopen_main_scene(m2_editor)

    assert _find_connection(m2_editor, PLAYER) is None
    assert TARGET not in _group_nodes(m2_editor, "actors")
    assert "actors" not in exec_ok(m2_editor, "node/group/list", {"node_path": TARGET})["groups"]


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
def test_signal_group_rejections(m2_editor, route, data, code):
    error = exec_error(m2_editor, route, data)
    assert error["code"] == code


def test_duplicate_signal_is_conflict(m2_editor):
    exec_ok(m2_editor, "node/signal/connect", CONNECTION)
    error = exec_error(m2_editor, "node/signal/connect", CONNECTION)
    assert error["code"] == "conflict"
