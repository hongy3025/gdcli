"""Run GDScript unit test suites through Godot --headless --script."""

from pathlib import Path

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
        editor=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "0 failed" in result.stdout


def test_runtime_debugger_plugin_registered_in_lifecycle():
    plugin_source = Path(__file__).resolve().parent.parent.parent / "gdapi" / "addon" / "plugin.gd"
    source = plugin_source.read_text(encoding="utf-8")
    register = "add_debugger_plugin(_runtime_debugger_plugin)"
    remove = "remove_debugger_plugin(_runtime_debugger_plugin)"
    assert register in source
    assert remove in source
    assert source.index("_runtime_debugger_plugin.setup(_runtime_broker)") < source.index(register)
