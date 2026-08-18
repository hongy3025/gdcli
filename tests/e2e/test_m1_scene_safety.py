"""M1 scene mutation acceptance tests.

The 2026-08-01 plan removed the ``force:true`` confirmation gate; these
tests now assert that scene mutations succeed without force and the audit
log captures each mutation. Each test still owns a per-test workspace
under ``.gdcli_e2e/`` so they remain isolated from the shared fixture.
"""

import json
import shutil
import subprocess
import uuid

import pytest

from conftest import gdcli_json


@pytest.fixture
def scene_workspace(e2e_editor):
    relative = f".gdcli_e2e/{uuid.uuid4().hex}"
    absolute = e2e_editor["fixture"] / relative
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


def _create_scene(env, path):
    return _ok(env, "scene/create", {"scene_path": path})


def test_scene_create_overwrites_existing_target(e2e_editor, scene_workspace):
    relative, _ = scene_workspace
    path = f"res://{relative}/created.tscn"
    first = _create_scene(e2e_editor, path)
    assert first["changed"] is True
    assert first["saved"] is True
    assert first["undoable"] is False
    second = _create_scene(e2e_editor, path)
    assert second["saved"] is True
    assert second["changed"] is True


def test_scene_add_node_succeeds(e2e_editor, scene_workspace):
    relative, _ = scene_workspace
    path = f"res://{relative}/typed.tscn"
    _create_scene(e2e_editor, path)
    body = {
        "scene_path": path,
        "node_type": "Node2D",
        "node_name": "Child",
    }
    response = _ok(e2e_editor, "scene/add_node", body)
    assert response["undoable"] is False
    assert response["saved"] is True


def test_scene_add_node_decodes_vector2(e2e_editor, scene_workspace):
    relative, absolute = scene_workspace
    path = f"res://{relative}/typed.tscn"
    _create_scene(e2e_editor, path)
    body = {
        "scene_path": path,
        "node_type": "Node2D",
        "node_name": "Child",
        "properties": {"position": {"type": "Vector2", "value": [12, 34]}},
    }
    response = _ok(e2e_editor, "scene/add_node", body)
    assert response["undoable"] is False
    content = (absolute / "typed.tscn").read_text(encoding="utf-8")
    assert "position = Vector2(12, 34)" in content


def test_scene_save_overwrites_existing_destination(e2e_editor, scene_workspace):
    relative, absolute = scene_workspace
    source = f"res://{relative}/source.tscn"
    destination = f"res://{relative}/destination.tscn"
    _create_scene(e2e_editor, source)
    (absolute / "destination.tscn").write_text("sentinel", encoding="utf-8")
    response = _ok(
        e2e_editor,
        "scene/save",
        {"scene_path": source, "new_path": destination},
    )
    assert response["saved"] is True
    assert (absolute / "destination.tscn").read_text(encoding="utf-8") != "sentinel"


def test_scene_load_sprite_reports_missing_texture(e2e_editor, scene_workspace):
    relative, _ = scene_workspace
    path = f"res://{relative}/sprite.tscn"
    _create_scene(e2e_editor, path)
    _ok(e2e_editor, "scene/add_node", {
        "scene_path": path,
        "node_type": "Sprite2D",
        "node_name": "Sprite",
    })
    result = subprocess.run(
        [
            str(e2e_editor["gdcli"]), "--json", "exec", "scene/load_sprite",
            "--project", str(e2e_editor["fixture"]),
            "--data", json.dumps({
                "scene_path": path,
                "node_path": "root/Sprite",
                "texture_path": "res://missing.png",
            }),
        ],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    assert result.returncode != 0
    payload = json.loads(result.stderr.split(": ", 1)[1])
    assert payload["code"] == "not_found"


def test_mesh_library_invalid_source_is_not_force_gated(e2e_editor, scene_workspace):
    relative, absolute = scene_workspace
    output = f"res://{relative}/library.tres"
    (absolute / "library.tres").write_text("sentinel", encoding="utf-8")
    result = subprocess.run(
        [
            str(e2e_editor["gdcli"]), "--json", "exec", "scene/export_mesh_library",
            "--project", str(e2e_editor["fixture"]),
            "--data", json.dumps({
                "scene_path": "res://test.tscn",
                "output_path": output,
            }),
        ],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    assert result.returncode != 0
    payload = json.loads(result.stderr.split(": ", 1)[1])
    assert payload["code"] == "godot_error"
    assert (absolute / "library.tres").read_text(encoding="utf-8") == "sentinel"


def test_scene_mutation_success_is_audited(e2e_editor, scene_workspace):
    relative, _ = scene_workspace
    path = f"res://{relative}/audit.tscn"
    _ok(e2e_editor, "gdapi/audit/clear", {})
    _create_scene(e2e_editor, path)
    entries = _ok(e2e_editor, "gdapi/audit/list", {"since": 0, "limit": 20})["entries"]
    assert any(entry["route"] == "scene/create" and entry["ok"] for entry in entries)
