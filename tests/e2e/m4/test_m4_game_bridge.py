"""M4 public bridge routes execute through the persistent RuntimeMain game."""

from .helpers import exec_ok


def test_physics_raycast_round_trip_requires_running_domain(m3_running):
    """Deleting runtime World2D query handling must turn the expected hit into a miss/error."""
    hit = exec_ok(m3_running, "physics/raycast", {
        "from": {"x": 0, "y": 100},
        "to": {"x": 320, "y": 100},
    })
    assert hit["hit"] is True
    assert hit["collider_path"] == "/root/RuntimeMain/PhysicsDomain/Floor"


def test_navigation_path_and_agent_target_round_trip(m3_running):
    """Removing the M4 navigation operations must break path/target evidence."""
    path = exec_ok(m3_running, "navigation/path/get", {
        "region_path": "/root/RuntimeMain/NavigationDomain/Region",
        "from": {"x": 0, "y": 0},
        "to": {"x": 100, "y": 0},
    })
    assert len(path["points"]) >= 2
    target = exec_ok(m3_running, "navigation/agent/target", {
        "agent_path": "/root/RuntimeMain/NavigationDomain/Agent",
        "target": {"x": 90, "y": 10},
    })
    assert target["changed"] is True
    assert target["target"] == {"type": "Vector2", "value": [90.0, 10.0]}
