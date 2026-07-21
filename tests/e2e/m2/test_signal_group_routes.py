"""Signal and group route acceptance tests."""

from __future__ import annotations

import pytest

from .helpers import exec_error, exec_ok


def test_signal_and_group_persist(m2_editor):
    connection = {
        "source_path": "/root/Main/Player",
        "signal": "health_changed",
        "target_path": "/root/Main/Target",
        "method": "_on_health_changed",
    }
    connect_result = exec_ok(m2_editor, "node/signal/connect", connection)
    assert connect_result["undoable"] is False

    group_add = exec_ok(m2_editor, "node/group/add", {
        "node_path": "/root/Main/Target",
        "group": "actors",
        "persistent": True,
    })
    assert group_add["undoable"] is False

    exec_ok(m2_editor, "scene/current/save")

    listed = exec_ok(m2_editor, "node/signal/list", {
        "node_path": "/root/Main/Player",
    })
    found = False
    for c in listed["connections"]:
        if c["signal"] == "health_changed" and c["target"].endswith("/Target") and c["method"] == "_on_health_changed":
            found = True
            break
    assert found

    members = exec_ok(m2_editor, "node/group/nodes", {"group": "actors"})
    assert any(p.endswith("/Target") for p in members["node_paths"])


@pytest.mark.parametrize("route,data,code", [
    ("node/signal/connect", {
        "source_path": "/root/Main/Player",
        "signal": "health_changed",
        "target_path": "/root/Main/Target",
        "method": "missing",
    }, "not_found"),
    ("node/signal/connect", {
        "source_path": "/root/Main/Player",
        "signal": "missing_signal",
        "target_path": "/root/Main/Target",
        "method": "_on_health_changed",
    }, "not_found"),
    ("node/group/add", {
        "node_path": "/root/Main/Target",
        "group": "",
        "persistent": True,
    }, "missing_param"),
])
def test_signal_group_rejections(m2_editor, route, data, code):
    error = exec_error(m2_editor, route, data)
    assert error["code"] == code


def test_duplicate_signal_is_conflict(m2_editor):
    connection = {
        "source_path": "/root/Main/Player",
        "signal": "health_changed",
        "target_path": "/root/Main/Target",
        "method": "_on_health_changed",
    }
    exec_ok(m2_editor, "node/signal/connect", connection)
    error = exec_error(m2_editor, "node/signal/connect", connection)
    assert error["code"] == "conflict"
