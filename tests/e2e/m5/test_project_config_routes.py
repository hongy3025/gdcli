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


def test_project_config_removals_succeed_without_force(m5_editor):
    before = project_snapshot(m5_editor)
    exec_ok(m5_editor, "project/settings/set", {
        "name": "application/config/m5_remove_value", "value": 7,
    })
    exec_ok(m5_editor, "project/settings/reset", {
        "name": "application/config/m5_remove_value",
    })
    exec_ok(m5_editor, "project/input_map/action/add", {"action": "m5_remove_action"})
    event = {"type": "InputEventKey", "keycode": 65}
    exec_ok(m5_editor, "project/input_map/bind", {
        "action": "m5_remove_action", "event": event,
    })
    exec_ok(m5_editor, "project/input_map/unbind", {
        "action": "m5_remove_action", "event": event,
    })
    exec_ok(m5_editor, "project/input_map/action/remove", {"action": "m5_remove_action"})
    exec_ok(m5_editor, "project/autoload/add", {
        "name": "M5RemoveAuto", "path": "res://fixtures/state.gd",
    })
    exec_ok(m5_editor, "project/autoload/remove", {"name": "M5RemoveAuto"})
    settings = exec_ok(m5_editor, "project/settings/list", {
        "filter": "application/config/m5_remove_value",
    })
    assert "application/config/m5_remove_value" not in settings["items"]
    actions = exec_ok(m5_editor, "project/input_map/list", {"filter": "m5_remove_action"})
    assert all(item["action"] != "m5_remove_action" for item in actions["items"])
    autoloads = exec_ok(m5_editor, "project/autoload/list", {})
    assert all(item["name"] != "M5RemoveAuto" for item in autoloads["autoloads"])
    restore_snapshot(m5_editor)
    assert_snapshot_restored(m5_editor, before)
