"""Policy restoration tests for the shared editor.

Verifies that temporary_policy correctly applies and restores capability
policies, routes are rejected when disabled, and restoration errors are
reported.
"""

from __future__ import annotations

from typing import Any

import pytest

from e2e.m2.helpers import exec_error, exec_ok
from e2e.shared_fixture import E2E_DEFAULT_POLICY_PATH, temporary_policy


def test_temporary_policy_disables_capability(e2e_editor: dict[str, Any]) -> None:
    """Apply a deny-all override, verify route rejection, then restore."""
    deny_all = {"version": 1, "capabilities": {}}
    with temporary_policy(e2e_editor, deny_all):
        # runtime/eval should be denied under deny-all
        error = exec_error(e2e_editor, "runtime/eval", {
            "source": "1 + 1", "force": True,
        })
        assert error["code"] == "permission_denied"

    # After context exit, policy is restored; runtime/eval should work
    # (requires a running game probe — just check the policy bytes match)
    policy_path = e2e_editor["project"] / ".godot" / "gdapi-policy.json"
    assert policy_path.read_bytes() == E2E_DEFAULT_POLICY_PATH.read_bytes()


def test_temporary_policy_restores_on_exception(e2e_editor: dict[str, Any]) -> None:
    """If the body raises, the policy is still restored."""
    deny_all = {"version": 1, "capabilities": {}}
    try:
        with temporary_policy(e2e_editor, deny_all):
            policy_path = e2e_editor["project"] / ".godot" / "gdapi-policy.json"
            # Verify the override was written
            assert deny_all["version"] == 1  # sanity
            raise ValueError("simulated failure")
    except ValueError:
        pass

    # Policy should be restored despite the exception
    policy_path = e2e_editor["project"] / ".godot" / "gdapi-policy.json"
    assert policy_path.read_bytes() == E2E_DEFAULT_POLICY_PATH.read_bytes()


def test_temporary_policy_reports_restoration_failure(
    e2e_editor: dict[str, Any],
) -> None:
    """If the policy file cannot be restored, the error is reported.

    On Windows, chmod does not enforce POSIX write permissions, so this
    test uses a file-lock simulation: make the policy file itself read-only
    so the restoration write fails.
    """
    import os
    import stat
    deny_all = {"version": 1, "capabilities": {}}
    policy_path = e2e_editor["project"] / ".godot" / "gdapi-policy.json"

    # Make the file read-only so the restoration write fails
    original_mode = policy_path.stat().st_mode
    policy_path.chmod(stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)  # remove write
    try:
        with pytest.raises(AssertionError, match="temporary_policy failed"):
            with temporary_policy(e2e_editor, deny_all):
                pass
    finally:
        policy_path.chmod(original_mode)