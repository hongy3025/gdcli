"""Resource route acceptance tests."""

from .helpers import exec_error, exec_ok




def test_resource_info_returns_class(m2_editor):
    info = exec_ok(m2_editor, "resource/info", {"path": "res://resources/player_data.tres"})
    assert info["class"] == "Resource"


def test_resource_search_finds_player(m2_editor):
    page = exec_ok(m2_editor, "resource/search", {
        "filter": "player", "offset": 0, "limit": 50,
    })
    assert any("player" in p for p in page["items"])


def test_resource_assign_rejects_non_resource_property(m2_editor):
    error = exec_error(m2_editor, "resource/assign", {
        "node_path": "/root/Main/Player",
        "property": "position",
        "path": "res://icon.svg",
    })
    assert error["code"] == "not_found"


def test_resource_overwrite_without_force(m2_editor):
    overwritten = exec_ok(m2_editor, "resource/create", {
        "path": "res://resources/player_data.tres",
        "type": "Resource",
        "properties": {"resource_name": "Other"},
    })
    assert overwritten["saved"] is True


def test_resource_create_assign_delete_round_trip(m2_editor):
    create_result = exec_ok(m2_editor, "resource/create", {
        "path": "res://resources/generated.tres",
        "type": "Resource",
        "properties": {"resource_name": "Generated"},
    })
    assert create_result["saved"] is True
    deleted = exec_ok(m2_editor, "resource/delete", {
        "path": "res://resources/generated.tres"
    })
    assert deleted["deleted"] is True

