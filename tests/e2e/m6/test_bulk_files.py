from __future__ import annotations

import os
import shutil
import subprocess
from uuid import uuid4

import pytest

from .conftest import (
    _exec_raw,
    apply_delete,
    apply_replace,
    clear_recover_failure,
    delete_plan,
    exec_error,
    exec_ok,
    inject_apply_failure,
    inject_recover_failure,
    project_file,
    replace_plan,
)


@pytest.fixture()
def bulk_workspace(m6_editor_bulk):
    """Own these files for one batch scenario; never restore the project tree."""
    relative = "bulk_cases/" + uuid4().hex
    directory = project_file(m6_editor_bulk, relative)
    directory.mkdir(parents=True)
    for name, uid in (("a.txt", "uid://b5hwk3lr43xsd"), ("b.txt", "uid://ccyplk273e5wf")):
        (directory / name).write_bytes(b"old-text\n")
        (directory / (name + ".uid")).write_text(uid + "\n", encoding="utf-8")
    try:
        yield directory, "res://" + relative
    finally:
        shutil.rmtree(directory)


def current_bytes(directory):
    return {path.name: path.read_bytes() for path in directory.iterdir() if path.is_file()}


def test_replace_dry_run_then_apply(m6_editor_bulk, bulk_workspace):
    directory, root = bulk_workspace
    before = current_bytes(directory)
    plan = replace_plan(m6_editor_bulk, root=root, find="old-text", replace="new-text")
    assert plan["ok"] and plan["operations"], plan
    assert current_bytes(directory) == before, "planning must not change bytes"
    result = apply_replace(m6_editor_bulk, plan)
    assert result["ok"], result
    assert (directory / "a.txt").read_bytes() == before["a.txt"].replace(b"old-text", b"new-text")
    assert (directory / "b.txt").read_bytes() == before["b.txt"].replace(b"old-text", b"new-text")


def test_replace_rolls_back_when_second_apply_fails(m6_editor_bulk, bulk_workspace):
    directory, root = bulk_workspace
    plan = replace_plan(m6_editor_bulk, root=root, find="old-text", replace="new-text")
    inject_apply_failure(m6_editor_bulk, fail_after=1)
    before = current_bytes(directory)
    try:
        error = apply_replace(m6_editor_bulk, plan)
        assert error["code"] == "godot_error", error
        assert current_bytes(directory) == before
    finally:
        project_file(m6_editor_bulk, ".gdapi-debug-apply-fail").unlink(missing_ok=True)


def test_stale_plan_returns_conflict(m6_editor_bulk, bulk_workspace):
    directory, root = bulk_workspace
    plan = replace_plan(m6_editor_bulk, root=root, find="old-text", replace="new-text")
    (directory / "a.txt").write_text("external edit", encoding="utf-8")
    before = current_bytes(directory)
    error = apply_replace(m6_editor_bulk, plan)
    assert error["code"] == "conflict", error
    assert current_bytes(directory) == before


def test_delete_recover_restores_uid_and_is_not_repeatable(m6_editor_bulk, bulk_workspace):
    directory, root = bulk_workspace
    before = current_bytes(directory)
    plan = delete_plan(m6_editor_bulk, [root + "/a.txt"])
    assert current_bytes(directory) == before
    deleted = apply_delete(m6_editor_bulk, plan)
    assert deleted["ok"], deleted
    assert not (directory / "a.txt").exists()
    assert not (directory / "a.txt.uid").exists()
    assert (directory / "b.txt").read_bytes() == before["b.txt"]
    assert (directory / "b.txt.uid").read_bytes() == before["b.txt.uid"]
    exec_ok(m6_editor_bulk, "filesystem/batch/recover", {
        "operation_id": deleted["operation_id"],
    })
    assert current_bytes(directory) == before
    error = exec_error(m6_editor_bulk, "filesystem/batch/recover", {
        "operation_id": deleted["operation_id"],
    })
    assert error["code"] == "conflict", error
    assert current_bytes(directory) == before


def test_replace_plan_hash_binds_find_and_replace(m6_editor_bulk, bulk_workspace):
    directory, root = bulk_workspace
    before = current_bytes(directory)
    first = replace_plan(m6_editor_bulk, root=root, find="old-text", replace="AAA")
    second = replace_plan(m6_editor_bulk, root=root, find="old-text", replace="BBB")
    assert first["operations"] == second["operations"]
    assert first["operations"], first
    assert first["plan_hash"] != second["plan_hash"]
    error = _exec_raw(m6_editor_bulk, "filesystem/batch/replace", {
        "root": root, "find": "old-text", "replace": "BBB",
        "plan_hash": first["plan_hash"],
    })
    assert error["code"] == "conflict", error
    assert current_bytes(directory) == before


def test_replace_rejects_protected_paths(m6_editor_bulk):
    plugin = project_file(m6_editor_bulk, "addons/gdapi/plugin.gd")
    before = plugin.read_bytes()
    error = exec_error(m6_editor_bulk, "filesystem/batch/replace", {
        "root": "res://addons/gdapi", "find": "gdapi", "replace": "x",
        "dry_run": True,
    })
    assert error["code"] == "permission_denied", error
    for protected in ("res://addons/gdapi/plugin.gd", "res://./addons/gdapi/plugin.gd"):
        error = exec_error(m6_editor_bulk, "filesystem/batch/delete", {
            "paths": [protected], "dry_run": True,
        })
        assert error["code"] == "permission_denied", error
    assert plugin.read_bytes() == before


def test_replace_rejects_windows_junction_outside_project(m6_editor_bulk, bulk_workspace, tmp_path):
    if os.name != "nt":
        pytest.skip("Windows junctions are only supported on Windows")
    directory, root = bulk_workspace
    junction = directory / "junction-boundary"
    original = directory / "junction-original"
    external = tmp_path / "external"
    external.mkdir()
    external_file = external / "outside.txt"
    external_file.write_text("old", encoding="utf-8")
    junction.mkdir()
    (junction / "inside.txt").write_text("old", encoding="utf-8")
    planned = replace_plan(m6_editor_bulk, root=root + "/junction-boundary", find="old", replace="new")
    junction.rename(original)
    created = subprocess.run(
        ["cmd", "/c", "mklink", "/J", str(junction), str(external)],
        capture_output=True, text=True, check=False,
    )
    if created.returncode != 0:
        original.rename(junction)
        pytest.skip(f"junction creation is unsupported: {created.stderr}")
    try:
        for dry_run in (True, False):
            error = exec_error(m6_editor_bulk, "filesystem/batch/replace", {
                "root": root + "/junction-boundary", "find": "old", "replace": "new",
                "dry_run": dry_run, "plan_hash": planned["plan_hash"],
            })
            assert error["code"] == "permission_denied", error
            assert external_file.read_text(encoding="utf-8") == "old"
            assert (original / "inside.txt").read_text(encoding="utf-8") == "old"
    finally:
        os.rmdir(junction)
        original.rename(junction)


def test_recover_failure_leaves_no_partial_state(m6_editor_bulk, bulk_workspace):
    directory, root = bulk_workspace
    before = current_bytes(directory)
    plan = delete_plan(m6_editor_bulk, [root + "/a.txt", root + "/b.txt"])
    deleted = apply_delete(m6_editor_bulk, plan)
    assert deleted["ok"], deleted
    assert current_bytes(directory) == {}
    try:
        inject_recover_failure(m6_editor_bulk, fail_after=1)
        error = exec_error(m6_editor_bulk, "filesystem/batch/recover", {
            "operation_id": deleted["operation_id"],
        })
        assert error["code"] == "godot_error", error
        assert error["details"]["rollback_failures"] == [], error
        assert current_bytes(directory) == {}, "partial recovery must roll back files and UID sidecars"
    finally:
        clear_recover_failure(m6_editor_bulk)
        exec_ok(m6_editor_bulk, "filesystem/batch/recover", {"operation_id": deleted["operation_id"]})
    assert current_bytes(directory) == before
