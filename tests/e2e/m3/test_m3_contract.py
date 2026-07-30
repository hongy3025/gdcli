"""M3 完整验收: 路线图 manifest + 文档一致性 + 无残留周期"""

from __future__ import annotations

import re
from pathlib import Path

from e2e.route_manifests import M3_RUNTIME_ROUTES

from .conftest import (
    command_doc,
    exec_error,
    exec_ok,
)


def test_runtime_manifest_match(m3_editor):
    routes = set(exec_ok(m3_editor, "gdapi/routes")["routes"])
    runtime_routes = {route for route in routes if route.startswith("runtime/")}
    assert M3_RUNTIME_ROUTES <= runtime_routes
    assert runtime_routes - M3_RUNTIME_ROUTES == {"runtime/eval"}
    missing = M3_RUNTIME_ROUTES - routes
    assert not missing, f"missing runtime routes: {sorted(missing)}"
    unexpected_runtime = runtime_routes - (M3_RUNTIME_ROUTES | {"runtime/eval"})
    assert not unexpected_runtime, f"unexpected runtime routes: {sorted(unexpected_runtime)}"


def test_runtime_manifest_has_no_aliases(m3_editor):
    runtime_routes = sorted(
        route for route in exec_ok(m3_editor, "gdapi/routes")["routes"]
        if route.startswith("runtime/")
    )
    assert runtime_routes == sorted(M3_RUNTIME_ROUTES | {"runtime/eval"})


def test_runtime_route_documentation_is_complete(m3_editor):
    bad = []
    for route in sorted(M3_RUNTIME_ROUTES):
        doc = command_doc(m3_editor, route)
        if not doc.get("summary"):
            bad.append((route, "missing summary"))
            continue
        if not doc["returns"]["fields"]:
            bad.append((route, "empty returns"))
        if doc.get("params") and not doc.get("examples"):
            bad.append((route, "no examples"))
    assert not bad, f"incomplete docs: {bad[:10]}"


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
