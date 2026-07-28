"""Behavioral contracts for the M3 harness failure and cleanup paths."""

from __future__ import annotations

import io
import subprocess
from pathlib import Path

import pytest

from . import conftest as harness


def _diagnostics() -> dict:
    return {
        "command": ["gdcli", "--json", "exec", "project/stop"],
        "exit_code": 1,
        "stdout": "",
        "stderr": "pending request",
        "runtime_status": {"state": "connected", "pending": 1},
        "godot_log_tail": "runtime disconnect",
    }


def _failure(message: str) -> RuntimeError:
    error = RuntimeError(message)
    error.diagnostics = _diagnostics()
    return error


def test_detach_game_preserves_attachment_and_diagnostics_when_wait_fails(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    env = {"project": tmp_path, "game_attached": True, "game_stop_count": 0}
    monkeypatch.setattr(harness, "project_stop", lambda _env: {"ok": True})
    monkeypatch.setattr(
        harness,
        "wait_stopped",
        lambda _env, timeout=15.0: (_ for _ in ()).throw(
            _failure("pending request did not drain")
        ),
    )
    monkeypatch.setattr(harness, "cleanup_stale_runtime", lambda _env: None)

    with pytest.raises(RuntimeError) as caught:
        harness.detach_game(env)

    assert env["game_attached"] is True
    diagnostics = getattr(caught.value, "diagnostics", {})
    assert set(harness.DIAGNOSTIC_FIELDS) <= set(diagnostics)


class _FakeEditorProcess:
    pid = 4242

    def __init__(self):
        self.terminated = False
        self.killed = False
        self.wait_calls = 0

    def poll(self):
        return None if not self.killed else -9

    def terminate(self):
        self.terminated = True

    def wait(self, timeout=None):
        self.wait_calls += 1
        if self.wait_calls == 1:
            raise subprocess.TimeoutExpired("godot", timeout)
        return -9

    def kill(self):
        self.killed = True


def test_detach_editor_retries_game_teardown_then_kills_and_reports_diagnostics(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    process = _FakeEditorProcess()
    teardown_calls = []

    def failing_detach(_env):
        teardown_calls.append(True)
        raise _failure("game stop failed")

    env = {
        "project": tmp_path,
        "game_attached": True,
        "godot": process,
        "godot_log": io.StringIO("log"),
        "recovery_events": [],
    }
    monkeypatch.setattr(harness, "detach_game", failing_detach)
    monkeypatch.setattr(harness, "cleanup_stale_runtime", lambda _env: None)

    with pytest.warns(RuntimeWarning) as recovery_warnings:
        harness.detach_editor(env)

    assert len(teardown_calls) == 2
    assert len(recovery_warnings) == 2
    assert process.killed is True
    assert env["game_attached"] is True
    recovery_text = "\n".join(map(str, env["recovery_events"]))
    assert all(field in recovery_text for field in harness.DIAGNOSTIC_FIELDS)
