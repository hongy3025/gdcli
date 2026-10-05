"""Audio bus and player M4 route contracts."""

from .helpers import command_doc, editor_undo, exec_error, exec_ok, select_domain


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
    select_domain(m4_env, "audio")
    before = exec_ok(m4_env, "audio/bus/list")["buses"]
    added = exec_ok(m4_env, "audio/bus/add", {"name": "M4Effects"})
    assert added["undoable"] is True
    assert set(exec_ok(m4_env, "audio/bus/list")["buses"]) == set(before) | {"M4Effects"}
    removed = exec_ok(m4_env, "audio/bus/remove", {"name": "M4Effects"})
    assert removed["changed"] is True
    assert removed["undoable"] is True
    assert exec_ok(m4_env, "audio/bus/list")["buses"] == before

def test_audio_player_creation_is_undoable(m4_env):
    select_domain(m4_env, "audio")
    created = exec_ok(
        m4_env,
        "audio/player/create",
        {"name": "GeneratedPlayer", "stream_path": "res://resources/tone.tres"},
    )
    assert created["undoable"] is True
    editor_undo(m4_env)


def test_audio_play_and_stop_expose_real_player_state(m4_env):
    """A hard-coded ``playing`` field must not survive a real play/stop round trip."""
    select_domain(m4_env, "audio")
    # An endless generator stream keeps ``playing`` observable across editor frames.
    stream_path = "res://resources/playback_probe.tres"
    exec_ok(m4_env, "resource/create", {"path": stream_path, "type": "AudioStreamGenerator"})
    created = exec_ok(
        m4_env,
        "audio/player/create",
        {"name": "Playable", "stream_path": stream_path},
    )
    node_path = "/root/AudioDomain/" + created["name"]

    def playing() -> bool:
        return exec_ok(
            m4_env, "node/property/get", {"node_path": node_path, "property": "playing"}
        )["value"]

    assert playing() is False
    played = exec_ok(m4_env, "audio/play", {"node_path": node_path})
    assert played["playing"] is True
    assert playing() is True
    stopped = exec_ok(m4_env, "audio/stop", {"node_path": node_path})
    assert stopped["playing"] is False
    assert playing() is False

