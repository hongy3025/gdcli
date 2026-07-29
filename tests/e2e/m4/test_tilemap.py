"""TileMapLayer M4 route contracts."""

from .helpers import command_doc, editor_undo, exec_error, exec_ok, save_reopen


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
    exec_ok(m4_env, "scene/open", {"path": scene_path})
    changed = exec_ok(m4_env, "tilemap/cell/set", payload)
    assert changed["undoable"] is True
    assert exec_ok(m4_env, "tilemap/cell/get", {"layer_path": "TileMapLayer", "cell": {"x": 1, "y": 2}})["source_id"] == 0
    editor_undo(m4_env)
    assert exec_ok(m4_env, "tilemap/cell/get", {"layer_path": "TileMapLayer", "cell": {"x": 1, "y": 2}})["source_id"] == -1
    exec_ok(m4_env, "tilemap/cell/set", payload)
    save_reopen(m4_env, scene_path)
    assert exec_ok(m4_env, "tilemap/cell/get", {"layer_path": "TileMapLayer", "cell": {"x": 1, "y": 2}})["source_id"] == 0


def test_tilemap_rejects_invalid_cell_and_clear_without_force(m4_env):
    """Out-of-range coordinates and destructive clears must fail before mutation."""
    exec_ok(m4_env, "scene/open", {"path": "res://scenes/tilemap.tscn"})
    invalid = exec_error(m4_env, "tilemap/cell/set", {"layer_path": "TileMapLayer", "cell": {"x": 32768, "y": 0}, "source_id": 0, "atlas_coords": {"x": 0, "y": 0}})
    assert invalid["code"] == "invalid_param"
    unsafe = exec_error(m4_env, "tilemap/layer/clear", {"layer_path": "TileMapLayer"})
    assert unsafe["code"] == "unsafe_operation"


def test_tilemap_fill_and_used_cells_are_sorted(m4_env):
    """A fill must expose every authored cell in deterministic coordinate order."""
    exec_ok(m4_env, "scene/open", {"path": "res://scenes/tilemap.tscn"})
    result = exec_ok(
        m4_env,
        "tilemap/rect/fill",
        {
            "layer_path": "TileMapLayer",
            "from": {"x": 1, "y": 1},
            "to": {"x": 2, "y": 2},
            "source_id": 0,
            "atlas_coords": {"x": 0, "y": 0},
        },
    )
    assert result["count"] == 4
    cells = exec_ok(m4_env, "tilemap/used_cells", {"layer_path": "TileMapLayer"})["cells"]
    assert cells == [{"x": 1, "y": 1}, {"x": 1, "y": 2}, {"x": 2, "y": 1}, {"x": 2, "y": 2}]
