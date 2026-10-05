"""Run native suites inside the ongoing shared Godot editor session."""

import pytest

from conftest import run_native_suite
from e2e.shared_fixture import gdcli_call


@pytest.mark.parametrize(
    "script",
    [
        "res://tests/test_request.gd",
        "res://tests/test_route_doc.gd",
        "res://tests/test_router.gd",
        "res://tests/test_path_guard.gd",
        "res://tests/test_variant_codec.gd",
        "res://tests/test_deferred_task_registry.gd",
        "res://tests/test_eval_service.gd",
        "res://tests/test_runtime_protocol.gd",
        "res://tests/test_runtime_broker.gd",
        "res://tests/test_runtime_ring_buffer.gd",
        "res://tests/test_runtime_reparent.gd",
        "res://tests/test_runtime_node_ops.gd",
        "res://tests/test_runtime_input_ops.gd",
        "res://tests/test_runtime_debugger_plugin.gd",
        "res://tests/test_runtime_transport_file_probe.gd",
        "res://tests/test_runtime_transport_file_editor.gd",
        "res://tests/test_runtime_transport_integration.gd",
        "res://tests/test_runtime_route.gd",
        "res://tests/test_runtime_capture_ops.gd",
        "res://tests/test_audit_log_redaction.gd",
        "res://tests/test_audit_retention.gd",
        "res://tests/test_response_send.gd",
        "res://tests/test_network_target_guard.gd",
        "res://tests/test_scene_editor_tab_mapping.gd",
    ],
)
def test_gdscript_unit_suite(e2e_editor, script):
    result = run_native_suite(e2e_editor, script)
    # Even a failed suite must leave the same editor serving real CLI requests.
    assert gdcli_call(e2e_editor, "gdapi/health/ping")["ok"] is True
    assert result["ok"] is True, result
    assert result["failed"] == 0, result


def test_native_runner_rejects_non_suite_without_breaking_editor(e2e_editor):
    result = run_native_suite(e2e_editor, "res://addons/gdapi/runtime/path_guard.gd")
    assert result["ok"] is False, result
    assert result["passed"] == 0 and result["failed"] == 1, result
    assert gdcli_call(e2e_editor, "gdapi/health/ping")["ok"] is True
