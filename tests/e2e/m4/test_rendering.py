"""Material and shader M4 route contracts."""

from .helpers import audit_cursor, command_doc, editor_undo, exec_error, exec_ok, save_scene, select_domain, source_digest


RENDERING_ROUTES = {
    "material/create", "material/info", "material/set", "material/assign",
    "material/duplicate", "material/save",
    "shader/read", "shader/write", "shader/uniforms",
    "shader/material/create", "shader/param/set",
}


def test_rendering_routes_are_discoverable_and_documented(m4_env):
    routes = set(exec_ok(m4_env, "gdapi/routes")["routes"])
    assert RENDERING_ROUTES <= routes
    for route in sorted(RENDERING_ROUTES):
        assert command_doc(m4_env, route)["summary"]


def test_shader_write_overwrites_without_force(m4_env):
    """Writing an existing scenario-owned shader must replace its actual disk contents."""
    shader_path = "res://shaders/m4_overwrite.gdshader"
    exec_ok(m4_env, "shader/write", {"path": shader_path, "source": "shader_type canvas_item;\nuniform float old_value;\n"})
    written = exec_ok(
        m4_env,
        "shader/write",
        {"path": shader_path, "source": "shader_type canvas_item;\n"},
    )
    assert written["ok"] is True
    assert written["written"] is True
    assert exec_ok(m4_env, "shader/read", {"path": shader_path})["source"] == "shader_type canvas_item;\n"


def test_canvas_material_is_edited_with_undo_and_persists_assignment(m4_env):
    """Replacing the UndoRedo action would leave a material after editor undo."""
    scene_path = "res://scenes/rendering.tscn"
    select_domain(m4_env, "rendering")
    sprite = exec_ok(m4_env, "node/create", {
        "parent_path": "/root/RenderingDomain", "name": "UndoMaterialSprite", "type": "Sprite2D",
    })["node_path"]

    created = exec_ok(
        m4_env,
        "material/create",
        {"node_path": sprite, "type": "CanvasItemMaterial"},
    )
    assert created["undoable"] is True
    before = exec_ok(m4_env, "material/info", {"node_path": sprite})
    assert before["class"] == "CanvasItemMaterial"

    configured = exec_ok(
        m4_env,
        "material/set",
        {"node_path": sprite, "property": "blend_mode", "value": 1},
    )
    assert configured["undoable"] is True
    assert exec_ok(m4_env, "material/info", {"node_path": sprite})["properties"]["blend_mode"] == 1
    editor_undo(m4_env)
    assert exec_ok(m4_env, "material/info", {"node_path": sprite})["properties"] == before["properties"]

    content = save_scene(m4_env, scene_path)
    assert 'type="CanvasItemMaterial"' in content
    assert exec_ok(m4_env, "material/info", {"node_path": sprite})["class"] == "CanvasItemMaterial"


def test_material_files_are_saved_and_assigned_with_stable_paths(m4_env):
    """Changing a saved path or bypassing assignment would break scene/resource evidence."""
    scene_path = "res://scenes/rendering.tscn"
    material_path = "res://materials/sprite_canvas.tres"
    duplicate_path = "res://materials/sprite_canvas_copy.tres"
    select_domain(m4_env, "rendering")
    sprite = exec_ok(m4_env, "node/create", {
        "parent_path": "/root/RenderingDomain", "name": "SavedMaterialSprite", "type": "Sprite2D",
    })["node_path"]
    exec_ok(m4_env, "material/create", {"node_path": sprite, "type": "CanvasItemMaterial"})

    saved = exec_ok(m4_env, "material/save", {"node_path": sprite, "path": material_path})
    assert saved == {"ok": True, "changed": True, "saved": True, "undoable": False, "path": material_path}
    duplicated = exec_ok(m4_env, "material/duplicate", {"node_path": sprite, "path": duplicate_path})
    assert duplicated["path"] == duplicate_path
    assert duplicated["path"] != material_path

    assigned = exec_ok(m4_env, "material/assign", {"node_path": sprite, "path": duplicate_path})
    assert assigned["undoable"] is True
    content = save_scene(m4_env, scene_path)
    assert f'path="{duplicate_path}"' in content
    assert exec_ok(m4_env, "material/info", {"node_path": sprite})["path"] == duplicate_path


def test_shader_file_uniform_and_parameter_contracts(m4_env):
    """Skipping uniform validation could write an unknown shader parameter to disk."""
    shader_path = "res://shaders/m4_uniforms.gdshader"
    material_path = "res://materials/m4_shader_material.tres"
    source = "shader_type canvas_item;\nuniform float strength = 0.5;\n"
    shader_file = m4_env["project"] / "shaders" / "m4_uniforms.gdshader"
    exec_ok(m4_env, "shader/write", {"path": shader_path, "source": "shader_type canvas_item;\n"})
    before = source_digest(shader_file)
    since = audit_cursor(m4_env)
    written = exec_ok(m4_env, "shader/write", {"path": shader_path, "source": source})
    assert written["undoable"] is False
    assert source_digest(shader_file) != before
    assert exec_ok(m4_env, "shader/read", {"path": shader_path})["source"] == source
    assert exec_ok(m4_env, "shader/uniforms", {"path": shader_path})["uniforms"] == [
        {"name": "strength", "type": "float", "default": "0.5"},
    ]

    created = exec_ok(m4_env, "shader/material/create", {"shader_path": shader_path, "path": material_path})
    assert created["path"] == material_path
    changed = exec_ok(
        m4_env,
        "shader/param/set",
        {"path": material_path, "name": "strength", "value": 0.75},
    )
    assert changed["undoable"] is False
    assert exec_error(
        m4_env,
        "shader/param/set",
        {"path": material_path, "name": "missing", "value": 1.0},
    )["code"] == "not_found"
    entries = exec_ok(m4_env, "gdapi/audit/list", {"since": since, "limit": 100})["entries"]
    assert any(entry["route"] == "shader/write" and entry["ok"] is True for entry in entries)


def test_rendering_rejects_invalid_material_values_and_unsafe_paths(m4_env):
    """Relaxing typed validation or PathGuard would mutate the wrong asset."""
    select_domain(m4_env, "rendering")
    sprite = exec_ok(m4_env, "node/create", {
        "parent_path": "/root/RenderingDomain", "name": "InvalidMaterialSprite", "type": "Sprite2D",
    })["node_path"]
    exec_ok(m4_env, "material/create", {"node_path": sprite, "type": "CanvasItemMaterial"})
    before = exec_ok(m4_env, "material/info", {"node_path": sprite})
    assert exec_error(
        m4_env,
        "material/set",
        {"node_path": sprite, "property": "blend_mode", "value": "one"},
    )["code"] == "invalid_param"
    assert exec_error(
        m4_env,
        "material/set",
        {"node_path": sprite, "property": "not_a_property", "value": 1},
    )["code"] == "not_found"
    assert exec_ok(m4_env, "material/info", {"node_path": sprite}) == before
    assert exec_error(
        m4_env,
        "shader/write",
        {"path": "res://shaders/../outside.gdshader", "source": "shader_type canvas_item;"},
    )["code"] == "invalid_path"
