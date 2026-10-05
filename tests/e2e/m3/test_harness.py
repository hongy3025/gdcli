"""Behavioral contracts for persistent runtime diagnostics and lifecycle commands."""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from . import conftest as harness


def test_wait_for_editor_playing_waits_for_editor_flag(monkeypatch, tmp_path):
    statuses = iter([
        {"ok": True, "state": "stopped", "editor_playing": False},
        {"ok": True, "state": "connecting", "editor_playing": True},
    ])
    result = subprocess.CompletedProcess([], 0, stdout="", stderr="")
    monkeypatch.setattr(harness, "_poll_runtime_status", lambda _: (
        ["exec", "runtime/status"], result, next(statuses),
    ))
    assert harness.wait_for_editor_playing({"project": tmp_path}, timeout=1.0)["editor_playing"] is True


def test_readiness_failure_preserves_last_runtime_status_payload(monkeypatch, tmp_path: Path):
    status = {"ok": True, "state": "connecting", "pending": 1, "transport": "none"}
    args = ["exec", "runtime/status", "--project", str(tmp_path)]
    result = subprocess.CompletedProcess(args, 0, stdout='{"ok":true,"state":"connecting","pending":1,"transport":"none"}', stderr="")
    monkeypatch.setattr(harness, "_poll_runtime_status", lambda _: (args, result, status))
    env = {"project": tmp_path, "gdcli": "gdcli", "godot_log_path": tmp_path / "godot.log"}
    with pytest.raises(harness.HarnessFailure) as caught:
        harness.wait_for_connected(env, timeout=0.01)
    assert caught.value.diagnostics["runtime_status"] == status
    assert set(harness.DIAGNOSTIC_FIELDS) <= set(caught.value.diagnostics)


def test_failed_game_commands_preserve_lifecycle_state(monkeypatch, tmp_path):
    env = {"project": tmp_path, "game_run_count": 0, "game_stop_count": 0, "game_attached": False}
    failure = RuntimeError("command failed")
    monkeypatch.setattr(harness, "exec_ok", lambda *_args, **_kwargs: (_ for _ in ()).throw(failure))
    with pytest.raises(RuntimeError):
        harness.project_run(env)
    assert env["game_attached"] is False
    env["game_attached"] = True
    with pytest.raises(RuntimeError):
        harness.project_stop(env)
    assert env["game_attached"] is True
    assert env["game_run_count"] == env["game_stop_count"] == 0
    monkeypatch.setattr(harness, "exec_ok", lambda *_args, **_kwargs: {"ok": True})
    harness.project_stop(env)
    assert env["game_attached"] is False
    harness.project_run(env)
    assert env["game_attached"] is True
    assert env["game_run_count"] == env["game_stop_count"] == 1


def test_attach_failure_does_not_retry_or_stop(monkeypatch, tmp_path):
    env = {"project": tmp_path}
    calls = []
    failure = RuntimeError("runtime connection lost")
    monkeypatch.setattr(harness, "project_run", lambda _: calls.append("run"))
    monkeypatch.setattr(harness, "wait_for_editor_playing", lambda _: calls.append("playing"))
    monkeypatch.setattr(harness, "wait_for_connected", lambda _: (_ for _ in ()).throw(failure))
    monkeypatch.setattr(harness, "project_stop", lambda _: calls.append("stop"))
    with pytest.raises(RuntimeError) as caught:
        harness.attach_game(env)
    assert caught.value is failure
    assert calls == ["run", "playing"]


def test_ensure_running_never_recovers_lost_connection(monkeypatch, tmp_path):
    env = {"project": tmp_path, "gdcli": "gdcli", "game_attached": True}
    monkeypatch.setattr(harness, "exec_ok", lambda *_: {"ok": True, "state": "stopped"})
    monkeypatch.setattr(harness, "attach_game", lambda _: pytest.fail("must not restart"))
    with pytest.raises(harness.HarnessFailure, match="lost runtime connection"):
        harness.ensure_running(env)
