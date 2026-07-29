"""Animation and AnimationTree M4 route contracts."""

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


def test_animation_create_delete_are_undoable(m4_env):
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
            "value": 1,
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
