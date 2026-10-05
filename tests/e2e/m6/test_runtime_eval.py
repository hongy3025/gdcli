"""E2E tests for runtime/eval across v1/v2 boundaries."""

from __future__ import annotations

from typing import Any


from e2e.m3.conftest import detach_game, wait_for
from .conftest import audit_cursor, exec_error, exec_ok, latest_audit, start_async_exec


def test_runtime_eval_requires_running_probe(m6_editor_eval: dict[str, Any]) -> None:
    detach_game(m6_editor_eval)
    since = audit_cursor(m6_editor_eval, "runtime/eval")
    error = exec_error(m6_editor_eval, "runtime/eval", {"source": "1 + 1"})
    assert error["code"] == "conflict"
    # Mutations are audited under the public route name, even on failure
    entry = latest_audit(m6_editor_eval, "runtime/eval", since=since)
    assert entry["route"] == "runtime/eval"
    assert entry["ok"] is False
    assert entry["code"] == "conflict"


def test_runtime_eval_runs_only_in_game_process(m3_running: dict[str, Any]) -> None:
    result = exec_ok(
        m3_running,
        "runtime/eval",
        {"source": "runtime_marker + 1", "inputs": {"runtime_marker": 41}},
    )
    assert result["value"] == 42
    editor_result = exec_ok(
        m3_running,
        "editor/eval",
        {"source": "runtime_marker + 1", "inputs": {"runtime_marker": 41}},
    )
    assert editor_result["value"] == 42


def test_runtime_eval_disconnect_completes_once(m3_running: dict[str, Any]) -> None:
    # Keep the actual game main thread busy so the eval is genuinely pending
    # before stopping its process; a fast expression alone races its own reply.
    blocker = start_async_exec(m3_running, "runtime/node/call", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
        "method": "block_then_emit_finished", "args": [3000],
        "timeout_ms": 10000,
    })
    try:
        wait_for(lambda: exec_ok(m3_running, "runtime/status")["pending"] == 1)
        pending = start_async_exec(m3_running, "runtime/eval", {
            "source": "runtime_marker + 1", "inputs": {"runtime_marker": 41},
        })
        try:
            wait_for(lambda: exec_ok(m3_running, "runtime/status")["pending"] == 2)
            stop = detach_game(m3_running)
            assert pending.result(timeout=5)["code"] == "conflict"
            assert blocker.result(timeout=5)["code"] == "conflict"
            assert stop["pending"] == 0
        finally:
            pending._executor.shutdown(wait=True)
    finally:
        blocker._executor.shutdown(wait=True)
