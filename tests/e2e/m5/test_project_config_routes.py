import os
import re
from pathlib import Path
from uuid import uuid4

import pytest

from .conftest import exec_error, exec_ok


@pytest.fixture()
def owned_setting(m5_editor):
    """Remember and undo only the settings explicitly claimed by this scenario."""
    prior = {}

    def claim(name):
        if name not in prior:
            names = exec_ok(m5_editor, "project/settings/list", {"filter": name})["items"]
            prior[name] = (
                name in names,
                exec_ok(m5_editor, "project/settings/get", {"name": name})["value"]
                if name in names else None,
            )
        return name

    yield claim
    for name, (exists, value) in reversed(list(prior.items())):
        if exists:
            exec_ok(m5_editor, "project/settings/set", {"name": name, "value": value})
        elif name in exec_ok(m5_editor, "project/settings/list", {"filter": name})["items"]:
            exec_ok(m5_editor, "project/settings/reset", {"name": name})


@pytest.fixture()
def owned_autoload(m5_editor):
    created = []

    def add(name):
        before = exec_ok(m5_editor, "project/autoload/list")["autoloads"]
        assert all(item["name"] != name for item in before)
        exec_ok(m5_editor, "project/autoload/add", {
            "name": name, "path": "res://fixtures/state.gd",
        })
        created.append(name)

    yield add
    for name in reversed(created):
        remaining = exec_ok(m5_editor, "project/autoload/list")["autoloads"]
        if any(item["name"] == name for item in remaining):
            exec_ok(m5_editor, "project/autoload/remove", {"name": name})


def test_project_config_round_trip(m5_editor, owned_setting, input_action, owned_autoload):
    name = owned_setting("application/config/m5_test_value")
    exec_ok(m5_editor, "project/settings/set", {"name": name, "value": 42})
    input_action("m5_round_trip_action")
    owned_autoload("M5RoundTripAuto")
    assert exec_ok(m5_editor, "project/settings/get", {"name": name})["value"] == 42
    assert any(item["action"] == "m5_round_trip_action" for item in exec_ok(
        m5_editor, "project/input_map/list", {}
    )["items"])
    assert any(item["name"] == "M5RoundTripAuto" for item in exec_ok(
        m5_editor, "project/autoload/list", {}
    )["autoloads"])


def test_project_config_removals_succeed_without_force(
    m5_editor, owned_setting, input_action, owned_autoload,
):
    owned_setting("application/config/m5_remove_value")
    exec_ok(m5_editor, "project/settings/set", {
        "name": "application/config/m5_remove_value", "value": 7,
    })
    exec_ok(m5_editor, "project/settings/reset", {
        "name": "application/config/m5_remove_value",
    })
    input_action("m5_remove_action")
    event = {"type": "InputEventKey", "keycode": 65}
    exec_ok(m5_editor, "project/input_map/bind", {
        "action": "m5_remove_action", "event": event,
    })
    exec_ok(m5_editor, "project/input_map/unbind", {
        "action": "m5_remove_action", "event": event,
    })
    exec_ok(m5_editor, "project/input_map/action/remove", {"action": "m5_remove_action"})
    owned_autoload("M5RemoveAuto")
    exec_ok(m5_editor, "project/autoload/remove", {"name": "M5RemoveAuto"})
    settings = exec_ok(m5_editor, "project/settings/list", {
        "filter": "application/config/m5_remove_value",
    })
    assert "application/config/m5_remove_value" not in settings["items"]
    actions = exec_ok(m5_editor, "project/input_map/list", {"filter": "m5_remove_action"})
    assert all(item["action"] != "m5_remove_action" for item in actions["items"])
    autoloads = exec_ok(m5_editor, "project/autoload/list", {})
    assert all(item["name"] != "M5RemoveAuto" for item in autoloads["autoloads"])


def test_input_map_and_autoload_are_persisted_to_project_file(
    m5_editor, input_action, owned_autoload,
):
    """Owned InputMap/Autoload changes must be persisted, not just live in memory."""
    input_action("m5_persist_action")
    owned_autoload("M5PersistAuto")
    text = (Path(m5_editor["project"]) / "project.godot").read_text(encoding="utf-8")
    assert "m5_persist_action" in text, text
    assert "M5PersistAuto" in text, text



def test_input_map_add_imports_preexisting_project_action(m5_editor, input_action, owned_setting):
    """Adding a project-defined but not-yet-live action imports its exact state."""
    action = "m5_preexisting_input_action"
    owned_setting("input/" + action)
    key_modifiers = (1 << 25) | (1 << 27)
    mouse_modifiers = 1 << 26
    stored_events = [
        {"type": "InputEventKey", "keycode": 65, "modifiers": key_modifiers},
        {"type": "InputEventMouseButton", "button_index": 1, "modifiers": mouse_modifiers},
    ]
    exec_ok(m5_editor, "project/settings/set", {
        "name": "input/" + action,
        "value": {"deadzone": 0.73, "events": stored_events},
    })

    input_action(action, deadzone=0.2)

    runtime = exec_ok(
        m5_editor, "project/input_map/list", {"filter": action}
    )["items"]
    assert len(runtime) == 1
    assert runtime[0]["deadzone"] == pytest.approx(0.73)
    assert runtime[0]["events"] == [
        {
            "type": "InputEventKey",
            "keycode": 65,
            "physical_keycode": 0,
            "unicode": 0,
            "modifiers": key_modifiers,
        },
        {
            "type": "InputEventMouseButton",
            "button_index": 1,
            "modifiers": mouse_modifiers,
        },
    ]
    persisted = exec_ok(m5_editor, "project/settings/get", {"name": "input/" + action})
    assert persisted["value"]["deadzone"] == pytest.approx(0.73)
    assert len(persisted["value"]["events"]) == 2
    project_text = (Path(m5_editor["project"]) / "project.godot").read_text(encoding="utf-8")
    assert re.search(r'"deadzone"\s*:\s*0\.73', project_text)
    assert re.search(r"(?m)^" + re.escape(action) + r"\s*=\{", project_text)
    assert re.search(r'"keycode"\s*:\s*65', project_text)
    assert re.search(r'"button_index"\s*:\s*1', project_text)
    assert re.search(r'"shift_pressed"\s*:\s*true', project_text)
    assert re.search(r'"meta_pressed"\s*:\s*true', project_text)
    assert re.search(r'"alt_pressed"\s*:\s*true', project_text)


def test_input_map_add_rejects_unsupported_stored_event_without_mutation(m5_editor, owned_setting):
    action = "m5_unsupported_project_action"
    owned_setting("input/" + action)
    setting = {"deadzone": 0.41, "events": [{"type": "InputEventGesture"}]}
    exec_ok(m5_editor, "project/settings/set", {
        "name": "input/" + action, "value": setting,
    })
    project_file = Path(m5_editor["project"]) / "project.godot"
    before = project_file.read_bytes()

    error = exec_error(m5_editor, "project/input_map/action/add", {
        "action": action, "deadzone": 0.2,
    })

    assert error["code"] == "invalid_param", error
    assert exec_ok(
        m5_editor, "project/input_map/list", {"filter": action}
    )["items"] == []
    assert exec_ok(
        m5_editor, "project/settings/get", {"name": "input/" + action}
    )["value"] == setting
    assert project_file.read_bytes() == before

def test_unwritable_project_file_fails_and_rolls_back(m5_editor, read_only_project_file):
    """project.godot 不可写时：必须报错、回滚内存状态、文件保持不变。

    Godot 在编辑器上下文里会返回 OK 却什么都没写（临时文件 rename 失败被吞），
    因此路由需要自己校验落盘结果，这条用例正是覆盖该路径。
    """
    project_godot = Path(m5_editor["project"]) / "project.godot"
    assert not os.access(project_godot, os.W_OK), "前置条件：project.godot 必须不可写"
    before_bytes = project_godot.read_bytes()
    suffix = uuid4().hex
    setting_name = "application/config/m5_rollback_" + suffix
    action_name = "m5_rollback_" + suffix
    autoload_name = "M5Rollback" + suffix
    before_settings = exec_ok(m5_editor, "project/settings/list", {"filter": setting_name})
    before_actions = exec_ok(m5_editor, "project/input_map/list", {"filter": action_name})
    before_autoloads = exec_ok(m5_editor, "project/autoload/list")["autoloads"]

    error = exec_error(m5_editor, "project/settings/set", {
        "name": setting_name, "value": 3,
    })
    assert error["code"] == "godot_error", error
    assert exec_ok(m5_editor, "project/settings/list", {"filter": setting_name}) == before_settings

    error = exec_error(m5_editor, "project/input_map/action/add", {
        "action": action_name,
    })
    assert error["code"] == "godot_error", error
    assert exec_ok(m5_editor, "project/input_map/list", {"filter": action_name}) == before_actions

    error = exec_error(m5_editor, "project/autoload/add", {
        "name": autoload_name, "path": "res://fixtures/state.gd",
    })
    assert error["code"] == "godot_error", error
    autoloads = exec_ok(m5_editor, "project/autoload/list", {})["autoloads"]
    assert autoloads == before_autoloads

    assert project_godot.read_bytes() == before_bytes


@pytest.fixture()
def input_action(m5_editor, owned_setting):
    """Create and remove only this scenario's explicitly owned InputMap actions."""
    created: list[str] = []

    def _create(name: str, **body) -> None:
        existing = exec_ok(m5_editor, "project/input_map/list", {"filter": name})["items"]
        assert all(item["action"] != name for item in existing), existing
        owned_setting("input/" + name)
        exec_ok(m5_editor, "project/input_map/action/add", {"action": name, **body})
        created.append(name)

    yield _create
    for name in reversed(created):
        remaining = exec_ok(m5_editor, "project/input_map/list", {"filter": name})["items"]
        if any(item["action"] == name for item in remaining):
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
