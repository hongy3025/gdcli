from __future__ import annotations

from .conftest import (
    apply_delete,
    apply_replace,
    bulk_digest,
    delete_plan,
    exec_error,
    exec_ok,
    inject_apply_failure,
    m6_editor_bulk,
    project_file,
    replace_plan,
)


def test_replace_dry_run_then_apply(m6_editor_bulk):
    plan = replace_plan(m6_editor_bulk, root="res://bulk", find="old-text", replace="new-text")
    assert plan["ok"]
    digest = bulk_digest(m6_editor_bulk)
    result = apply_replace(m6_editor_bulk, plan)
    assert result["ok"]
    assert bulk_digest(m6_editor_bulk) != digest
    undo_plan = replace_plan(m6_editor_bulk, root="res://bulk", find="new-text", replace="old-text")
    apply_replace(m6_editor_bulk, undo_plan)


def test_replace_rolls_back_when_second_apply_fails(m6_editor_bulk):
    plan = replace_plan(m6_editor_bulk, root="res://bulk", find="old-text", replace="new-text")
    inject_apply_failure(m6_editor_bulk, fail_after=1)
    before = bulk_digest(m6_editor_bulk)
    error = apply_replace(m6_editor_bulk, plan)
    assert error["code"] == "godot_error"
    assert bulk_digest(m6_editor_bulk) == before


def test_stale_plan_returns_conflict(m6_editor_bulk):
    plan = replace_plan(m6_editor_bulk, root="res://bulk", find="old-text", replace="new-text")
    project_file(m6_editor_bulk, "bulk/a.txt").write_text("external edit")
    error = apply_replace(m6_editor_bulk, plan)
    assert error["code"] == "conflict"


def test_delete_recover_restores_uid_and_is_not_repeatable(m6_editor_bulk):
    plan = delete_plan(m6_editor_bulk, ["res://bulk/a.txt"])
    deleted = apply_delete(m6_editor_bulk, plan)
    assert deleted["ok"]
    assert not project_file(m6_editor_bulk, "bulk/a.txt").exists()
    exec_ok(m6_editor_bulk, "filesystem/batch/recover", {
        "operation_id": deleted["operation_id"],
    })
    assert project_file(m6_editor_bulk, "bulk/a.txt").exists()
    error = exec_error(m6_editor_bulk, "filesystem/batch/recover", {
        "operation_id": deleted["operation_id"],
    })
    assert error["code"] == "conflict"
