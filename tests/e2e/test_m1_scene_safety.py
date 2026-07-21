"""M1 scene mutation safety acceptance tests."""

import json
import shutil
import subprocess
import uuid

import pytest

from conftest import gdcli_json


@pytest.fixture
def scene_workspace(godot_env):
    relative = f".gdcli_e2e/{uuid.uuid4().hex}"
    absolute = godot_env["fixture"] / relative
    absolute.mkdir(parents=True)
    try:
        yield relative, absolute
    finally:
        shutil.rmtree(absolute, ignore_errors=True)


def _ok(env, route, body):
    return gdcli_json(
        env,
        "exec",
        route,
        "--project",
        str(env["fixture"]),
        "--data",
        json.dumps(body),
    )


def _error(env, route, body):
    result = subprocess.run(
        [
            str(env["gdcli"]), "--json", "exec", route,
            "--project", str(env["fixture"]),
            "--data", json.dumps(body),
        ],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    assert result.returncode != 0, result.stdout
    payload = result.stderr.split(": ", 1)[1]
    return json.loads(payload)


def _create_scene(env, path):
    return _ok(env, "scene/create", {"scene_path": path})


def test_scene_create_requires_force_only_for_existing_target(godot_env, scene_workspace):
    relative, _ = scene_workspace
    path = f"res://{relative}/created.tscn"
    first = _create_scene(godot_env, path)
    assert first["changed"] is True
    assert first["saved"] is True
    assert first["undoable"] is False
    assert _error(godot_env, "scene/create", {"scene_path": path})["code"] == "unsafe_operation"
    forced = _ok(godot_env, "scene/create", {"scene_path": path, "force": True})
    assert forced["saved"] is True


def test_scene_add_node_requires_force(godot_env, scene_workspace):
    relative, _ = scene_workspace
    path = f"res://{relative}/typed.tscn"
    _create_scene(godot_env, path)
    body = {
        "scene_path": path,
        "node_type": "Node2D",
        "node_name": "Child",
    }
    assert _error(godot_env, "scene/add_node", body)["code"] == "unsafe_operation"
    body["force"] = True
    response = _ok(godot_env, "scene/add_node", body)
    assert response["undoable"] is False


def test_scene_add_node_decodes_vector2(godot_env, scene_workspace):
    relative, absolute = scene_workspace
    path = f"res://{relative}/typed.tscn"
    _create_scene(godot_env, path)
    body = {
        "scene_path": path,
        "node_type": "Node2D",
        "node_name": "Child",
        "properties": {"position": {"type": "Vector2", "value": [12, 34]}},
        "force": True,
    }
    response = _ok(godot_env, "scene/add_node", body)
    assert response["undoable"] is False
    content = (absolute / "typed.tscn").read_text(encoding="utf-8")
    assert "position = Vector2(12, 34)" in content


def test_scene_save_rejects_unforced_existing_destination(godot_env, scene_workspace):
    relative, absolute = scene_workspace
    source = f"res://{relative}/source.tscn"
    destination = f"res://{relative}/destination.tscn"
    _create_scene(godot_env, source)
    (absolute / "destination.tscn").write_text("sentinel", encoding="utf-8")
    error = _error(
        godot_env,
        "scene/save",
        {"scene_path": source, "new_path": destination},
    )
    assert error["code"] == "unsafe_operation"
    assert (absolute / "destination.tscn").read_text(encoding="utf-8") == "sentinel"


def test_scene_load_sprite_requires_force(godot_env, scene_workspace):
    relative, _ = scene_workspace
    path = f"res://{relative}/sprite.tscn"
    _create_scene(godot_env, path)
    _ok(godot_env, "scene/add_node", {
        "scene_path": path,
        "node_type": "Sprite2D",
        "node_name": "Sprite",
        "force": True,
    })
    error = _error(godot_env, "scene/load_sprite", {
        "scene_path": path,
        "node_path": "root/Sprite",
        "texture_path": "res://missing.png",
    })
    assert error["code"] == "unsafe_operation"


def test_mesh_library_rejects_unforced_existing_destination(godot_env, scene_workspace):
    relative, absolute = scene_workspace
    output = f"res://{relative}/library.tres"
    (absolute / "library.tres").write_text("sentinel", encoding="utf-8")
    error = _error(godot_env, "scene/export_mesh_library", {
        "scene_path": "res://test.tscn",
        "output_path": output,
    })
    assert error["code"] == "unsafe_operation"
    assert (absolute / "library.tres").read_text(encoding="utf-8") == "sentinel"


def test_scene_mutation_success_and_rejection_are_audited(godot_env, scene_workspace):
    relative, _ = scene_workspace
    path = f"res://{relative}/audit.tscn"
    _ok(godot_env, "gdapi/audit/clear", {"force": True})
    _create_scene(godot_env, path)
    _error(godot_env, "scene/add_node", {
        "scene_path": path,
        "node_type": "Node2D",
        "node_name": "Rejected",
    })
    entries = _ok(godot_env, "gdapi/audit/list", {"since": 0, "limit": 20})["entries"]
    assert any(entry["route"] == "scene/create" and entry["ok"] for entry in entries)
    assert any(entry["route"] == "scene/add_node" and not entry["ok"] for entry in entries)