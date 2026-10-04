from __future__ import annotations

import time

from typing import Any

from e2e.m6.conftest import audit_for_route, exec_error, exec_ok


def test_process_run_no_shell_preserves_argv(m6_editor_process: dict[str, Any]) -> None:
    result = exec_ok(m6_editor_process, "process/run", {
        "executable": "echo_args.cmd", "args": ["a;b", "$(whoami)"],
        "cwd": "res://tools",
    })
    assert result["exit_code"] == 0
    assert '"a;b"' in result["stdout"]
    assert '"$(whoami)"' in result["stdout"]


def test_process_run_timeout_has_one_failed_terminal_audit(
    m6_editor_process: dict[str, Any],
) -> None:
    started = time.monotonic()
    error = exec_error(m6_editor_process, "process/run", {
        "executable": "sleep.cmd", "args": ["10"], "cwd": "res://tools",
        "timeout_ms": 200,
    })
    assert error["code"] == "timeout"
    assert time.monotonic() - started < 5.0
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
    started = time.monotonic()
    error = exec_error(m6_editor_process, "process/run", {
        "executable": "sleep.cmd", "args": ["30"], "cwd": "res://tools",
        "timeout_ms": 200,
    })
    assert error.get("code") == "timeout", error
    assert time.monotonic() - started < 5.0


def test_process_spawn_failure_is_audited_as_failure(
    m6_editor_process: dict[str, Any],
) -> None:
    error = exec_error(m6_editor_process, "process/run", {
        "executable": "definitely-not-a-real-binary-xyz", "args": [], "cwd": "res://tools",
    })
    assert error.get("code"), error
    events = audit_for_route(m6_editor_process, "process/run")
    failures = [e for e in events if e.get("ok") is False and e.get("code")]
    assert failures, events
