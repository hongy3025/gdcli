"""Animation and AnimationTree M4 route contracts."""

import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

from .helpers import command_doc, editor_redo, editor_undo, exec_error, exec_ok, save_reopen


ANIMATION_ROUTES = {
    "animation/create", "animation/delete", "animation/play", "animation/stop",
    "animation/track/add", "animation/track/remove", "animation/key/add", "animation/key/remove",
    "animation_tree/state/add", "animation_tree/transition/add", "animation_tree/blend/set",
}


def test_animation_routes_are_discoverable_and_documented(m4_env):
    """Removing an M4 animation handler must fail its public manifest contract."""
    routes = set(exec_ok(m4_env, "gdapi/routes")["routes"])
    assert ANIMATION_ROUTES <= routes
    for route in sorted(ANIMATION_ROUTES):
        assert command_doc(m4_env, route)["summary"]


def test_animation_create_delete_are_undoable(m4_env, monkeypatch):
    """Removing the UndoRedo action would leave a deleted animation unrecoverable."""
    exec_ok(m4_env, "scene/open", {"path": "res://scenes/animation.tscn"})
    created = exec_ok(
        m4_env,
        "animation/create",
        {"player_path": "AnimationPlayer", "name": "idle"},
    )
    assert created["undoable"] is True
    exec_ok(
        m4_env,
        "animation/delete",
        {"player_path": "AnimationPlayer", "name": "idle"},
    )

    command = Path(m4_env["project"]) / ".godot" / "gdapi-test-command.json"
    write_text = Path.write_text

    def interrupted_write(path, data, *args, **kwargs):
        if path.parent != command.parent or not path.name.startswith("gdapi-test-command"):
            return write_text(path, data, *args, **kwargs)
        with path.open("w", encoding="utf-8") as stream:
            halfway = len(data) // 2
            stream.write(data[:halfway])
            stream.flush()
            # Observe the same path as the editor while the producer is mid-write.
            # No command is fine; a visible command must already be complete JSON.
            try:
                visible = command.read_text(encoding="utf-8")
            except FileNotFoundError:
                pass
            else:
                assert isinstance(json.loads(visible), dict)
            stream.write(data[halfway:])
        return len(data)

    monkeypatch.setattr(Path, "write_text", interrupted_write)

    editor_undo(m4_env)
    duplicate = exec_error(
        m4_env,
        "animation/create",
        {"player_path": "AnimationPlayer", "name": "idle"},
    )
    assert duplicate["code"] == "conflict"
    editor_redo(m4_env)
    recreated = exec_ok(
        m4_env,
        "animation/create",
        {"player_path": "AnimationPlayer", "name": "idle"},
    )
    assert recreated["name"] == "idle"


def test_history_result_recovers_after_reader_releases_file(m4_env):
    """A temporary Windows reader lock must not force a ten-second command retransmit."""
    if sys.platform != "win32":
        pytest.skip("Windows result-file sharing violation")
    exec_ok(m4_env, "scene/open", {"path": "res://scenes/animation.tscn"})
    params = {"player_path": "AnimationPlayer", "name": "locked_a"}
    other = params | {"name": "locked_b"}
    for data in (params, other):
        exec_ok(m4_env, "animation/create", data)
    for data in (params, other):
        exec_ok(m4_env, "animation/delete", data)
    editor_undo(m4_env)

    result = Path(m4_env["project"]) / ".godot" / "gdapi-test-result.json"
    with ThreadPoolExecutor(max_workers=1) as executor:
        with result.open("rb"):
            future = executor.submit(editor_undo, m4_env)
            deadline = time.monotonic() + 3
            while not result.with_suffix(".tmp").exists() and time.monotonic() < deadline:
                time.sleep(.005)
            assert result.with_suffix(".tmp").exists(), "Editor did not stage the new result"
            # Keep the read handle open across the publisher's attempted rename.
            time.sleep(.1)
        future.result(timeout=3)
    # Publishing the deferred result must not execute Undo a second time.
    for data in (params, other):
        assert exec_error(m4_env, "animation/create", data)["code"] == "conflict"
    editor_redo(m4_env)
    assert exec_ok(m4_env, "animation/create", params)["name"] == params["name"]
    assert exec_error(m4_env, "animation/create", other)["code"] == "conflict"


def test_animation_tree_state_and_transition_are_undoable(m4_env):
    """Replacing state-machine edits with no-ops must fail this observable contract."""
    exec_ok(m4_env, "scene/open", {"path": "res://scenes/animation.tscn"})
    state = exec_ok(
        m4_env,
        "animation_tree/state/add",
        {"tree_path": "AnimationTree", "name": "idle"},
    )
    assert state["undoable"] is True
    transition = exec_ok(
        m4_env,
        "animation_tree/transition/add",
        {"tree_path": "AnimationTree", "from": "Start", "to": "idle"},
    )
    assert transition["undoable"] is True
    duplicate = exec_error(
        m4_env,
        "animation_tree/state/add",
        {"tree_path": "AnimationTree", "name": "idle"},
    )
    assert duplicate["code"] == "conflict"


def test_animation_track_and_key_persist_after_reopen(m4_env):
    """Dropping the resource replacement would lose authored keys on scene reload."""
    scene_path = "res://scenes/animation.tscn"
    exec_ok(m4_env, "scene/open", {"path": scene_path})
    exec_ok(
        m4_env,
        "animation/create",
        {"player_path": "AnimationPlayer", "name": "move"},
    )
    track = exec_ok(
        m4_env,
        "animation/track/add",
        {"player_path": "AnimationPlayer", "name": "move", "path": ".:position"},
    )
    key = exec_ok(
        m4_env,
        "animation/key/add",
        {
            "player_path": "AnimationPlayer",
            "name": "move",
            "track_index": track["track_index"],
            "time": 0.0,
            "value": {"type": "Vector2", "value": [1.0, 2.0]},
        },
    )
    assert key["undoable"] is True
    save_reopen(m4_env, scene_path)
    duplicate = exec_error(
        m4_env,
        "animation/create",
        {"player_path": "AnimationPlayer", "name": "move"},
    )
    assert duplicate["code"] == "conflict"
    # Read the persisted track/key back through the animation API on the reopened scene.
    reopened_key = exec_ok(
        m4_env,
        "animation/key/remove",
        {
            "player_path": "AnimationPlayer",
            "name": "move",
            "track_index": track["track_index"],
            "time": 0.0,
        },
    )
    assert reopened_key["key_index"] == key["key_index"]
    missing_key = exec_error(
        m4_env,
        "animation/key/remove",
        {
            "player_path": "AnimationPlayer",
            "name": "move",
            "track_index": track["track_index"],
            "time": 5.0,
        },
    )
    assert missing_key["code"] == "not_found"
    missing_track = exec_error(
        m4_env,
        "animation/key/remove",
        {
            "player_path": "AnimationPlayer",
            "name": "move",
            "track_index": track["track_index"] + 1,
            "time": 0.0,
        },
    )
    assert missing_track["code"] == "not_found"
    reopened_track = exec_ok(
        m4_env,
        "animation/track/remove",
        {
            "player_path": "AnimationPlayer",
            "name": "move",
            "track_index": track["track_index"],
        },
    )
    assert reopened_track["track_index"] == track["track_index"]
    # The saved scene file itself must carry the authored track path and key time.
    content = exec_ok(m4_env, "filesystem/read", {"path": scene_path})["content"]
    assert 'tracks/0/path = NodePath(".:position")' in content, content
    assert "PackedFloat32Array(0)" in content, content


def test_animation_play_and_stop_expose_player_state(m4_env):
    """Hard-coded play/stop results must not survive the AnimationPlayer read-back."""
    exec_ok(m4_env, "scene/open", {"path": "res://scenes/animation.tscn"})
    exec_ok(
        m4_env,
        "animation/create",
        {"player_path": "AnimationPlayer", "name": "idle"},
    )

    def current_animation() -> str:
        return exec_ok(
            m4_env,
            "node/property/get",
            {"node_path": "/root/AnimationDomain/AnimationPlayer", "property": "current_animation"},
        )["value"]

    assert current_animation() == ""
    exec_ok(m4_env, "animation/play", {"player_path": "AnimationPlayer", "name": "idle"})
    assert current_animation() == "idle"
    exec_ok(m4_env, "animation/stop", {"player_path": "AnimationPlayer"})
    assert current_animation() == ""


def test_animation_key_removal_undo_redo_and_invalid_value(m4_env):
    """A removed key must return only after undo; malformed variants must not mutate it."""
    exec_ok(m4_env, "scene/open", {"path": "res://scenes/animation.tscn"})
    exec_ok(
        m4_env,
        "animation/create",
        {"player_path": "AnimationPlayer", "name": "key_test"},
    )
    track = exec_ok(
        m4_env,
        "animation/track/add",
        {"player_path": "AnimationPlayer", "name": "key_test", "path": ".:position"},
    )
    key_data = {
        "player_path": "AnimationPlayer",
        "name": "key_test",
        "track_index": track["track_index"],
        "time": 0.0,
    }
    exec_ok(m4_env, "animation/key/add", key_data | {"value": 1})
    invalid = exec_error(
        m4_env,
        "animation/key/add",
        key_data | {"time": 1.0, "value": {"type": "NoSuchVariant", "value": []}},
    )
    assert invalid["code"] == "invalid_param"
    exec_ok(m4_env, "animation/key/remove", key_data)
    editor_undo(m4_env)
    editor_redo(m4_env)
    missing = exec_error(m4_env, "animation/key/remove", key_data)
    assert missing["code"] == "not_found"


def test_animation_tree_blend_position_is_undoable(m4_env):
    """Replacing blend edits with direct mutation would lose editor UndoRedo history."""
    exec_ok(m4_env, "scene/open", {"path": "res://scenes/animation.tscn"})
    result = exec_ok(
        m4_env,
        "animation_tree/blend/set",
        {
            "tree_path": "AnimationTree",
            "parameter": "parameters/Blend/blend_position",
            "value": 0.5,
        },
    )
    assert result["undoable"] is True
    editor_undo(m4_env)
    editor_redo(m4_env)
    invalid = exec_error(
        m4_env,
        "animation_tree/blend/set",
        {"tree_path": "AnimationTree", "parameter": "parameters/Blend/weight", "value": 0.5},
    )
    assert invalid["code"] == "invalid_param"
    missing = exec_error(
        m4_env,
        "animation_tree/blend/set",
        {
            "tree_path": "AnimationTree",
            "parameter": "parameters/Missing/blend_position",
            "value": 0.5,
        },
    )
    assert missing["code"] == "not_found"
