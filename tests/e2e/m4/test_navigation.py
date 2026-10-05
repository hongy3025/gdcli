"""2D navigation region and bake M4 route contracts."""

from pathlib import Path

from e2e.m3.conftest import wait_stopped

from .helpers import command_doc, editor_undo, exec_error, exec_ok, select_domain


NAVIGATION_ROUTES = {
    "navigation/region/list", "navigation/mesh/bake",
    "navigation/path/get", "navigation/agent/target",
}

REGION = "/root/NavigationDomain/Region"
EMPTY_REGION = "/root/NavigationDomain/EmptyRegion"
RUNTIME_REGION = "/root/RuntimeMain/NavigationDomain/Region"


def test_navigation_routes_are_discoverable_and_documented(m4_env):
    routes = set(exec_ok(m4_env, "gdapi/routes")["routes"])
    assert NAVIGATION_ROUTES <= routes
    for route in sorted(NAVIGATION_ROUTES):
        assert command_doc(m4_env, route)["summary"]


def _polygon_from_disk(env, path):
    """Load a saved NavigationPolygon through resource/info into counted metrics."""
    info = exec_ok(env, "resource/info", {"path": path})
    properties = info["properties"]
    return {
        "class": info["class"],
        "vertices": properties["vertices"],
        "vertex_count": properties["vertices"].count("("),
        "polygon_count": len(properties["polygons"]),
    }


def test_navigation_regions_bake_to_project_local_resource(m4_env):
    select_domain(m4_env, "navigation")
    before = exec_ok(m4_env, "navigation/region/list")["regions"]
    regions = {region["path"]: region for region in before}
    assert regions[EMPTY_REGION]["vertex_count"] == 0
    assert regions[REGION]["vertex_count"] == 4
    assert regions[REGION]["polygon_count"] == 1

    target = "res://navigation/baked_test.tres"
    baked = exec_ok(m4_env, "navigation/mesh/bake", {
        "region_path": REGION, "path": target,
    })
    assert baked["path"] == target
    assert baked["undoable"] is False

    # 真烘焙：产物由源几何（障碍物）生成，而非复制源多边形的 4 顶点单多边形。
    stored = _polygon_from_disk(m4_env, target)
    assert stored["class"] == "NavigationPolygon"
    assert baked["vertex_count"] == stored["vertex_count"] == 8
    assert baked["polygon_count"] == stored["polygon_count"] == 4

    # 烘焙不改写当前场景中的源多边形。
    assert exec_ok(m4_env, "navigation/region/list")["regions"] == before

    overwritten = exec_ok(m4_env, "navigation/mesh/bake", {
        "region_path": REGION, "path": target,
    })
    assert overwritten["path"] == target

    reloaded = _polygon_from_disk(m4_env, target)
    assert reloaded["class"] == "NavigationPolygon"
    assert reloaded["vertex_count"] == 8
    assert reloaded["polygon_count"] == 4


def test_navigation_bake_reflects_current_source_geometry(m4_env):
    select_domain(m4_env, "navigation")
    before_path = "res://navigation/source_before.tres"
    after_path = "res://navigation/source_after.tres"

    before = exec_ok(m4_env, "navigation/mesh/bake", {
        "region_path": REGION, "path": before_path,
    })
    before_info = _polygon_from_disk(m4_env, before_path)
    assert before["polygon_count"] == before_info["polygon_count"] == 4

    # Change only this scenario's obstacle edit, then undo precisely that edit.
    shape_path = REGION + "/Obstacle/ObstacleShape"
    baseline = exec_ok(m4_env, "node/property/get", {
        "node_path": shape_path, "property": "scale",
    })["value"]
    exec_ok(m4_env, "node/property/set", {
        "node_path": shape_path, "property": "scale",
        "value": {"type": "Vector2", "value": [6, 1]},
    })
    try:
        after = exec_ok(m4_env, "navigation/mesh/bake", {
            "region_path": REGION, "path": after_path,
        })
        after_info = _polygon_from_disk(m4_env, after_path)
        assert after["polygon_count"] == after_info["polygon_count"] == 3
        assert after_info["polygon_count"] != before_info["polygon_count"]
        assert after_info["vertices"] != before_info["vertices"]
    finally:
        editor_undo(m4_env)
    assert exec_ok(m4_env, "node/property/get", {
        "node_path": shape_path, "property": "scale",
    })["value"] == baseline


def test_navigation_bake_failures_leave_no_output(m4_env):
    project = Path(m4_env["project"])
    select_domain(m4_env, "navigation")

    wrong_extension = exec_error(m4_env, "navigation/mesh/bake", {
        "region_path": REGION, "path": "res://navigation/bake_wrong.txt",
    })
    assert wrong_extension["code"] == "invalid_path"
    assert not (project / "navigation" / "bake_wrong.txt").exists()

    bad_region_path = exec_error(m4_env, "navigation/mesh/bake", {
        "region_path": 7, "path": "res://navigation/never.tres",
    })
    assert bad_region_path["code"] == "invalid_param"
    assert not (project / "navigation" / "never.tres").exists()

    missing_region = exec_error(m4_env, "navigation/mesh/bake", {
        "region_path": "/root/NavigationDomain/Missing",
        "path": "res://navigation/missing.tres",
    })
    assert missing_region["code"] == "not_found"
    assert not (project / "navigation" / "missing.tres").exists()

    empty_bake = exec_error(m4_env, "navigation/mesh/bake", {
        "region_path": EMPTY_REGION, "path": "res://navigation/empty_bake.tres",
    })
    assert empty_bake["code"] == "godot_error"
    assert not (project / "navigation" / "empty_bake.tres").exists()


def test_navigation_runtime_round_trip_is_2d(m3_running):
    m4_env = m3_running
    path = exec_ok(m4_env, "navigation/path/get", {
        "region_path": RUNTIME_REGION,
        "from": {"x": 0, "y": 0}, "to": {"x": 100, "y": 0},
    })
    assert path["points"]
    assert exec_ok(m4_env, "navigation/agent/target", {
        "agent_path": "/root/RuntimeMain/NavigationDomain/Agent", "target": {"x": 100, "y": 0},
    })["target"] == {"type": "Vector2", "value": [100.0, 0.0]}
    assert exec_error(m4_env, "navigation/path/get", {
        "region_path": RUNTIME_REGION,
        "from": {"x": 0, "y": 0, "z": 0}, "to": {"x": 1, "y": 0},
    })["code"] == "not_supported"


def test_navigation_runtime_queries_require_running_game(m3_running):
    """Stopping the actual shared game must reject subsequent runtime queries."""
    exec_ok(m3_running, "project/stop")
    m3_running["game_attached"] = False
    assert wait_stopped(m3_running, timeout=15.0)["pending"] == 0
    assert exec_error(m3_running, "navigation/path/get", {
        "region_path": RUNTIME_REGION,
        "from": {"x": 0, "y": 0}, "to": {"x": 1, "y": 0},
    })["code"] in {"conflict", "not_connected", "timeout"}
