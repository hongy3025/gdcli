"""Lifecycle tests for the shared `e2e_editor` fixture and reset helpers.

These tests verify the deterministic per-test reset that stops games,
clears runtime transport, clears the audit log, and restores the
editor selection. Capability-policy overlay helpers were removed when
gdcli was repositioned as a development-time tool (2026-08-01); the
`temporary_policy` context manager is no longer used.
"""

from __future__ import annotations

import subprocess

import sys
from pathlib import Path
from typing import Any
from unittest import mock

import pytest

from tests.e2e import shared_fixture


REPO_ROOT = Path(__file__).resolve().parents[2]


def _fake_env(project: Path) -> dict[str, Any]:
    godot_log = project / ".godot" / "godot.log"
    godot_log.parent.mkdir(parents=True, exist_ok=True)
    godot_log.write_text("fake log\n", encoding="utf-8")
    return {
        "root": REPO_ROOT,
        "project": project,
        "fixture": project,
        "fixture_root": shared_fixture.E2E_FIXTURE_SOURCE,
        "godot_bin": "fake-godot",
        "gdcli": REPO_ROOT / "target" / "debug" / (
            "gdcli.exe" if sys.platform == "win32" else "gdcli"
        ),
        "godot": mock.MagicMock(
            poll=mock.Mock(return_value=None),
            pid=4242,
            terminate=mock.Mock(),
            wait=mock.Mock(return_value=0),
            returncode=0,
        ),
        "editor_pid": 4242,
        "meta": {"ping": "ok", "pid": 4242},
        "godot_log": mock.MagicMock(closed=False),
        "godot_log_path": godot_log,
        "game_attached": False,
    }


def test_reset_shared_state_reports_failing_phase(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path,
) -> None:
    """When a step inside reset fails, the exception names the failing phase."""
    project = tmp_path / "project"
    project.mkdir()
    env = _fake_env(project)

    def _fake_gdcli_call(_env, route, data=None):
        if route == "project/stop":
            raise AssertionError("simulated stop failure")
        return {"ok": True}

    monkeypatch.setattr(shared_fixture, "gdcli_call", _fake_gdcli_call)

    with pytest.raises(AssertionError) as exc_info:
        shared_fixture.reset_shared_state(env, reason="unit")
    assert "project/stop" in str(exc_info.value)
    assert "reason=unit" in str(exc_info.value)


def test_build_environment_yields_one_process(
    monkeypatch: pytest.MonkeyPatch, tmp_path_factory: pytest.TempPathFactory,
) -> None:
    """Two builds share the same Popen, PID, and metadata, and the start counter ticks once."""
    shared_fixture.EDITOR_START_COUNTER["starts"] = 0
    shared_fixture.EDITOR_START_COUNTER["pids"] = set()
    captured: dict[str, Any] = {}

    def _fake_start(env: dict[str, Any]) -> mock.MagicMock:
        process = mock.MagicMock(
            pid=9001,
            poll=mock.Mock(return_value=None),
            terminate=mock.Mock(),
            wait=mock.Mock(return_value=0),
            returncode=0,
        )
        env["godot"] = process
        env["editor_pid"] = process.pid
        env["meta"] = {"pid": process.pid, "ping": "ok"}
        captured["pid"] = process.pid
        return process

    monkeypatch.setattr(shared_fixture, "_start_editor", _fake_start)
    monkeypatch.setattr(
        shared_fixture.subprocess, "run",
        lambda cmd, *a, **kw: subprocess.CompletedProcess(cmd, 0, "", ""),
    )
    monkeypatch.setattr(shared_fixture, "require_godot_47", lambda _bin: (4, 7, 1))
    monkeypatch.setattr(
        shared_fixture, "wait_for_metadata",
        lambda _project: {"pid": captured["pid"], "ping": "ok"},
    )
    monkeypatch.setattr(shared_fixture, "wait_for_godot_ready", lambda _project: None)
    monkeypatch.setattr(shared_fixture, "_gdcli_ping", lambda _env: True)

    env = shared_fixture.build_environment(tmp_path_factory)
    try:
        assert env["editor_pid"] == captured["pid"]
        assert env["meta"]["pid"] == captured["pid"]
    finally:
        shared_fixture.teardown_environment(env)

    assert shared_fixture.EDITOR_START_COUNTER["starts"] == 1
    assert shared_fixture.EDITOR_START_COUNTER["pids"] == {captured["pid"]}


def test_build_editor_command_uses_headless_audio_driver(tmp_path: Path):
    assert shared_fixture.build_editor_command("godot.exe", tmp_path) == [
        "godot.exe",
        "--editor",
        "--headless",
        "--audio-driver",
        "Dummy",
        "--path",
        str(tmp_path),
    ]


def test_build_editor_environment_isolates_godot_user_data(tmp_path: Path):
    environment = shared_fixture.build_editor_environment(tmp_path)

    assert Path(environment["APPDATA"]) == tmp_path / ".godot" / "appdata"
    assert Path(environment["LOCALAPPDATA"]) == tmp_path / ".godot" / "localappdata"
    assert Path(environment["APPDATA"]).is_dir()
    assert Path(environment["LOCALAPPDATA"]).is_dir()


def test_build_environment_copies_unified_project(
    monkeypatch: pytest.MonkeyPatch, tmp_path_factory: pytest.TempPathFactory,
) -> None:
    """The fixture lays down a copy of tests/fixtures/e2e_project."""
    shared_fixture.EDITOR_START_COUNTER["starts"] = 0

    captured_project: dict[str, Path] = {}

    def _fake_start(env: dict[str, Any]) -> mock.MagicMock:
        captured_project["path"] = env["project"]
        process = mock.MagicMock(
            pid=2,
            poll=mock.Mock(return_value=None),
            terminate=mock.Mock(),
            wait=mock.Mock(return_value=0),
            returncode=0,
        )
        env["godot"] = process
        env["editor_pid"] = process.pid
        env["meta"] = {"pid": process.pid}
        return process

    monkeypatch.setattr(shared_fixture, "_start_editor", _fake_start)
    monkeypatch.setattr(
        shared_fixture.subprocess, "run",
        lambda cmd, *a, **kw: subprocess.CompletedProcess(cmd, 0, "", ""),
    )
    monkeypatch.setattr(shared_fixture, "require_godot_47", lambda _b: (4, 7, 1))
    monkeypatch.setattr(shared_fixture, "wait_for_metadata", lambda _p: {"pid": 2})
    monkeypatch.setattr(shared_fixture, "wait_for_godot_ready", lambda _p: None)
    monkeypatch.setattr(shared_fixture, "_gdcli_ping", lambda _e: True)

    env = shared_fixture.build_environment(tmp_path_factory)
    try:
        project = captured_project["path"]
        assert (project / "project.godot").is_file()
        assert (project / "addons" / "gdapi_test" / "plugin.gd").is_file()

        assert env["fixture_root"] is shared_fixture.E2E_FIXTURE_SOURCE
    finally:
        shared_fixture.teardown_environment(env)
