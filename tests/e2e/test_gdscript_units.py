"""Run GDScript unit test suites through Godot --headless --script."""

import pytest

from conftest import run_godot_script


@pytest.mark.skip(reason="GDScript unit test files not in e2e_project fixture; needs fixture_project/tests/ copy")
@pytest.mark.parametrize(
    "script",
    [
        "res://tests/test_request.gd",
        "res://tests/test_route_doc.gd",
        "res://tests/test_router.gd",
        "res://tests/test_path_guard.gd",
        "res://tests/test_variant_codec.gd",
        "res://tests/test_capability_policy.gd",
        "res://tests/test_deferred_task_registry.gd",
        "res://tests/test_eval_service.gd",
        "res://tests/test_runtime_protocol.gd",
        "res://tests/test_runtime_broker.gd",
        "res://tests/test_runtime_ring_buffer.gd",
        "res://tests/test_runtime_reparent.gd",
        "res://tests/test_runtime_transport_file_probe.gd",
        "res://tests/test_runtime_transport_file_editor.gd",
        "res://tests/test_runtime_transport_integration.gd",
        "res://tests/test_runtime_route.gd",
        "res://tests/test_runtime_node_ops.gd",
        "res://tests/test_runtime_input_ops.gd",
        "res://tests/test_runtime_capture_ops.gd",
        "res://tests/test_network_target_guard.gd",
        "res://tests/test_bulk_deploy_service.gd",
        ],
)
def test_gdscript_unit_suite(e2e_editor, script):
    result = run_godot_script(e2e_editor, script)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "0 failed" in result.stdout


@pytest.mark.skip(reason="GDScript unit test files not in e2e_project fixture; needs fixture_project/tests/ copy")
def test_runtime_debugger_plugin_suite(e2e_editor):
    result = run_godot_script(
        e2e_editor,
        "res://tests/test_runtime_debugger_plugin.gd",
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "0 failed" in result.stdout
