"""A real CLI-created resource must survive the entire persistent editor workload."""
from __future__ import annotations

import uuid

import pytest

from e2e.shared_fixture import gdcli_call


@pytest.mark.e2e
def test_live_project_state_survives_subsequent_cases(e2e_editor):
    token = uuid.uuid4().hex
    path = f"res://persistent_session_{token}.txt"
    content = f"written through gdcli in the persistent session: {token}\n"
    gdcli_call(e2e_editor, "filesystem/write", {"path": path, "content": content})
    assert gdcli_call(e2e_editor, "filesystem/read", {"path": path})["content"] == content
    # The session fixture reads this same resource after every remaining case.
    # A whole-project rollback, unlike scenario-owned cleanup, destroys it.
    e2e_editor["persistent_session_marker"] = {"path": path, "content": content}
