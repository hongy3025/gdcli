from pathlib import Path

from .conftest import exec_ok


def _uid_sidecar_digests(project_dir):
    import hashlib
    return {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(project_dir.rglob("*.uid"))
    }


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
