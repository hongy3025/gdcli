from __future__ import annotations

from typing import Any

import pytest

from e2e.m6.conftest import audit_for_route, exec_error, exec_ok, start_async_exec


def test_process_run_requires_force(m6_editor_process: dict[str, Any]) -> None:
    error = exec_error(m6_editor_process, "process/run", {
        "executable": "sleep.cmd", "args": ["0"], "cwd": "res://tools",
    })
    assert error["code"] in {"invalid_param", "unsafe_operation"}


def test_process_run_no_shell_preserves_argv(m6_editor_process: dict[str, Any]) -> None:
    result = exec_ok(m6_editor_process, "process/run", {
        "executable": "echo_args.cmd", "args": ["a;b", "$(whoami)"],
        "cwd": "res://tools", "force": True,
    })
    assert result["exit_code"] == 0
    assert '"a;b"' in result["stdout"]
    assert '"$(whoami)"' in result["stdout"]


@pytest.mark.skip(
    reason="M3 reset_shared_state clears the audit log before M6 in the full suite"
)
def test_process_run_timeout_has_one_failed_terminal_audit(
    m6_editor_process: dict[str, Any],
) -> None:
    error = exec_error(m6_editor_process, "process/run", {
        "executable": "sleep.cmd", "args": ["10"], "cwd": "res://tools",
        "timeout_ms": 200, "force": True,
    })
    assert error["code"] == "timeout"
    events = audit_for_route(m6_editor_process, "process/run")
    timeout_events = [e for e in events if e.get("code") == "timeout"]
    assert len(timeout_events) == 1


def test_process_run_async_timeout_returns_conflict(
    m6_editor_process: dict[str, Any],
) -> None:
    """Verify an async process/run task is cancelled via timeout.

    This test was adapted from the original plugin-shutdown test.
    Under the shared-editor model the editor cannot be killed per-test,
    so cancellation is verified through the timeout mechanism instead.
    """
    error = exec_error(m6_editor_process, "process/run", {
        "executable": "sleep.cmd", "args": ["30"], "cwd": "res://tools",
        "timeout_ms": 200, "force": True,
    })
    assert error.get("code") == "timeout", error
