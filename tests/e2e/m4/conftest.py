"""M4 E2E fixtures — session-scoped alias of the shared e2e_editor and
per-test project snapshot/reset.

The single Godot editor and unified project live in `tests/e2e/shared_fixture.py`,
re-exported through the root `tests/e2e/conftest.py` as `m4_env` and friends.
This module only re-exports `exec_ok` / `exec_error` / `command_doc` for
backward compatibility and provides the per-test isolation hook.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

import pytest

from e2e.m3.conftest import command_doc, exec_error, exec_ok  # noqa: F401
from e2e.shared_fixture import is_tracked_project_file  # noqa: F401 — re-export
from e2e.shared_fixture import m4_env  # noqa: F401 — re-export
from e2e.shared_fixture import reset_shared_state, restore_file_state


def project_files(project: Path) -> dict[str, str]:
    """Tracked project files → sha256 hex, excluding generated/installed state."""
    files: dict[str, str] = {}
    for path in sorted(project.rglob("*")):
        if not path.is_file():
            continue
        rel = str(path.relative_to(project)).replace("\\", "/")
        if not is_tracked_project_file(rel):
            continue
        files[rel] = hashlib.sha256(path.read_bytes()).hexdigest()
    return files


def project_snapshot(project: Path) -> str:
    digest = hashlib.sha256()
    for rel, file_digest in project_files(project).items():
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        digest.update(file_digest.encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def describe_project_diff(before: dict[str, str], after: dict[str, str]) -> str:
    added = sorted(set(after) - set(before))
    removed = sorted(set(before) - set(after))
    changed = sorted(rel for rel in set(before) & set(after) if before[rel] != after[rel])
    return f"added={added} removed={removed} changed={changed}"


def reset_project_state(env: dict[str, Any]) -> None:
    """Restore the file baseline and runtime state captured at fixture setup."""
    baseline = env.get("file_baseline")
    if baseline is not None:
        restore_file_state(env, baseline)
    reset_shared_state(env, reason="m4 autouse")


@pytest.fixture(autouse=True)
def isolated_test_state(m4_env):
    project = Path(m4_env["project"])
    before = project_files(project)
    yield
    reset_project_state(m4_env)
    after = project_files(project)
    assert after == before, (
        "M4 project state changed after test: " + describe_project_diff(before, after)
    )


__all__ = [
    "command_doc",
    "exec_error",
    "exec_ok",
    "m4_env",
    "project_snapshot",
    "reset_project_state",
]
