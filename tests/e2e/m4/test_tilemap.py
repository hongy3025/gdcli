"""TileMapLayer M4 route contracts."""

from .helpers import command_doc, editor_undo, exec_error, exec_ok, save_scene, select_domain


TILEMAP_ROUTES = {
    "tilemap/info", "tilemap/cell/get", "tilemap/cell/set",
    "tilemap/rect/fill", "tilemap/layer/clear", "tilemap/used_cells",
}


def test_tilemap_routes_are_discoverable_and_documented(m4_env):
    """Removing any TileMapLayer command breaks the public M4 contract."""
    routes = set(exec_ok(m4_env, "gdapi/routes")["routes"])
    assert TILEMAP_ROUTES <= routes
    for route in sorted(TILEMAP_ROUTES):
        assert command_doc(m4_env, route)["summary"]


def test_tilemap_cell_set_is_undoable_and_persists(m4_env):
    """Dropping the cell UndoRedo action would leave the authored tile after undo."""
    scene_path = "res://scenes/tilemap.tscn"
    payload = {
        "layer_path": "TileMapLayer",
        "cell": {"x": 1, "y": 2},
        "source_id": 0,
        "atlas_coords": {"x": 0, "y": 0},
    }
    select_domain(m4_env, "tilemap")
    baseline = exec_ok(m4_env, "tilemap/cell/get", {"layer_path": "TileMapLayer", "cell": payload["cell"]})
    changed = exec_ok(m4_env, "tilemap/cell/set", payload)
    assert changed["undoable"] is True
    assert exec_ok(m4_env, "tilemap/cell/get", {"layer_path": "TileMapLayer", "cell": {"x": 1, "y": 2}})["source_id"] == 0
    editor_undo(m4_env)
    assert exec_ok(m4_env, "tilemap/cell/get", {"layer_path": "TileMapLayer", "cell": payload["cell"]}) == baseline
    exec_ok(m4_env, "tilemap/cell/set", payload)
    content = save_scene(m4_env, scene_path)
    assert "tile_map_data = PackedByteArray(" in content
    assert exec_ok(m4_env, "tilemap/cell/get", {"layer_path": "TileMapLayer", "cell": {"x": 1, "y": 2}})["source_id"] == 0


def test_tilemap_rejects_invalid_cell(m4_env):
    """Out-of-range coordinates must fail before mutation."""
    select_domain(m4_env, "tilemap")
    invalid = exec_error(m4_env, "tilemap/cell/set", {"layer_path": "TileMapLayer", "cell": {"x": 32768, "y": 0}, "source_id": 0, "atlas_coords": {"x": 0, "y": 0}})
    assert invalid["code"] == "invalid_param"


def test_tilemap_clear_without_force_succeeds(m4_env):
    """Clear must commit immediately, not require force."""
    select_domain(m4_env, "tilemap")
    layer = exec_ok(m4_env, "node/create", {
        "parent_path": "/root/TilemapDomain", "name": "ClearContractLayer", "type": "TileMapLayer",
    })["node_path"]
    exec_ok(m4_env, "node/property/set", {
        "node_path": layer, "property": "tile_set",
        "value": {"type": "Resource", "value": "res://resources/tile_set.tres"},
    })
    exec_ok(
        m4_env,
        "tilemap/cell/set",
        {"layer_path": layer, "cell": {"x": 0, "y": 0}, "source_id": 0, "atlas_coords": {"x": 0, "y": 0}},
    )
    before = exec_ok(m4_env, "tilemap/used_cells", {"layer_path": layer})["cells"]
    cleared = exec_ok(m4_env, "tilemap/layer/clear", {"layer_path": layer})
    assert cleared["changed"] is True
    assert cleared["undoable"] is True
    assert exec_ok(m4_env, "tilemap/used_cells", {"layer_path": layer})["cells"] == []
    editor_undo(m4_env)
    assert exec_ok(m4_env, "tilemap/used_cells", {"layer_path": layer})["cells"] == before


def test_tilemap_fill_and_used_cells_are_sorted(m4_env):
    """A fill must expose every authored cell in deterministic coordinate order."""
    select_domain(m4_env, "tilemap")
    before = exec_ok(m4_env, "tilemap/used_cells", {"layer_path": "TileMapLayer"})["cells"]
    result = exec_ok(
        m4_env,
        "tilemap/rect/fill",
        {
            "layer_path": "TileMapLayer",
            "from": {"x": 20, "y": 20},
            "to": {"x": 21, "y": 21},
            "source_id": 0,
            "atlas_coords": {"x": 0, "y": 0},
        },
    )
    assert result["count"] == 4
    cells = exec_ok(m4_env, "tilemap/used_cells", {"layer_path": "TileMapLayer"})["cells"]
    authored = {(20, 20), (20, 21), (21, 20), (21, 21)}
    expected = {(cell["x"], cell["y"]) for cell in before} | authored
    assert cells == [{"x": x, "y": y} for x, y in sorted(expected)]
