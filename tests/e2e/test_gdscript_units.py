"""Run GDScript unit test suites through Godot --headless --script."""

import pytest

from conftest import run_godot_script


@pytest.mark.parametrize(
    "script",
    [
        "res://tests/test_request.gd",
        "res://tests/test_route_doc.gd",
        "res://tests/test_router.gd",
        "res://tests/test_path_guard.gd",
        "res://tests/test_variant_codec.gd",
    ],
)
def test_gdscript_unit_suite(godot_env, script):
    result = run_godot_script(godot_env, script)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "0 failed" in result.stdout