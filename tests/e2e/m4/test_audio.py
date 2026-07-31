"""Audio bus and player M4 route contracts."""

from .helpers import command_doc, editor_undo, exec_error, exec_ok


AUDIO_ROUTES = {
    "audio/bus/list", "audio/bus/add", "audio/bus/remove",
    "audio/player/create", "audio/play", "audio/stop",
}


def test_audio_routes_are_discoverable_and_documented(m4_env):
    routes = set(exec_ok(m4_env, "gdapi/routes")["routes"])
    assert AUDIO_ROUTES <= routes
    for route in sorted(AUDIO_ROUTES):
        assert command_doc(m4_env, route)["summary"]


def test_audio_bus_add_and_remove_require_safe_semantics(m4_env):
    exec_ok(m4_env, "scene/open", {"path": "res://scenes/audio.tscn"})
    added = exec_ok(m4_env, "audio/bus/add", {"name": "Effects"})
    assert added["undoable"] is False
    assert "Effects" in exec_ok(m4_env, "audio/bus/list")["buses"]
    removed = exec_ok(m4_env, "audio/bus/remove", {"name": "Effects"})
    assert removed["changed"] is True
    assert removed["undoable"] is False
    assert "Effects" not in exec_ok(m4_env, "audio/bus/list")["buses"]

def test_audio_player_creation_is_undoable(m4_env):
    exec_ok(m4_env, "scene/open", {"path": "res://scenes/audio.tscn"})
    created = exec_ok(
        m4_env,
        "audio/player/create",
        {"name": "GeneratedPlayer", "stream_path": "res://resources/tone.tres"},
    )
    assert created["undoable"] is True
    editor_undo(m4_env)

