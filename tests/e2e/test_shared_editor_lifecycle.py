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

from e2e import shared_fixture


REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(autouse=True)
def _preserve_editor_start_counter():
    """这些用例会重置/递增全局启动计数：结束后必须还原，
    否则会话级"只启动一个编辑器"的断言会被污染。"""
    snapshot = dict(shared_fixture.EDITOR_START_COUNTER)
    snapshot["pids"] = set(snapshot.get("pids", set()))
    snapshot["callers"] = list(snapshot.get("callers", []))
    yield
    shared_fixture.EDITOR_START_COUNTER.clear()
    shared_fixture.EDITOR_START_COUNTER.update(snapshot)


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


def test_project_settings_save_temporary_file_is_not_tracked() -> None:
    assert not shared_fixture.is_tracked_project_file("project.godot61736153.tmp")
    assert not shared_fixture.is_tracked_project_file("project.godot")
    assert shared_fixture.is_tracked_project_file("scenes/project.godot61736153.tmp")
    assert shared_fixture.is_tracked_project_file("scenes/main.tscn")
    assert not shared_fixture.is_tracked_project_file("default_bus_layout.tres152465955.tmp")
    assert not shared_fixture.is_tracked_project_file("default_bus_layout.tres")
    assert shared_fixture.is_tracked_project_file("scenes/default_bus_layout.tres152465955.tmp")
    assert shared_fixture.is_tracked_project_file("default_bus_layout.tres.backup.tmp")


def test_reset_skips_stop_when_game_is_known_detached(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path,
) -> None:
    project = tmp_path / "project"
    project.mkdir()
    env = _fake_env(project)
    env["game_attached"] = False
    calls: list[str] = []
    monkeypatch.setattr(
        shared_fixture, "gdcli_call",
        lambda _env, route, _data=None: calls.append(route) or {"ok": True},
    )
    monkeypatch.setattr(shared_fixture, "wait_for_scene", lambda *_args: True)

    shared_fixture.reset_shared_state(env, reason="detached")

    assert "project/stop" not in calls
    assert "scene/open" in calls
    assert "editor/selection/set" in calls
    assert "gdapi/audit/clear" in calls


def test_reset_shared_state_reports_failing_phase(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path,
) -> None:
    """When a step inside reset fails, the exception names the failing phase."""
    project = tmp_path / "project"
    project.mkdir()
    env = _fake_env(project)
    env["game_attached"] = True

    def _fake_gdcli_call(_env, route, data=None):
        if route == "project/stop":
            raise AssertionError("simulated stop failure")
        return {"ok": True}

    monkeypatch.setattr(shared_fixture, "gdcli_call", _fake_gdcli_call)
    monkeypatch.setattr(shared_fixture, "wait_for_scene", lambda *_args: True)

    with pytest.raises(AssertionError) as exc_info:
        shared_fixture.reset_shared_state(env, reason="unit")
    assert "project/stop" in str(exc_info.value)
    assert "reason=unit" in str(exc_info.value)


def test_build_environment_yields_one_process(
    monkeypatch: pytest.MonkeyPatch, tmp_path_factory: pytest.TempPathFactory,
) -> None:
    """Build copies the unified project and starts exactly one shared process."""
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
    monkeypatch.setattr(shared_fixture, "wait_for_scene", lambda *_args: True)
    monkeypatch.setattr(shared_fixture, "_gdcli_ping", lambda _env: True)

    env = shared_fixture.build_environment(tmp_path_factory)
    try:
        assert env["editor_pid"] == captured["pid"]
        assert env["meta"]["pid"] == captured["pid"]
        project = Path(env["project"])
        assert (project / "project.godot").is_file()
        assert (project / "addons" / "gdapi_test" / "plugin.gd").is_file()
        assert env["fixture_root"] is shared_fixture.E2E_FIXTURE_SOURCE
    finally:
        shared_fixture.teardown_environment(env, reset=False)  # mock 环境没有真实编辑器可重置

    assert shared_fixture.EDITOR_START_COUNTER["starts"] == 1
    assert shared_fixture.EDITOR_START_COUNTER["pids"] == {captured["pid"]}




def test_build_editor_environment_isolates_godot_user_data(tmp_path: Path):
    environment = shared_fixture.build_editor_environment(tmp_path)

    assert Path(environment["APPDATA"]) == tmp_path / ".godot" / "appdata"
    assert Path(environment["LOCALAPPDATA"]) == tmp_path / ".godot" / "localappdata"
    assert Path(environment["APPDATA"]).is_dir()
    assert Path(environment["LOCALAPPDATA"]).is_dir()



def test_start_editor_terminates_process_when_readiness_fails(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path,
) -> None:
    from e2e.timing import TIMINGS

    monkeypatch.setattr(TIMINGS, "enabled", False)
    project = tmp_path / "project"
    project.mkdir()
    process = mock.MagicMock(
        pid=4321,
        poll=mock.Mock(return_value=None),
        terminate=mock.Mock(),
        wait=mock.Mock(return_value=0),
    )
    monkeypatch.setattr(shared_fixture, "build_editor_command", lambda *_: ["fake-godot"])
    monkeypatch.setattr(shared_fixture, "build_editor_environment", lambda *_: {})
    monkeypatch.setattr(shared_fixture.subprocess, "Popen", lambda *_, **__: process)
    monkeypatch.setattr(shared_fixture, "wait_for_metadata", lambda _: {"pid": process.pid})
    monkeypatch.setattr(shared_fixture, "_gdcli_ping", lambda _: True)

    def fail_readiness(_: Path) -> None:
        raise RuntimeError("editor readiness failed")

    monkeypatch.setattr(shared_fixture, "wait_for_godot_ready", fail_readiness)
    env = {"godot_bin": "fake-godot", "project": project}

    with pytest.raises(RuntimeError, match="editor readiness failed"):
        shared_fixture._start_editor(env)

    process.terminate.assert_called_once_with()
    process.wait.assert_called_once_with(timeout=10)
    assert env["godot_log"].closed


def test_file_baseline_restores_mutations_without_touching_excluded_state(tmp_path):
    contents = {
        "scenes/main.tscn": b"original scene",
        "addons/gdapi_test/plugin.gd": b"fixture plugin",
        ".godot/cache/generated.bin": b"editor cache",
        "addons/gdapi/runtime/plugin.gd": b"installed addon",
        "project.godot": b"engine configuration",
    }
    for relative, data in contents.items():
        path = tmp_path / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    env = {"project": tmp_path}
    baseline = shared_fixture.snapshot_files(env)
    assert baseline == {
        "scenes/main.tscn": b"original scene",
        "addons/gdapi_test/plugin.gd": b"fixture plugin",
    }
    (tmp_path / "scenes/main.tscn").write_bytes(b"mutated")
    (tmp_path / "addons/gdapi_test/plugin.gd").unlink()
    (tmp_path / "scenes/temporary.tscn").write_bytes(b"created")
    (tmp_path / ".godot/cache/generated.bin").write_bytes(b"new cache")
    shared_fixture.restore_file_state(env, baseline)
    assert shared_fixture.snapshot_files(env) == baseline
    assert not (tmp_path / "scenes/temporary.tscn").exists()
    assert (tmp_path / ".godot/cache/generated.bin").read_bytes() == b"new cache"
    assert (tmp_path / "addons/gdapi/runtime/plugin.gd").read_bytes() == b"installed addon"
    assert (tmp_path / "project.godot").read_bytes() == b"engine configuration"
