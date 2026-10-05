"""UI controls and theme M4 route contracts."""

from .helpers import command_doc, editor_undo, exec_error, exec_ok, save_scene, select_domain


UI_ROUTES = {"ui/control/set_anchor", "ui/text/set", "ui/layout/build"}
THEME_ROUTES = {"theme/create", "theme/color/set", "theme/constant/set", "theme/font_size/set", "theme/stylebox/set"}


def test_ui_and_theme_routes_are_discoverable_and_documented(m4_env):
    routes = set(exec_ok(m4_env, "gdapi/routes")["routes"])
    for route in sorted(UI_ROUTES | THEME_ROUTES):
        assert route in routes
        assert command_doc(m4_env, route)["summary"]


def test_button_text_and_anchor_use_undo_redo(m4_env):
    scene_path = "res://scenes/ui.tscn"
    select_domain(m4_env, "ui")
    before = exec_ok(m4_env, "node/property/get", {"node_path": "/root/UiDomain/Button", "property": "text"})["value"]
    changed = exec_ok(m4_env, "ui/text/set", {"node_path": "Button", "text": "Updated"})
    assert changed["undoable"] is True
    editor_undo(m4_env)
    assert exec_ok(m4_env, "node/property/get", {"node_path": "/root/UiDomain/Button", "property": "text"})["value"] == before
    anchored = exec_ok(m4_env, "ui/control/set_anchor", {"node_path": "Button", "anchors": {"left": 0.0, "right": 1.0}})
    assert anchored["undoable"] is True
    content = save_scene(m4_env, scene_path)
    assert "anchor_right = 1.0" in content


def test_ui_rejects_non_text_control_and_bad_layout(m4_env):
    select_domain(m4_env, "ui")
    assert exec_error(m4_env, "ui/text/set", {"node_path": "UiDomain", "text": "bad"})["code"] == "not_supported"
    assert exec_error(m4_env, "ui/layout/build", {"node_path": "Button", "layout": "arbitrary"})["code"] == "invalid_param"

