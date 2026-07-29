"""2D navigation region and bake M4 route contracts."""

from .helpers import command_doc, exec_error, exec_ok, run_domain, save_reopen, stop_domain


NAVIGATION_ROUTES = {
    "navigation/region/list", "navigation/mesh/bake",
    "navigation/path/get", "navigation/agent/target",
}


def test_navigation_routes_are_discoverable_and_documented(m4_env):
    routes = set(exec_ok(m4_env, "gdapi/routes")["routes"])
    assert NAVIGATION_ROUTES <= routes
    for route in sorted(NAVIGATION_ROUTES):
        assert command_doc(m4_env, route)["summary"]


def test_navigation_regions_bake_to_project_local_resource_with_force(m4_env):
    exec_ok(m4_env, "scene/open", {"path": "res://scenes/navigation.tscn"})
    regions = exec_ok(m4_env, "navigation/region/list")
    assert regions["regions"] == [{
        "path": "/root/NavigationDomain/Region",
        "class": "NavigationRegion2D",
        "map_rid": regions["regions"][0]["map_rid"],
    }]

    target = "res://navigation/baked_test.tres"
    baked = exec_ok(m4_env, "navigation/mesh/bake", {
        "region_path": "/root/NavigationDomain/Region", "path": target,
    })
    assert baked["undoable"] is False
    assert exec_ok(m4_env, "resource/info", {"path": target})["class"] == "NavigationPolygon"
    assert exec_error(m4_env, "navigation/mesh/bake", {
        "region_path": "/root/NavigationDomain/Region", "path": target,
    })["code"] == "unsafe_operation"
    assert exec_ok(m4_env, "navigation/mesh/bake", {
        "region_path": "/root/NavigationDomain/Region", "path": target, "force": True,
    })["path"] == target

    save_reopen(m4_env, "res://scenes/navigation.tscn")
    assert exec_ok(m4_env, "resource/info", {"path": target})["class"] == "NavigationPolygon"


def test_navigation_runtime_round_trip_is_2d_and_cleans_up(m4_env):
    run_domain(m4_env, "navigation")
    path = exec_ok(m4_env, "navigation/path/get", {
        "region_path": "/root/NavigationDomain/Region",
        "from": {"x": 0, "y": 0}, "to": {"x": 100, "y": 0},
    })
    assert path["points"]
    assert exec_ok(m4_env, "navigation/agent/target", {
        "agent_path": "/root/NavigationDomain/Agent", "target": {"x": 100, "y": 0},
    })["target"] == {"type": "Vector2", "value": [100.0, 0.0]}
    assert exec_error(m4_env, "navigation/path/get", {
        "region_path": "/root/NavigationDomain/Region",
        "from": {"x": 0, "y": 0, "z": 0}, "to": {"x": 1, "y": 0},
    })["code"] == "not_supported"
    stop_domain(m4_env, "navigation")
    assert exec_error(m4_env, "navigation/path/get", {
        "region_path": "/root/NavigationDomain/Region",
        "from": {"x": 0, "y": 0}, "to": {"x": 1, "y": 0},
    })["code"] in {"conflict", "not_connected", "timeout"}
