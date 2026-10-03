"""3D construction and GPU-particle state/transaction/persistence acceptance."""
from __future__ import annotations

import pytest

from .helpers import editor_redo, editor_undo, exec_error, exec_ok


def variant(kind, value):
    return {"type": kind, "value": value}


def resource(kind, **properties):
    return {"class": kind, "properties": properties}


def resource_state(value):
    if isinstance(value, dict):
        return {key: resource_state(item) for key, item in value.items() if key != "path"}
    if isinstance(value, list):
        return [resource_state(item) for item in value]
    return value


def spatial(editor):
    exec_ok(editor, "scene/open", {"path": "res://scenes/spatial.tscn"})


def reopen(editor):
    exec_ok(editor, "scene/current/save", {"path": "res://scenes/spatial_saved.tscn"})
    exec_ok(editor, "scene/close")
    exec_ok(editor, "scene/open", {"path": "res://scenes/spatial_saved.tscn"})


@pytest.mark.parametrize("kind,properties", [
    ("DirectionalLight3D", {"light_energy": 2.0, "shadow_enabled": True}),
    ("OmniLight3D", {"light_energy": 3.0, "omni_range": 8.0}),
    ("SpotLight3D", {"spot_range": 9.0, "spot_angle": 30.0}),
    ("Camera3D", {"fov": 55.0, "near": 0.2, "far": 200.0}),
    ("CSGBox3D", {"size": variant("Vector3", [2, 3, 4])}),
    ("CSGSphere3D", {"radius": 2.0, "radial_segments": 16}),
    ("CSGCylinder3D", {"radius": 2.0, "height": 4.0, "cone": True}),
    ("CSGTorus3D", {"inner_radius": 0.5, "outer_radius": 2.0}),
    ("CSGPolygon3D", {"polygon": variant("PackedVector2Array", [[-1, -1], [1, -1], [0, 1]]), "depth": 2.0}),
    ("CSGMesh3D", {"mesh": resource("BoxMesh", size=variant("Vector3", [2, 2, 2]))}),
    ("CSGCombiner3D", {"position": variant("Vector3", [1, 2, 3])}),
])
def test_each_spatial_construct_configured_undo_redo_and_persistent(m2_editor, kind, properties):
    spatial(m2_editor)
    created = exec_ok(m2_editor, "scene3d/create", {
        "parent_path": "/root/Spatial", "type": kind, "name": "Construct", "properties": properties,
    })
    assert created["undoable"] is True
    path = "/root/Spatial/Construct"
    before = exec_ok(m2_editor, "scene3d/info", {"node_path": path})
    for key, value in properties.items():
        actual = before["properties"][key]
        if isinstance(value, dict) and "class" in value:
            assert actual["class"] == value["class"]
            for prop, configured in value["properties"].items():
                assert actual["properties"][prop] == configured
        else:
            assert actual == (pytest.approx(value) if isinstance(value, float) else value)
    editor_undo(m2_editor)
    assert exec_error(m2_editor, "scene3d/info", {"node_path": path})["code"] == "not_found"
    editor_redo(m2_editor)
    assert exec_ok(m2_editor, "scene3d/info", {"node_path": path})["properties"] == before["properties"]
    changed = exec_ok(m2_editor, "scene3d/set", {"node_path": path, "properties": {"position": variant("Vector3", [4, 5, 6])}})
    assert changed["undoable"] is True
    editor_undo(m2_editor)
    assert exec_ok(m2_editor, "scene3d/info", {"node_path": path})["properties"] == before["properties"]
    editor_redo(m2_editor)
    reopen(m2_editor)
    after = exec_ok(m2_editor, "scene3d/info", {"node_path": path})
    assert after["properties"]["position"] == variant("Vector3", [4, 5, 6])
    for key in properties:
        if key != "position":
            assert resource_state(after["properties"][key]) == resource_state(before["properties"][key])


def test_environment_sky_material_configuration_persists_and_is_undoable(m2_editor):
    spatial(m2_editor)
    sky_color = variant("Color", [0.125, 0.25, 0.5, 1])
    environment = resource("Environment", background_mode=2, ambient_light_energy=0.5,
        sky=resource("Sky", sky_material=resource("ProceduralSkyMaterial", sky_top_color=sky_color)))
    exec_ok(m2_editor, "scene3d/create", {"parent_path": "/root/Spatial", "type": "WorldEnvironment", "name": "World", "properties": {"environment": environment}})
    path = "/root/Spatial/World"
    exec_ok(m2_editor, "scene3d/set", {"node_path": path, "properties": {"environment": resource("Environment", background_mode=1, background_energy_multiplier=2.0)}})
    editor_undo(m2_editor)
    info = exec_ok(m2_editor, "scene3d/info", {"node_path": path})
    assert info["properties"]["environment"]["properties"]["sky"]["properties"]["sky_material"]["properties"]["sky_top_color"] == sky_color
    editor_redo(m2_editor)
    assert exec_ok(m2_editor, "scene3d/info", {"node_path": path})["properties"]["environment"]["properties"]["background_mode"] == 1
    editor_undo(m2_editor)
    reopen(m2_editor)
    saved = exec_ok(m2_editor, "scene3d/info", {"node_path": path})["properties"]["environment"]["properties"]
    assert saved["ambient_light_energy"] == 0.5
    assert saved["sky"]["properties"]["sky_material"]["properties"]["sky_top_color"] == sky_color


def test_gridmap_library_cells_atomic_replace_undo_and_persistence(m2_editor):
    spatial(m2_editor)
    cells = [{"position": variant("Vector3i", [2, 0, -3]), "item": 7, "orientation": 5}]
    library = {"items": [{"id": 7, "name": "Cube", "mesh": resource("BoxMesh", size=variant("Vector3", [2, 2, 2]))}]}
    exec_ok(m2_editor, "scene3d/create", {"parent_path": "/root/Spatial", "type": "GridMap", "name": "Grid", "mesh_library": library, "cells": cells, "properties": {"cell_size": variant("Vector3", [3, 3, 3])}})
    path = "/root/Spatial/Grid"
    assert exec_ok(m2_editor, "scene3d/info", {"node_path": path})["cells"] == cells
    bad = exec_error(m2_editor, "scene3d/set", {"node_path": path, "mesh_library": {"items": []}, "cells": cells})
    assert bad["code"] == "invalid_param"
    assert exec_ok(m2_editor, "scene3d/info", {"node_path": path})["cells"] == cells
    exec_ok(m2_editor, "scene3d/set", {"node_path": path, "cells": []})
    editor_undo(m2_editor)
    assert exec_ok(m2_editor, "scene3d/info", {"node_path": path})["cells"] == cells
    editor_redo(m2_editor)
    assert exec_ok(m2_editor, "scene3d/info", {"node_path": path})["cells"] == []
    editor_undo(m2_editor)
    reopen(m2_editor)
    info = exec_ok(m2_editor, "scene3d/info", {"node_path": path})
    assert info["cells"] == cells
    assert info["mesh_library"]["items"][0]["id"] == 7
    assert info["mesh_library"]["items"][0]["mesh"]["properties"]["size"] == variant("Vector3", [2, 2, 2])


def test_multimesh_instances_mesh_transform_color_custom_roundtrip(m2_editor):
    spatial(m2_editor)
    transform = variant("Transform3D", [[[1, 0, 0], [0, 2, 0], [0, 0, 1]], [3, 4, 5]])
    instance = {"transform": transform, "color": variant("Color", [0.5, 0.25, 1, 1]), "custom_data": variant("Color", [0.125, 0.25, 0.5, 1])}
    multi = {"mesh": resource("SphereMesh", radius=0.5, height=1.0), "instances": [instance], "visible_instance_count": 1}
    exec_ok(m2_editor, "scene3d/create", {"parent_path": "/root/Spatial", "type": "MultiMeshInstance3D", "name": "Many", "multimesh": multi})
    path = "/root/Spatial/Many"
    assert exec_ok(m2_editor, "scene3d/info", {"node_path": path})["multimesh"]["instances"] == [instance]
    exec_ok(m2_editor, "scene3d/set", {"node_path": path, "multimesh": {"mesh": resource("BoxMesh"), "instances": []}})
    editor_undo(m2_editor)
    assert exec_ok(m2_editor, "scene3d/info", {"node_path": path})["multimesh"]["instances"] == [instance]
    editor_redo(m2_editor)
    assert exec_ok(m2_editor, "scene3d/info", {"node_path": path})["multimesh"]["instances"] == []
    editor_undo(m2_editor)
    reopen(m2_editor)
    saved = exec_ok(m2_editor, "scene3d/info", {"node_path": path})["multimesh"]
    assert saved["instances"] == [instance]
    assert saved["mesh"]["class"] == "SphereMesh"
    assert saved["mesh"]["properties"]["radius"] == 0.5


@pytest.mark.parametrize("kind", ["GPUParticles2D", "GPUParticles3D"])
def test_particles_configuration_material_draw_resources_undo_and_persistence(m2_editor, kind):
    spatial(m2_editor)
    material = resource("ParticleProcessMaterial", gravity=variant("Vector3", [0, -4, 0]), initial_velocity_min=2.0, initial_velocity_max=5.0, particle_flag_disable_z=kind.endswith("2D"))
    props = {"amount": 24, "lifetime": 2.5, "emitting": False, "process_material": material}
    draw = "texture" if kind.endswith("2D") else "draw_pass_1"
    props[draw] = resource("GradientTexture2D", width=8, height=8, gradient=resource("Gradient")) if kind.endswith("2D") else resource("QuadMesh", size=variant("Vector2", [0.5, 0.5]))
    exec_ok(m2_editor, "particles/create", {"parent_path": "/root/Spatial", "type": kind, "name": "GPU", "properties": props})
    path = "/root/Spatial/GPU"
    before = exec_ok(m2_editor, "particles/info", {"node_path": path})["properties"]
    assert before["amount"] == 24
    assert before["lifetime"] == 2.5
    assert before["process_material"]["properties"]["gravity"] == variant("Vector3", [0, -4, 0])
    assert before[draw]["class"] == props[draw]["class"]
    exec_ok(m2_editor, "particles/set", {"node_path": path, "properties": {"amount": 48, "lifetime": 4.0, "emitting": True}})
    editor_undo(m2_editor)
    assert exec_ok(m2_editor, "particles/info", {"node_path": path})["properties"] == before
    editor_redo(m2_editor)
    reopen(m2_editor)
    saved = exec_ok(m2_editor, "particles/info", {"node_path": path})["properties"]
    assert (saved["amount"], saved["lifetime"], saved["emitting"]) == (48, 4.0, True)
    assert saved["process_material"]["properties"]["initial_velocity_max"] == 5.0
    assert saved[draw]["class"] == props[draw]["class"]


@pytest.mark.parametrize("route,kind,properties,code", [
    ("particles/create", "GPUParticles2D", {"amount": 0}, "invalid_param"),
    ("particles/create", "GPUParticles3D", {"lifetime": -1}, "invalid_param"),
    ("particles/create", "GPUParticles2D", {"amount": 1.5}, "invalid_param"),
    ("particles/create", "GPUParticles3D", {"emitting": "yes"}, "invalid_param"),
    ("particles/create", "GPUParticles2D", {"process_material": resource("StandardMaterial3D")}, "invalid_param"),
    ("particles/create", "GPUParticles2D", {"texture": resource("BoxMesh")}, "invalid_param"),
    ("scene3d/create", "Camera3D", {"near": 20, "far": 10}, "invalid_param"),
    ("scene3d/create", "CSGBox3D", {"use_collision": True}, "permission_denied"),
    ("scene3d/create", "OmniLight3D", {"script": "x"}, "permission_denied"),
])
def test_invalid_construction_leaves_no_half_node(m2_editor, route, kind, properties, code):
    spatial(m2_editor)
    before = exec_ok(m2_editor, "scene/tree")
    assert exec_error(m2_editor, route, {"parent_path": "/root/Spatial", "name": "Bad", "type": kind, "properties": properties})["code"] == code
    assert exec_ok(m2_editor, "scene/tree") == before


def test_particle_set_rejects_entire_batch_without_material_or_amount_leak(m2_editor):
    spatial(m2_editor)
    exec_ok(m2_editor, "particles/create", {"parent_path": "/root/Spatial", "name": "GPU", "type": "GPUParticles3D", "properties": {"emitting": False}})
    path = "/root/Spatial/GPU"
    before = exec_ok(m2_editor, "particles/info", {"node_path": path})
    assert exec_error(m2_editor, "particles/set", {"node_path": path, "properties": {"amount": 99, "process_material": resource("ParticleProcessMaterial", gravity=variant("Vector3", [1, 2, 3])), "lifetime": 0}})["code"] == "invalid_param"
    assert exec_ok(m2_editor, "particles/info", {"node_path": path}) == before


def test_particle_runtime_observes_both_gpu_types_in_game_process(m3_running):
    from e2e.m3.conftest import reset_fixture
    reset_fixture(m3_running)
    for name, kind, amount, lifetime, draw in [
        ("GPU2D", "GPUParticles2D", 12, 2.5, "texture"),
        ("GPU3D", "GPUParticles3D", 18, 3.5, "draw_pass_1"),
    ]:
        result = exec_ok(m3_running, "runtime/particles/info", {"node_path": "/root/RuntimeMain/ParticlesFixture/" + name})
        assert (result["type"], result["amount"], result["lifetime"]) == (kind, amount, lifetime)
        assert result["emitting"] is False
        assert result["inside_tree"] is True
        assert result["process_frame"] > 0
        assert result["process_material"]["class"] == "ParticleProcessMaterial"
        assert result["properties"][draw]["class"] == ("GradientTexture2D" if name == "GPU2D" else "QuadMesh")
    assert exec_error(m3_running, "runtime/particles/info", {"node_path": "/root/RuntimeMain/ProbeTarget"})["code"] == "invalid_param"
    assert exec_error(m3_running, "runtime/particles/info", {"node_path": "/root/RuntimeMain/Missing"})["code"] == "not_found"


@pytest.mark.parametrize("payload", [
    {"type": "GridMap", "mesh_library": {"items": [{"id": 0, "mesh": resource("BoxMesh")}]}, "cells": [{"position": variant("Vector3i", [0, 0, 0]), "item": 0, "orientation": 24}]},
    {"type": "GridMap", "mesh_library": {"items": [{"id": 0, "mesh": resource("BoxMesh")}]}, "cells": [{"position": variant("Vector3i", [32768, 0, 0]), "item": 0}]},
    {"type": "MultiMeshInstance3D", "multimesh": {"mesh": resource("BoxMesh"), "instances": [{"transform": variant("Transform3D", [[1], [0, 0, 0]])}]}},
    {"type": "MultiMeshInstance3D", "multimesh": {"mesh": resource("BoxMesh"), "instances": [], "visible_instance_count": 1}},
])
def test_spatial_structured_boundary_rejections_leave_tree_unchanged(m2_editor, payload):
    spatial(m2_editor)
    before = exec_ok(m2_editor, "scene/tree")
    assert exec_error(m2_editor, "scene3d/create", {"parent_path": "/root/Spatial", "name": "Bad", **payload})["code"] == "invalid_param"
    assert exec_ok(m2_editor, "scene/tree") == before


@pytest.mark.parametrize("kind", ["GPUParticles2D", "GPUParticles3D"])
def test_particle_lower_valid_amount_and_fractional_lifetime(m2_editor, kind):
    spatial(m2_editor)
    created = exec_ok(m2_editor, "particles/create", {"parent_path": "/root/Spatial", "name": "One", "type": kind, "properties": {"amount": 1, "lifetime": 0.5, "emitting": False}})
    assert (created["properties"]["amount"], created["properties"]["lifetime"]) == (1, 0.5)
    before = exec_ok(m2_editor, "scene/tree")
    assert exec_error(m2_editor, "particles/create", {"parent_path": "/root/Spatial", "name": "One", "type": kind})["code"] == "conflict"
    assert exec_ok(m2_editor, "scene/tree") == before
