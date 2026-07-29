"""M4 bridge registration is public while M3 runtime routes stay closed."""

from .conftest import command_doc, exec_ok


M4_ROUTES = {
    "animation/create", "animation/delete", "animation/play", "animation/stop",
    "animation/track/add", "animation/track/remove", "animation/key/add", "animation/key/remove",
    "animation_tree/state/add", "animation_tree/transition/add", "animation_tree/blend/set",
    "tilemap/info", "tilemap/cell/get", "tilemap/cell/set", "tilemap/rect/fill", "tilemap/layer/clear", "tilemap/used_cells",
    "material/create", "material/info", "material/set", "material/assign", "material/duplicate", "material/save",
    "shader/read", "shader/write", "shader/uniforms", "shader/material/create", "shader/param/set",
    "audio/bus/list", "audio/bus/add", "audio/bus/remove", "audio/player/create", "audio/play", "audio/stop",
    "ui/control/set_anchor", "ui/text/set", "ui/layout/build",
    "theme/create", "theme/color/set", "theme/constant/set", "theme/font_size/set", "theme/stylebox/set",
    "physics/body/create", "physics/shape/create", "physics/layer/set", "physics/raycast", "physics/joint/create",
    "navigation/region/list", "navigation/mesh/bake", "navigation/path/get", "navigation/agent/target",
}


def test_m4_routes_are_exactly_discoverable_and_documented(m4_env):
    """M4 exposes the roadmap's exact public set with complete route docs."""
    routes = set(exec_ok(m4_env, "gdapi/routes")["routes"])
    assert {route for route in routes if _is_m4(route)} == M4_ROUTES
    for route in sorted(M4_ROUTES):
        doc = command_doc(m4_env, route)
        assert doc["summary"]
        assert doc["returns"]["fields"]


def _is_m4(route: str) -> bool:
    return route.split("/", 1)[0] in {
        "animation", "animation_tree", "tilemap", "material", "shader",
        "audio", "ui", "theme", "physics", "navigation",
    }


def test_m4_bridge_does_not_add_runtime_routes(m4_env):
    """Publishing an M4 bridge under runtime/** would violate the M3 contract."""
    routes = set(exec_ok(m4_env, "gdapi/routes")["routes"])
    runtime_routes = {route for route in routes if route.startswith("runtime/")}
    assert len(runtime_routes) == 35
