from __future__ import annotations

from .conftest import (
    _exec_raw,
    apply_delete,
    apply_replace,
    bulk_digest,
    clear_recover_failure,
    delete_plan,
    exec_error,
    exec_ok,
    inject_apply_failure,
    inject_recover_failure,
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


def test_replace_plan_hash_binds_find_and_replace(m6_editor_bulk):
    """同一批文件、不同替换文本必须得到不同 hash，且旧 hash 不能驱动新替换。"""
    first = replace_plan(m6_editor_bulk, root="res://bulk", find="old-text", replace="AAA")
    second = replace_plan(m6_editor_bulk, root="res://bulk", find="old-text", replace="BBB")
    assert first["operations"] == second["operations"], "两次计划针对同一批文件"
    assert first["plan_hash"] != second["plan_hash"], "plan_hash 必须绑定 find/replace"

    error = _exec_raw(m6_editor_bulk, "filesystem/batch/replace", {
        "root": "res://bulk", "find": "old-text", "replace": "BBB",
        "plan_hash": first["plan_hash"],
    })
    assert error["code"] == "conflict", error


def test_replace_rejects_protected_paths(m6_editor_bulk):
    error = exec_error(m6_editor_bulk, "filesystem/batch/replace", {
        "root": "res://addons/gdapi", "find": "gdapi", "replace": "x",
        "dry_run": True,
    })
    assert error["code"] == "permission_denied", error


def test_recover_failure_leaves_no_partial_state(m6_editor_bulk):
    plan = delete_plan(m6_editor_bulk, ["res://bulk/a.txt", "res://bulk/b.txt"])
    deleted = apply_delete(m6_editor_bulk, plan)
    assert deleted["ok"], deleted
    assert not project_file(m6_editor_bulk, "bulk/a.txt").exists()
    assert not project_file(m6_editor_bulk, "bulk/b.txt").exists()
    try:
        inject_recover_failure(m6_editor_bulk, fail_after=1)
        error = exec_error(m6_editor_bulk, "filesystem/batch/recover", {
            "operation_id": deleted["operation_id"],
        })
        assert error["code"] == "godot_error", error
        assert error["details"]["rollback_failures"] == [], error
        assert not project_file(m6_editor_bulk, "bulk/a.txt").exists(), "部分恢复必须回滚"
        assert not project_file(m6_editor_bulk, "bulk/b.txt").exists()
    finally:
        clear_recover_failure(m6_editor_bulk)
