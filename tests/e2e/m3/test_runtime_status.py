"""M3 状态转换测试"""

from __future__ import annotations

from .conftest import (
    command_doc,
    exec_ok,
)


def test_runtime_status_initial_state_is_stopped(m3_editor):
    status = exec_ok(m3_editor, "runtime/status")
    assert status["state"] == "stopped"
    assert status["broker_registered"] is True
    assert status["pending"] == 0
    assert status["transport"] == "none"


def test_runtime_lifecycle_scenario(m3_lifecycle):
    initial = m3_lifecycle["initial"]
    assert initial["state"] == "stopped"
    assert initial["pending"] == 0

    assert len(m3_lifecycle["cycles"]) == 2
    for cycle in m3_lifecycle["cycles"]:
        assert cycle["started"]["runtime_state"] in ("connecting", "connected")
        assert cycle["connected"]["state"] == "connected"
        assert cycle["connected"]["protocol_version"] == 1
        assert cycle["connected"]["transport"] in ("file", "engine_debugger")
        assert cycle["stopped"]["runtime_state"] == "stopped"
        assert cycle["stopped_status"]["state"] == "stopped"
        assert cycle["stopped_status"]["pending"] == 0
        assert cycle["runtime_entries"] == []


def test_runtime_status_doc_has_returns(m3_editor):
    doc = command_doc(m3_editor, "runtime/status")
    assert doc["summary"]
    assert doc["returns"]["fields"]


def test_m3_editor_session_reuses_one_process_and_setup(m3_editor):
    assert m3_editor.get("build_count") == 1
    assert m3_editor.get("install_count") == 1
    assert m3_editor.get("editor_start_count") == 1
    assert m3_editor.get("editor_pids") == {m3_editor["godot"].pid}
