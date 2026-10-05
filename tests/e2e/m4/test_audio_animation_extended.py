"""Real audio layouts and serializable animation graphs."""

from __future__ import annotations

import pytest

from .helpers import editor_redo, editor_undo, exec_error, exec_ok, save_scene, select_domain


SCENE = "res://scenes/animation.tscn"
TREE = {"tree_path": "AnimationTree"}


def _authored_tree(env, name):
    """Create a scenario-owned graph, leaving other authored trees intact.

    ``tree_path`` is node/create's absolute user path (``/root/<root>/<name>``),
    which animation_tree routes resolve to the same node as the scene-relative
    form; generic node/property/set stays absolute per the node/* contract.
    """
    created = exec_ok(env, "node/create", {
        "parent_path": "/root/AnimationDomain", "type": "AnimationTree", "name": name,
    })
    tree = {"tree_path": created["node_path"]}
    exec_ok(env, "node/property/set", {
        "node_path": created["node_path"], "property": "anim_player",
        "value": {"type": "NodePath", "value": "../AnimationPlayer"},
    })
    return tree


def test_audio_bus_properties_effects_persist_and_undo(m4_env):
    select_domain(m4_env, "audio")
    exec_ok(m4_env, "audio/bus/add", {"name": "AuthoredAudio"})
    properties = {"volume_db": -7.5, "mute": True, "solo": True, "bypass": True, "send": "Master"}
    changed = exec_ok(m4_env, "audio/bus/set", {"name": "AuthoredAudio", "properties": properties})
    assert changed["undoable"] is True
    actual = exec_ok(m4_env, "audio/bus/get", {"name": "AuthoredAudio"})
    for key, value in properties.items():
        assert actual[key] == value
    editor_undo(m4_env)
    assert exec_ok(m4_env, "audio/bus/get", {"name": "AuthoredAudio"})["volume_db"] == 0
    editor_redo(m4_env)
    added = exec_ok(m4_env, "audio/bus/effect/add", {
        "name": "AuthoredAudio", "type": "AudioEffectAmplify", "parameters": {"volume_db": -4},
    })
    assert added["slot"] == 0 and added["enabled"] is True
    assert added["parameters"]["volume_db"] == -4
    exec_ok(m4_env, "audio/bus/effect/enable", {"name": "AuthoredAudio", "slot": 0, "enabled": False})
    assert exec_ok(m4_env, "audio/bus/effect/get", {"name": "AuthoredAudio", "slot": 0})["enabled"] is False
    editor_undo(m4_env)
    assert exec_ok(m4_env, "audio/bus/effect/get", {"name": "AuthoredAudio", "slot": 0})["enabled"] is True
    exec_ok(m4_env, "audio/bus/effect/set", {
        "name": "AuthoredAudio", "slot": 0, "parameters": {"volume_db": -2}, "enabled": False,
    })
    updated = exec_ok(m4_env, "audio/bus/effect/get", {"name": "AuthoredAudio", "slot": 0})
    assert updated["parameters"]["volume_db"] == -2 and updated["enabled"] is False
    layout = {"path": changed["layout_path"]}
    prefix = f"bus/{actual['index']}/"
    assert exec_ok(m4_env, "resource/get", layout | {"property": prefix + "name"})["value"] == "AuthoredAudio"
    assert exec_ok(m4_env, "resource/get", layout | {"property": prefix + "volume_db"})["value"] == -7.5
    assert exec_ok(m4_env, "resource/get", layout | {"property": prefix + "effect/0/enabled"})["value"] is False
    exec_ok(m4_env, "audio/bus/effect/remove", {"name": "AuthoredAudio", "slot": 0})
    assert exec_ok(m4_env, "audio/bus/get", {"name": "AuthoredAudio"})["effects"] == []
    editor_undo(m4_env)
    assert exec_ok(m4_env, "audio/bus/effect/get", {"name": "AuthoredAudio", "slot": 0})["parameters"]["volume_db"] == -2
    exec_ok(m4_env, "audio/bus/remove", {"name": "AuthoredAudio"})
    editor_undo(m4_env)
    assert exec_ok(m4_env, "audio/bus/get", {"name": "AuthoredAudio"})["volume_db"] == -7.5
    exec_ok(m4_env, "audio/bus/remove", {"name": "AuthoredAudio"})


def test_audio_send_cycles_and_invalid_effects_are_atomic(m4_env):
    for name in ["SendA", "SendB"]:
        exec_ok(m4_env, "audio/bus/add", {"name": name})
    exec_ok(m4_env, "audio/bus/set", {"name": "SendA", "properties": {"send": "SendB"}})
    baseline = exec_ok(m4_env, "audio/bus/get", {"name": "SendB"})
    error = exec_error(m4_env, "audio/bus/set", {"name": "SendB", "properties": {"mute": True, "send": "SendA"}})
    assert error["code"] == "conflict"
    assert exec_ok(m4_env, "audio/bus/get", {"name": "SendB"}) == baseline
    assert exec_error(m4_env, "audio/bus/set", {"name": "SendA", "properties": {"send": "SendA"}})["code"] == "conflict"
    for payload in [
        {"type": "Node"},
        {"type": "AudioEffectAmplify", "parameters": {"volume_db": "loud"}},
        {"type": "AudioEffectAmplify", "parameters": {"script": "res://bad.gd"}},
        {"type": "AudioEffectAmplify", "slot": 4},
        {"type": "AudioEffectAmplify", "enabled": "yes"},
    ]:
        assert exec_error(m4_env, "audio/bus/effect/add", {"name": "SendB"} | payload)["code"] == "invalid_param"
        assert exec_ok(m4_env, "audio/bus/get", {"name": "SendB"})["effects"] == []
    assert exec_error(m4_env, "audio/bus/remove", {"name": "Master"})["code"] == "permission_denied"
    assert exec_error(m4_env, "audio/bus/effect/get", {"name": "SendB", "slot": -1})["code"] == "invalid_param"
    exec_ok(m4_env, "audio/bus/remove", {"name": "SendB"})
    assert exec_ok(m4_env, "audio/bus/get", {"name": "SendA"})["send"] == "Master"
    exec_ok(m4_env, "audio/bus/remove", {"name": "SendA"})


def test_animation_state_removal_cleans_transitions_and_undo(m4_env):
    select_domain(m4_env, "animation")
    exec_ok(m4_env, "animation_tree/state/add", TREE | {"name": "remove_me"})
    edge = TREE | {"from": "Start", "to": "remove_me"}
    exec_ok(m4_env, "animation_tree/transition/add", edge)
    exec_ok(m4_env, "animation_tree/transition/remove", edge)
    assert exec_error(m4_env, "animation_tree/transition/remove", edge)["code"] == "not_found"
    editor_undo(m4_env)
    assert exec_error(m4_env, "animation_tree/transition/add", edge)["code"] == "conflict"
    removed = exec_ok(m4_env, "animation_tree/state/remove", TREE | {"name": "remove_me"})
    assert removed["undoable"] is True
    assert exec_error(m4_env, "animation_tree/transition/remove", edge)["code"] == "not_found"
    editor_undo(m4_env)
    assert exec_error(m4_env, "animation_tree/transition/add", edge)["code"] == "conflict"
    editor_redo(m4_env)
    content = save_scene(m4_env, SCENE)
    assert "remove_me" not in content
    exec_ok(m4_env, "animation_tree/state/add", TREE | {"name": "remove_me"})
    assert exec_error(m4_env, "animation_tree/state/remove", TREE | {"name": "Start"})["code"] == "invalid_param"


def test_blend_tree_authoring_serialization_and_undo(m4_env):
    select_domain(m4_env, "animation")
    TREE = _authored_tree(m4_env, "SerializationTree")
    exec_ok(m4_env, "animation/create", {"player_path": "AnimationPlayer", "name": "graph_idle"})
    created = exec_ok(m4_env, "animation_tree/blend_tree/create", TREE)
    assert created["undoable"] is True
    exec_ok(m4_env, "animation_tree/blend_tree/add", TREE | {
        "name": "idle", "type": "AnimationNodeAnimation", "properties": {"animation": "graph_idle"},
    })
    exec_ok(m4_env, "animation_tree/blend_tree/add", TREE | {"name": "blend", "type": "AnimationNodeBlend2", "parameters": {"blend_amount": 0.25}})
    exec_ok(m4_env, "animation_tree/blend_tree/add", TREE | {"name": "scale", "type": "AnimationNodeTimeScale", "parameters": {"scale": 1.5}})
    for input_node, port, output_node in [("blend", 0, "idle"), ("scale", 0, "blend"), ("output", 0, "scale")]:
        exec_ok(m4_env, "animation_tree/blend_tree/connect", TREE | {"input_node": input_node, "input_index": port, "output_node": output_node})
    authored = exec_ok(m4_env, "animation_tree/blend_tree/get", TREE)
    assert authored["parameters"]["parameters/blend/blend_amount"] == 0.25
    assert authored["parameters"]["parameters/scale/scale"] == 1.5
    content = save_scene(m4_env, SCENE)
    assert 'animation = &"graph_idle"' in content
    assert 'name="SerializationTree"' in content
    assert "parameters/blend/blend_amount = 0.25" in content
    assert "parameters/scale/scale = 1.5" in content
    saved_state = exec_ok(m4_env, "animation_tree/blend_tree/get", TREE)
    assert saved_state["connections"] == authored["connections"]
    assert saved_state["parameters"] == authored["parameters"]
    idle = next(node for node in saved_state["nodes"] if node["name"] == "idle")
    assert idle["properties"]["animation"] == "graph_idle"
    exec_ok(m4_env, "animation_tree/blend_tree/set", TREE | {"name": "blend", "parameters": {"blend_amount": 0.75}})
    editor_undo(m4_env)
    assert exec_ok(m4_env, "animation_tree/blend_tree/get", TREE)["parameters"]["parameters/blend/blend_amount"] == 0.25
    editor_redo(m4_env)
    assert exec_ok(m4_env, "animation_tree/blend_tree/get", TREE)["parameters"]["parameters/blend/blend_amount"] == 0.75
    exec_ok(m4_env, "animation_tree/blend_tree/remove", TREE | {"name": "scale"})
    graph = exec_ok(m4_env, "animation_tree/blend_tree/get", TREE)
    assert all(edge["input_node"] != "scale" and edge["output_node"] != "scale" for edge in graph["connections"])
    editor_undo(m4_env)
    assert exec_ok(m4_env, "animation_tree/blend_tree/get", TREE)["connections"] == authored["connections"]
    exec_ok(m4_env, "animation_tree/blend_tree/disconnect", TREE | {"input_node": "output", "input_index": 0})
    assert len(exec_ok(m4_env, "animation_tree/blend_tree/get", TREE)["connections"]) == 2


@pytest.mark.parametrize("node_type,parameters", [
    ("AnimationNodeBlend3", {"blend_amount": -0.5}),
    ("AnimationNodeOneShot", {"request": 1}),
    ("AnimationNodeTimeScale", {"scale": 2.0}),
    ("AnimationNodeTimeSeek", {"seek_request": 0.5}),
    ("AnimationNodeAdd2", {"add_amount": 0.5}),
    ("AnimationNodeAdd3", {"add_amount": 0.5}),
    ("AnimationNodeSub2", {"sub_amount": 0.5}),
])
def test_common_blend_nodes_have_real_typed_parameters(m4_env, node_type, parameters):
    select_domain(m4_env, "animation")
    TREE = _authored_tree(m4_env, "Typed" + node_type)
    exec_ok(m4_env, "animation_tree/blend_tree/create", TREE)
    result = exec_ok(m4_env, "animation_tree/blend_tree/add", TREE | {"name": "authored", "type": node_type, "parameters": parameters})
    assert next(node for node in result["nodes"] if node["name"] == "authored")["type"] == node_type
    for key, value in parameters.items():
        assert result["parameters"]["parameters/authored/" + key] == value


def test_blend_tree_invalid_graph_and_parameters_are_atomic(m4_env):
    select_domain(m4_env, "animation")
    TREE = _authored_tree(m4_env, "AtomicGraphTree")
    exec_ok(m4_env, "animation_tree/blend_tree/create", TREE)
    for name in ["a", "b"]:
        exec_ok(m4_env, "animation_tree/blend_tree/add", TREE | {"name": name, "type": "AnimationNodeBlend2"})
    exec_ok(m4_env, "animation_tree/blend_tree/connect", TREE | {"input_node": "a", "input_index": 0, "output_node": "b"})
    baseline = exec_ok(m4_env, "animation_tree/blend_tree/get", TREE)
    cases = [
        ("connect", {"input_node": "b", "input_index": 0, "output_node": "a"}, "conflict"),
        ("connect", {"input_node": "a", "input_index": 1, "output_node": "missing"}, "not_found"),
        ("connect", {"input_node": "a", "input_index": 5, "output_node": "b"}, "invalid_param"),
        ("remove", {"name": "output"}, "invalid_param"),
        ("add", {"name": "invalid", "type": "Node"}, "invalid_param"),
        ("add", {"name": "invalid", "type": "AnimationNodeBlend3", "parameters": {"blend_amount": "bad"}}, "invalid_param"),
        ("set", {"name": "a", "properties": {"script": "res://bad.gd"}}, "invalid_param"),
        ("set", {"name": "a", "parameters": {"not_a_parameter": 1}}, "invalid_param"),
    ]
    for op, payload, code in cases:
        assert exec_error(m4_env, "animation_tree/blend_tree/" + op, TREE | payload)["code"] == code
        assert exec_ok(m4_env, "animation_tree/blend_tree/get", TREE) == baseline
