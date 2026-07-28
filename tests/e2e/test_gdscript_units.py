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
        "res://tests/test_runtime_protocol.gd",
        "res://tests/test_runtime_broker.gd",
        "res://tests/test_runtime_ring_buffer.gd",
        "res://tests/test_runtime_transport_file_probe.gd",
        "res://tests/test_runtime_transport_file_editor.gd",
        "res://tests/test_runtime_transport_integration.gd",
        "res://tests/test_runtime_route.gd",
    ],
)
def test_gdscript_unit_suite(godot_env, script):
    result = run_godot_script(godot_env, script)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "0 failed" in result.stdout


def test_runtime_debugger_plugin_suite(godot_env):
    result = run_godot_script(
        godot_env,
        "res://tests/test_runtime_debugger_plugin.gd",
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "0 failed" in result.stdout
