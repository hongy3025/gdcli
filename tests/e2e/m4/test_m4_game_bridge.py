"""M4 public bridge routes execute only through a connected game probe."""

from .helpers import exec_ok, run_domain, stop_domain


def test_physics_raycast_round_trip_requires_running_domain(m4_env):
    """Deleting runtime World2D query handling must turn the expected hit into a miss/error."""
    run_domain(m4_env, "physics")
    try:
        hit = exec_ok(m4_env, "physics/raycast", {
            "from": {"x": 0, "y": 100},
            "to": {"x": 320, "y": 100},
        })
        assert hit["hit"] is True
        assert hit["collider_path"] == "/root/PhysicsDomain/Floor"
    finally:
        stop_domain(m4_env, "physics")


def test_navigation_path_and_agent_target_round_trip(m4_env):
    """Removing the M4 navigation operations must break path/target evidence."""
    run_domain(m4_env, "navigation")
    try:
        path = exec_ok(m4_env, "navigation/path/get", {
            "region_path": "/root/NavigationDomain/Region",
            "from": {"x": 0, "y": 0},
            "to": {"x": 100, "y": 0},
        })
        assert len(path["points"]) >= 2
        target = exec_ok(m4_env, "navigation/agent/target", {
            "agent_path": "/root/NavigationDomain/Agent",
            "target": {"x": 100, "y": 0},
        })
        assert target["changed"] is True
        assert target["target"] == {"type": "Vector2", "value": [100.0, 0.0]}
    finally:
        stop_domain(m4_env, "navigation")
