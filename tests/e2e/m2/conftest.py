"""M2 E2E fixtures — per-test project snapshot/reset on top of the shared editor.

The single Godot editor and unified project live in `tests/e2e/shared_fixture.py`,
re-exported through the root `tests/e2e/conftest.py` as `m2_editor` and friends.
This module only defines the autouse per-test isolation hook and M2-specific
reset helpers.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

import pytest

from e2e.shared_fixture import is_tracked_project_file, reset_shared_state, restore_file_state


def project_snapshot(project: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(project.rglob("*")):
        if not path.is_file():
            continue
        rel = str(path.relative_to(project)).replace("\\", "/")
        # Skip generated, addon-installed and engine-maintained files that
        # change without being a test artifact; the shared reset hook owns them.
        if not is_tracked_project_file(rel):
            continue
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def reset_project_state(env: dict[str, Any]) -> None:
    """Restore the file baseline and runtime state captured at fixture setup."""
    baseline = env.get("file_baseline")
    if baseline is not None:
        restore_file_state(env, baseline)
    reset_shared_state(env, reason="m2 autouse")


@pytest.fixture(autouse=True)
def isolated_test_state(m2_editor):
    before = project_snapshot(Path(m2_editor["project"]))
    yield
    reset_project_state(m2_editor)
    after = project_snapshot(Path(m2_editor["project"]))
    assert after == before, "M2 project state changed after test"


__all__ = [
    "project_snapshot",
    "reset_project_state",
]
