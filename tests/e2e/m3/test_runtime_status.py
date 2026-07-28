"""M3 状态转换测试"""

from __future__ import annotations

import json

import pytest

from .conftest import (
    command_doc,
    exec_ok,
    project_run,
    project_stop,
    wait_for_connected,
    wait_for,
    wait_stopped,
)


def test_runtime_status_initial_state_is_stopped(m3_editor):
    status = exec_ok(m3_editor, "runtime/status")
    assert status["state"] == "stopped"
    assert status["broker_registered"] is True
    assert status["pending"] == 0
    assert status["transport"] == "none"


def test_runtime_status_after_run_reaches_connected(m3_editor):
    project_run(m3_editor)
    try:
        wait_for_connected(m3_editor, timeout=30.0)
        status = exec_ok(m3_editor, "runtime/status")
        assert status["state"] == "connected"
        assert status["protocol_version"] == 1
        assert status["transport"] in ("file", "engine_debugger")
    finally:
        project_stop(m3_editor)
        wait_stopped(m3_editor, timeout=30.0)


def test_runtime_status_two_consecutive_runs(m3_editor):
    # 第一次
    project_run(m3_editor)
    wait_for_connected(m3_editor, timeout=30.0)
    project_stop(m3_editor)
    wait_stopped(m3_editor, timeout=30.0)
    assert exec_ok(m3_editor, "runtime/status")["pending"] == 0

    # 第二次
    project_run(m3_editor)
    wait_for_connected(m3_editor, timeout=30.0)
    project_stop(m3_editor)
    wait_stopped(m3_editor, timeout=30.0)
    assert exec_ok(m3_editor, "runtime/status")["pending"] == 0


def test_runtime_status_doc_has_returns(m3_editor):
    doc = command_doc(m3_editor, "runtime/status")
    assert doc["summary"]
    assert doc["returns"]["fields"]
