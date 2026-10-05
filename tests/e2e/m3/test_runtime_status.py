"""M3 状态转换测试"""

from __future__ import annotations

from .conftest import command_doc, detach_game, project_run, wait_for_connected, wait_for_editor_playing


def test_runtime_lifecycle_scenario(m3_editor):
    stopped = detach_game(m3_editor)
    assert stopped["state"] == "stopped"
    assert stopped["broker_registered"] is True
    assert stopped["pending"] == 0
    assert stopped["transport"] == "none"
    generations = set()
    for _ in range(2):
        started = project_run(m3_editor)
        assert started["runtime_state"] in ("connecting", "connected")
        assert m3_editor["game_attached"] is True
        wait_for_editor_playing(m3_editor)
        connected = wait_for_connected(m3_editor)
        assert connected["state"] == "connected"
        assert connected["protocol_version"] >= 1
        assert connected["transport"] in ("file", "engine_debugger")
        assert connected["generation"]
        assert connected["generation"] not in generations
        generations.add(connected["generation"])
        stopped = detach_game(m3_editor)
        assert stopped["state"] == "stopped"
        assert stopped["pending"] == 0
        assert stopped["editor_playing"] is False
        assert m3_editor["game_attached"] is False


def test_runtime_status_doc_has_returns(m3_editor):
    doc = command_doc(m3_editor, "runtime/status")
    assert doc["summary"]
    assert doc["returns"]["fields"]




