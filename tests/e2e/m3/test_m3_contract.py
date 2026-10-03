"""Runtime failure diagnostics remain available across capability additions."""

from __future__ import annotations


from .conftest import exec_error




def test_failed_cli_diagnostics_include_runtime_context(m3_editor):
    error = exec_error(m3_editor, "runtime/node/get", {
        "node_path": "RuntimeMain/ProbeTarget",
        "property": "counter",
    })
    diagnostics = error.get("diagnostics", {})
    assert {
        "command",
        "exit_code",
        "stdout",
        "stderr",
        "runtime_status",
        "godot_log_tail",
    } <= set(diagnostics)
