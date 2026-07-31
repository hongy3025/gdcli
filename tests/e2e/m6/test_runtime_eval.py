"""E2E tests for runtime/eval across v1/v2 boundaries."""

from __future__ import annotations

from typing import Any

import pytest

from .conftest import exec_error, exec_ok, start_async_exec, stop_game


def test_runtime_eval_requires_running_probe(m6_editor_eval: dict[str, Any]) -> None:
    error = exec_error(m6_editor_eval, "runtime/eval", {"source": "1 + 1"})
    assert error["code"] == "conflict"


def test_runtime_eval_runs_only_in_game_process(m6_runtime_eval_running: dict[str, Any]) -> None:
    result = exec_ok(
        m6_runtime_eval_running,
        "runtime/eval",
        {"source": "runtime_marker + 1", "inputs": {"runtime_marker": 41}},
    )
    assert result["value"] == 42
    editor_result = exec_ok(
        m6_runtime_eval_running,
        "editor/eval",
        {"source": "runtime_marker + 1", "inputs": {"runtime_marker": 41}},
    )
    assert editor_result["value"] == 42


def test_runtime_eval_disconnect_completes_once(m6_runtime_eval_running: dict[str, Any]) -> None:
    pending = start_async_exec(
        m6_runtime_eval_running,
        "runtime/eval",
        {"source": "runtime_marker + 1", "inputs": {"runtime_marker": 41}},
    )
    stop_game(m6_runtime_eval_running)
    assert pending.result(timeout=5)["code"] == "conflict"
    assert exec_ok(m6_runtime_eval_running, "runtime/status")["pending"] == 0
