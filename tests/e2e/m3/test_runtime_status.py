"""M3 状态转换测试"""

from __future__ import annotations

from pathlib import Path

from . import conftest as harness
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
    assert m3_editor.get("setup_events") == ["build", "install", "editor_start"]


def test_reset_connected_game_cleans_stale_transport(m3_editor):
    assert m3_editor.get("pre_attach_stale_removed") is True
    harness.attach_game(m3_editor)
    try:
        connected = exec_ok(m3_editor, "runtime/status")
        assert connected["state"] == "connected"
        stale = Path(m3_editor["project"]) / ".godot" / "gdapi_runtime" / "stale" / "reply.json"
        stale.parent.mkdir(parents=True, exist_ok=True)
        stale.write_text("stale", encoding="utf-8")

        stopped = harness.reset_fixture(m3_editor)

        assert stopped["state"] == "stopped"
        assert stopped["pending"] == 0
        assert not stale.exists()
        assert m3_editor["game_attached"] is False
    finally:
        if m3_editor.get("game_attached"):
            harness.detach_game(m3_editor)
