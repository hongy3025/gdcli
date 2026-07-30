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


def test_detach_game_preserves_attachment_when_stale_cleanup_fails(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    env = {"project": tmp_path, "game_attached": True, "game_stop_count": 0}
    monkeypatch.setattr(harness, "project_stop", lambda _env: {"ok": True})
    monkeypatch.setattr(
        harness,
        "wait_stopped",
        lambda _env, timeout=15.0: {"state": "stopped", "pending": 0},
    )
    monkeypatch.setattr(
        harness,
        "cleanup_stale_runtime",
        lambda _env: (_ for _ in ()).throw(_failure("stale cleanup failed")),
    )

    with pytest.raises(RuntimeError) as caught:
        harness.detach_game(env)

    assert env["game_attached"] is True
    diagnostics = getattr(caught.value, "diagnostics", {})
    assert set(harness.DIAGNOSTIC_FIELDS) <= set(diagnostics)


def test_readiness_failure_preserves_last_runtime_status_payload(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    status = {"ok": True, "state": "connecting", "pending": 1, "transport": "none"}
    args = ["exec", "runtime/status", "--project", str(tmp_path)]
    result = subprocess.CompletedProcess(
        ["gdcli", "--json", *args], 0, stdout="{" + '"ok":true,"state":"connecting","pending":1,"transport":"none"' + "}", stderr=""
    )
    monkeypatch.setattr(harness, "_poll_runtime_status", lambda _env: (args, result, status))
    env = {"project": tmp_path, "gdcli": "gdcli", "godot_log_path": tmp_path / "godot.log"}

    with pytest.raises(harness.HarnessFailure) as caught:
        harness.wait_for_connected(env, timeout=0.01)

    assert caught.value.diagnostics["runtime_status"] == status
    assert set(harness.DIAGNOSTIC_FIELDS) <= set(caught.value.diagnostics)


def test_reset_failure_preserves_last_runtime_status_payload(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    status = {"ok": False, "state": "connected", "pending": 2, "code": "conflict"}
    args = ["exec", "runtime/status", "--project", str(tmp_path)]
    result = subprocess.CompletedProcess(
        ["gdcli", "--json", *args], 1, stdout='{"ok":false,"state":"connected","pending":2,"code":"conflict"}', stderr=""
    )
    monkeypatch.setattr(harness, "_run_cli", lambda _env, _args, timeout=35, **kwargs: result)
    env = {"project": tmp_path, "gdcli": "gdcli", "godot_log_path": tmp_path / "godot.log"}

    with pytest.raises(harness.HarnessFailure) as caught:
        harness.reset_fixture(env)

    assert caught.value.diagnostics["runtime_status"] == status
    assert set(harness.DIAGNOSTIC_FIELDS) <= set(caught.value.diagnostics)


def test_reset_recovery_restores_environment_but_fails_affected_test(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    env = {
        "project": tmp_path,
        "gdcli": "gdcli",
        "godot_log_path": tmp_path / "godot.log",
        "game_attached": True,
        "fixture_reset_count": 0,
        "recovery_markers": [],
        "recovery_events": [],
    }
    original = _failure("fixture reset lost broker reply")
    attempts = iter([
        original,
        {"ok": True, "changed": True, "undoable": False},
    ])

    monkeypatch.setattr(
        harness,
        "exec_ok",
        lambda _env, route, data=None: {
            "ok": True, "state": "connected", "pending": 0,
            "transport": "engine_debugger",
        } if route == "runtime/status" else {},
    )

    def reset_once(_env):
        outcome = next(attempts)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome

    monkeypatch.setattr(harness, "_fixture_hook_reset_once", reset_once)
    monkeypatch.setattr(harness, "detach_game", lambda _env: _env.update(game_attached=False))
    monkeypatch.setattr(
        harness,
        "attach_game",
        lambda _env, recovery_restarts=0: _env.update(game_attached=True),
    )
    monkeypatch.setattr(harness, "_record_recovery", lambda *_args: None)
    monkeypatch.setattr(
        harness,
        "_diagnostics",
        lambda *_args: (_ for _ in ()).throw(
            AssertionError("original HarnessFailure diagnostics must not be rebuilt")
        ),
    )

    with pytest.raises(harness.HarnessFailure) as caught:
        harness.reset_fixture(env)

    assert env["game_attached"] is True
    assert caught.value.diagnostics["stderr"] == "pending request"
    assert caught.value.diagnostics["recovery_succeeded"] is True
    assert len(env["recovery_markers"]) == 1


def test_file_transport_reset_uses_public_broker_node_call(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    env = {
        "project": tmp_path,
        "gdcli": "gdcli",
        "godot_log_path": tmp_path / "godot.log",
        "game_attached": True,
        "fixture_reset_count": 0,
    }
    calls = []

    def exec_result(_env, route, data=None):
        calls.append((route, data))
        if route == "runtime/status":
            return {
                "ok": True,
                "state": "connected",
                "pending": 0,
                "transport": "file",
            }
        if route == "runtime/node/call":
            return {
                "ok": True,
                "method": "reset_shared_fixture",
                "result": {"changed": True, "undoable": False},
            }
        raise AssertionError(f"unexpected route: {route}")

    monkeypatch.setattr(harness, "exec_ok", exec_result)

    assert harness.reset_fixture(env)["changed"] is True
    assert calls == [
        ("runtime/status", None),
        ("runtime/node/call", {
            "node_path": "/root/RuntimeMain/ProbeTarget",
            "method": "reset_shared_fixture",
            "args": [],
        }),
    ]


def test_session_budget_accepts_planned_starts_and_rejects_recovery():
    harness.assert_session_budget({
        "editor_start_count": 1,
        "game_run_count": 3,
        "fixture_reset_restarts": 0,
        "recovery_markers": [],
    })

    with pytest.raises(AssertionError, match="game starts"):
        harness.assert_session_budget({
            "editor_start_count": 1,
            "game_run_count": 4,
            "fixture_reset_restarts": 1,
            "recovery_markers": [{"operation": "runtime/fixture/reset"}],
        })


def test_session_finalizer_reports_cleanup_and_budget_failures(
    monkeypatch: pytest.MonkeyPatch
):
    cleanup_error = RuntimeError("editor cleanup failed")
    monkeypatch.setattr(
        harness,
        "detach_editor",
        lambda _env: (_ for _ in ()).throw(cleanup_error),
    )
    env = {
        "editor_start_count": 1,
        "game_run_count": 4,
        "fixture_reset_restarts": 1,
        "recovery_markers": [{"operation": "runtime/fixture/reset"}],
        "recovery_events": [],
    }

    with pytest.raises(ExceptionGroup) as caught:
        harness.finalize_m3_session(env)

    messages = [str(error) for error in caught.value.exceptions]
    assert messages[0] == "editor cleanup failed"
    assert "M3 session budget violated" in messages[1]


def test_failed_game_commands_do_not_increment_lifecycle_counters(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    env = {"project": tmp_path, "game_run_count": 0, "game_stop_count": 0}
    failure = RuntimeError("command failed")
    monkeypatch.setattr(harness, "exec_ok", lambda *_args, **_kwargs: (_ for _ in ()).throw(failure))

    with pytest.raises(RuntimeError):
        harness.project_run(env)
    with pytest.raises(RuntimeError):
        harness.project_stop(env)
    assert env["game_run_count"] == 0
    assert env["game_stop_count"] == 0

    monkeypatch.setattr(harness, "exec_ok", lambda *_args, **_kwargs: {"ok": True})
    harness.project_run(env)
    harness.project_stop(env)
    assert env["game_run_count"] == 1
    assert env["game_stop_count"] == 1


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
