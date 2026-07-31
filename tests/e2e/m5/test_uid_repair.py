from .conftest import exec_ok


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
