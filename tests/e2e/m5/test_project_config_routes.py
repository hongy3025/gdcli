import os
from pathlib import Path

import pytest

from .conftest import (
    assert_snapshot_restored,
    exec_error,
    exec_ok,
    m5_editor,
    project_snapshot,
    restore_snapshot,
)


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


def test_input_map_and_autoload_are_persisted_to_project_file(m5_editor):
    """InputMap/Autoload 变更必须写进 project.godot，重载后才不会丢失。"""
    before = project_snapshot(m5_editor)
    exec_ok(m5_editor, "project/input_map/action/add", {"action": "m5_persist_action"})
    exec_ok(m5_editor, "project/autoload/add", {
        "name": "M5PersistAuto", "path": "res://fixtures/state.gd",
    })
    text = (Path(m5_editor["project"]) / "project.godot").read_text(encoding="utf-8")
    assert "m5_persist_action" in text, text
    assert "M5PersistAuto" in text, text
    restore_snapshot(m5_editor)
    assert_snapshot_restored(m5_editor, before)


def test_unwritable_project_file_fails_and_rolls_back(m5_editor, read_only_project_file):
    """project.godot 不可写时：必须报错、回滚内存状态、文件保持不变。

    Godot 在编辑器上下文里会返回 OK 却什么都没写（临时文件 rename 失败被吞），
    因此路由需要自己校验落盘结果，这条用例正是覆盖该路径。
    """
    project_godot = Path(m5_editor["project"]) / "project.godot"
    assert not os.access(project_godot, os.W_OK), "前置条件：project.godot 必须不可写"
    before = project_snapshot(m5_editor)
    before_bytes = project_godot.read_bytes()

    error = exec_error(m5_editor, "project/settings/set", {
        "name": "application/config/m5_rollback_value", "value": 3,
    })
    assert error["code"] == "godot_error", error
    settings = exec_ok(m5_editor, "project/settings/list", {
        "filter": "application/config/m5_rollback_value",
    })
    assert "application/config/m5_rollback_value" not in settings["items"], settings

    error = exec_error(m5_editor, "project/input_map/action/add", {
        "action": "m5_rollback_action",
    })
    assert error["code"] == "godot_error", error
    actions = exec_ok(m5_editor, "project/input_map/list", {"filter": "m5_rollback_action"})
    assert all(item["action"] != "m5_rollback_action" for item in actions["items"]), actions

    error = exec_error(m5_editor, "project/autoload/add", {
        "name": "M5RollbackAuto", "path": "res://fixtures/state.gd",
    })
    assert error["code"] == "godot_error", error
    autoloads = exec_ok(m5_editor, "project/autoload/list", {})["autoloads"]
    assert all(item["name"] != "M5RollbackAuto" for item in autoloads), autoloads

    assert project_godot.read_bytes() == before_bytes
    assert_snapshot_restored(m5_editor, before)


@pytest.fixture()
def input_action(m5_editor):
    """创建 InputMap 动作，并在用例结束后从共享编辑器移除。

    `m5_editor` 只恢复项目文件基线，共享编辑器的运行时 InputMap 不会随之回滚，
    因此每个用例必须清理自己创建的动作，否则下一个用例会命中 "action already exists"。
    """
    created: list[str] = []

    def _create(name: str, **body) -> None:
        exec_ok(m5_editor, "project/input_map/action/add", {"action": name, **body})
        created.append(name)

    yield _create
    for name in reversed(created):
        exec_ok(m5_editor, "project/input_map/action/remove", {"action": name})


@pytest.mark.parametrize(("route", "keycode", "keys"), [
    ("project/input_map/unbind", 90, []),
    ("project/input_map/unbind", 90, [65, 66, 67]),
    ("project/input_map/unbind", 66, [65, 66, 67]),
    ("project/input_map/bind", 66, [65, 66, 67]),
    ("project/input_map/bind", 90, [65, 66, 67]),
    ("project/input_map/action/remove", None, [65, 66, 67]),
])
def test_input_map_save_failure_restores_exact_action_and_setting(
    m5_editor, input_action, route, keycode, keys,
):
    action = "m5_exact_input_rollback"
    input_action(action, deadzone=0.37)
    for key in keys:
        exec_ok(m5_editor, "project/input_map/bind", {
            "action": action, "event": {"type": "InputEventKey", "keycode": key},
        })
    # A persisted setting is independent of the current InputMap. Rollback must
    # not synthesize it from the runtime action (or drop extra setting fields).
    exec_ok(m5_editor, "project/settings/set", {
        "name": "input/" + action,
        "value": {"deadzone": 0.91, "events": [], "integrity_marker": "preserve"},
    })
    before_action = exec_ok(m5_editor, "project/input_map/list", {"filter": action})["items"]
    before_setting = exec_ok(m5_editor, "project/settings/get", {"name": "input/" + action})
    assert before_action[0]["deadzone"] == pytest.approx(0.37)
    assert [event["keycode"] for event in before_action[0]["events"]] == keys
    project_file = Path(m5_editor["project"]) / "project.godot"
    before_bytes = project_file.read_bytes()
    mode = project_file.stat().st_mode
    project_file.chmod(mode & ~0o222)
    try:
        body = {"action": action}
        if keycode is not None:
            body["event"] = {"type": "InputEventKey", "keycode": keycode}
        error = exec_error(m5_editor, route, body)
        assert error["code"] == "godot_error", error
        assert exec_ok(
            m5_editor, "project/input_map/list", {"filter": action}
        )["items"] == before_action
        assert exec_ok(
            m5_editor, "project/settings/get", {"name": "input/" + action}
        ) == before_setting
        assert project_file.read_bytes() == before_bytes
    finally:
        project_file.chmod(mode)


def test_input_map_bind_failure_restores_absent_project_setting(m5_editor, input_action):
    action = "m5_runtime_only_rollback"
    input_action(action, deadzone=0.42)
    exec_ok(m5_editor, "project/settings/reset", {"name": "input/" + action})
    before_action = exec_ok(m5_editor, "project/input_map/list", {"filter": action})["items"]
    assert before_action[0]["events"] == []
    project_file = Path(m5_editor["project"]) / "project.godot"
    before_bytes = project_file.read_bytes()
    mode = project_file.stat().st_mode
    project_file.chmod(mode & ~0o222)
    try:
        error = exec_error(m5_editor, "project/input_map/bind", {
            "action": action, "event": {"type": "InputEventKey", "keycode": 65},
        })
        assert error["code"] == "godot_error", error
        assert exec_ok(
            m5_editor, "project/input_map/list", {"filter": action}
        )["items"] == before_action
        assert exec_error(
            m5_editor, "project/settings/get", {"name": "input/" + action}
        )["code"] == "not_found"
        assert project_file.read_bytes() == before_bytes
    finally:
        project_file.chmod(mode)
