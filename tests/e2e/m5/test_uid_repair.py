from pathlib import Path

from .conftest import exec_error, exec_ok


def _uid_sidecar_digests(project_dir):
    import hashlib
    return {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(project_dir.rglob("*.uid"))
    }


def test_uid_repair_rolls_back_when_a_write_fails(m5_editor):
    """目标资源不可写时必须报错，并把已写入的 UID 回滚（无部分状态）。

    构造方式：先用 uid/repair 给两个副本各自写入 UID（missing → 写入），
    再把其中一个的 UID 复制成第三个文件（冲突，且 old_uid 非空可还原），
    最后把它设为只读，使 apply 在写入第二个目标时失败。
    """
    import os
    from pathlib import Path

    work = Path(m5_editor["project"]) / "fixtures" / "uid_collision"
    work.mkdir(parents=True, exist_ok=True)
    (work / "a.tres").write_text(
        '[gd_resource type="Resource" format=3]\n\n[resource]\n', encoding="utf-8"
    )
    (work / "b.tres").write_text(
        '[gd_resource type="Resource" format=3]\n\n[resource]\n', encoding="utf-8"
    )
    exec_ok(m5_editor, "uid/repair", {
        "roots": ["res://fixtures/uid_collision"], "dry_run": False,
    })
    for source_name, target_name in (("a.tres", "c.tres"), ("b.tres", "d.tres")):
        for suffix in ("", ".uid"):
            source = work / (source_name + suffix)
            if source.exists():
                (work / (target_name + suffix)).write_bytes(source.read_bytes())

    before = exec_ok(m5_editor, "uid/repair", {
        "roots": ["res://fixtures/uid_collision"], "dry_run": True,
    })
    assert len(before["changes"]) == 2, before
    assert all(change["status"] == "collision" for change in before["changes"]), before
    assert all(change["old_uid"] for change in before["changes"]), before
    assert [change["path"] for change in before["changes"]] == [
        "res://fixtures/uid_collision/c.tres",
        "res://fixtures/uid_collision/d.tres",
    ], before

    blocked = work / "d.tres"
    mode = blocked.stat().st_mode
    blocked.chmod(mode & ~0o222)
    assert not os.access(blocked, os.W_OK), "前置条件：d.tres 必须不可写"
    try:
        error = exec_error(m5_editor, "uid/repair", {
            "roots": ["res://fixtures/uid_collision"], "dry_run": False,
        })
        assert error["code"] == "godot_error", error
        details = error["details"]
        assert details["failed_path"].endswith("d.tres"), details
        assert details["applied"] == 1, details
        assert details["rollback_failures"] == [], details

        after = exec_ok(m5_editor, "uid/repair", {
            "roots": ["res://fixtures/uid_collision"], "dry_run": True,
        })

        def _state(plan):
            # new_uid 每次规划都会重新生成，比较状态字段（path/old_uid/status）
            return [
                {"path": c["path"], "old_uid": c["old_uid"], "status": c["status"]}
                for c in plan["changes"]
            ]

        assert _state(after) == _state(before), (after, before)
    finally:
        blocked.chmod(mode)


def test_uid_repair_dry_run_writes_nothing(m5_editor):
    """dry_run 不能写任何文件：既不创建 .uid，也不修改既有 .uid。"""
    fixtures = Path(m5_editor["project"]) / "fixtures"
    before = _uid_sidecar_digests(Path(m5_editor["project"]))
    plan = exec_ok(m5_editor, "uid/repair", {"roots": ["res://fixtures"], "dry_run": True})
    assert plan["changed"] is False
    assert _uid_sidecar_digests(Path(m5_editor["project"])) == before
    assert fixtures.is_dir()


def test_uid_repair_dry_run_apply_is_idempotent(m5_editor):
    body = {"roots": ["res://fixtures"], "dry_run": True}
    dry_run = exec_ok(m5_editor, "uid/repair", body)
    assert dry_run["changes"]
    assert dry_run["changed"] is False

    applied = exec_ok(m5_editor, "uid/repair", {
        "roots": ["res://fixtures"], "dry_run": False,
    })
    assert applied["changed"] is True
    second = exec_ok(m5_editor, "uid/repair", body)
    assert second["changes"] == []
    assert second["changed"] is False
