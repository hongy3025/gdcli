from .conftest import assert_snapshot_restored, exec_ok, m5_editor, project_snapshot, restore_snapshot


def test_project_config_round_trip_restores_snapshot(m5_editor):
    before = project_snapshot(m5_editor)
    exec_ok(m5_editor, "project/settings/set", {
        "name": "application/config/m5_test_value", "value": 42,
    })
    exec_ok(m5_editor, "project/input_map/action/add", {"action": "audit_jump"})
    exec_ok(m5_editor, "project/autoload/add", {
        "name": "AuditAuto", "path": "res://fixtures/state.gd",
    })
    assert exec_ok(m5_editor, "project/settings/get", {
        "name": "application/config/m5_test_value",
    })["value"] == 42
    assert any(item["action"] == "audit_jump" for item in exec_ok(
        m5_editor, "project/input_map/list", {}
    )["items"])
    assert any(item["name"] == "AuditAuto" for item in exec_ok(
        m5_editor, "project/autoload/list", {}
    )["autoloads"])
    restore_snapshot(m5_editor)
    assert_snapshot_restored(m5_editor, before)
