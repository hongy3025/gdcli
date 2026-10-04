from pathlib import Path

import pytest

from .conftest import exec_error, exec_ok


def _uid_sidecar_digests(project_dir):
    import hashlib
    return {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(project_dir.rglob("*.uid"))
    }


def test_uid_repair_preflights_all_targets_before_writing(m5_editor):
    """A late read-only collision must reject the whole batch before any UID writes."""
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
    before_bytes = {path.name: path.read_bytes() for path in work.iterdir() if path.is_file()}
    try:
        error = exec_error(m5_editor, "uid/repair", {
            "roots": ["res://fixtures/uid_collision"], "dry_run": False,
        })
        assert error["code"] == "permission_denied", error
        details = error["details"]
        assert details["failed_path"].endswith("d.tres"), details
        assert details["applied"] == 0, details
        assert {
            path.name: path.read_bytes() for path in work.iterdir() if path.is_file()
        } == before_bytes

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


@pytest.mark.parametrize("root", [
    "res://addons/gdapi", "res://addons/gdapi/",
    "res://addons/gdapi/runtime", "res://addons/gdapi/runtime/protected.tres",
    "res://.godot", "res://.godot/",
])
@pytest.mark.parametrize("dry_run", [True, False])
def test_uid_repair_rejects_protected_roots_atomically(m5_editor, root, dry_run):
    project = Path(m5_editor["project"])
    work = project / "fixtures" / "uid_protected_batch"
    work.mkdir(parents=True, exist_ok=True)
    target = work / "missing.tres"
    target.write_text('[gd_resource type="Resource" format=3]\n\n[resource]\n', encoding="utf-8")
    before = {path.name: path.read_bytes() for path in work.iterdir()}
    error = exec_error(m5_editor, "uid/repair", {
        "roots": ["res://fixtures/uid_protected_batch", root], "dry_run": dry_run,
    })
    assert error["code"] == "permission_denied", error
    assert {path.name: path.read_bytes() for path in work.iterdir()} == before


def test_uid_repair_broad_scan_skips_protected_files_and_deduplicates_roots(m5_editor):
    project = Path(m5_editor["project"])
    protected = project / "addons" / "gdapi" / "uid_protected.tres"
    protected.write_text('[gd_resource type="Resource" format=3]\n\n[resource]\n', encoding="utf-8")
    protected_before = protected.read_bytes()
    try:
        single = exec_ok(m5_editor, "uid/repair", {"roots": ["res://"], "dry_run": True})
        repeated = exec_ok(m5_editor, "uid/repair", {
            "roots": ["res://fixtures", "res://", "res://fixtures/", "res://"],
            "dry_run": True,
        })
        assert repeated["scanned"] == single["scanned"]
        fields = lambda plan: [
            (item["path"], item["old_uid"], item["status"]) for item in plan["changes"]
        ]
        assert fields(repeated) == fields(single)
        assert all(
            not item["path"].startswith(("res://addons/gdapi/", "res://.godot/"))
            for item in repeated["changes"]
        )
        exec_ok(m5_editor, "uid/repair", {"roots": ["res://"], "dry_run": False})
        assert protected.read_bytes() == protected_before
        assert not protected.with_suffix(".tres.uid").exists()
    finally:
        protected.unlink(missing_ok=True)
        protected.with_suffix(".tres.uid").unlink(missing_ok=True)


def test_uid_repair_read_only_missing_uid_does_not_partially_create_uids(m5_editor):
    work = Path(m5_editor["project"]) / "fixtures" / "uid_missing_preflight"
    work.mkdir(parents=True, exist_ok=True)
    for name in ("a.tres", "z.tres"):
        (work / name).write_text(
            '[gd_resource type="Resource" format=3]\n\n[resource]\n', encoding="utf-8"
        )
    blocked = work / "z.tres"
    mode = blocked.stat().st_mode
    blocked.chmod(mode & ~0o222)
    before = {path.name: path.read_bytes() for path in work.iterdir()}
    try:
        error = exec_error(m5_editor, "uid/repair", {
            "roots": ["res://fixtures/uid_missing_preflight"], "dry_run": False,
        })
        assert error["code"] == "permission_denied", error
        assert {path.name: path.read_bytes() for path in work.iterdir()} == before
    finally:
        blocked.chmod(mode)
