"""M4 bridge registration is public while M3 runtime routes stay closed."""

from .conftest import command_doc, exec_ok
from e2e.route_manifests import M3_RUNTIME_ROUTES, M4_ROUTES


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
    assert not (M4_ROUTES & runtime_routes)
    assert runtime_routes == M3_RUNTIME_ROUTES | {"runtime/eval"}
