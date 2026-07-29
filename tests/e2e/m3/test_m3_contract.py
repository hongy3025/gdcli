"""M3 完整验收: 路线图 manifest + 文档一致性 + 无残留周期"""

from __future__ import annotations

import re
from pathlib import Path

from .conftest import (
    command_doc,
    exec_error,
    exec_ok,
)


EXPECTED_RUNTIME_ROUTES = (
    {"runtime/status", "runtime/scene/tree"}
    | {f"runtime/node/{name}" for name in ["info", "get", "set", "call", "find", "remove", "reparent", "create", "duplicate", "rename"]}
    | {f"runtime/input/{name}" for name in ["key", "mouse", "gamepad", "touch", "action", "sequence"]}
    | {f"runtime/screenshot/{name}" for name in ["viewport", "camera", "frames"]}
    | {f"runtime/log/{name}" for name in ["read", "clear"]}
    | {f"runtime/assert/{name}" for name in ["condition", "node_exists", "property_equals", "signal_received"]}
    | {f"runtime/signal/{name}" for name in ["connect", "disconnect", "emit", "await"]}
    | {f"runtime/debug/{name}" for name in ["performance", "monitors", "errors", "breakpoints"]}
)


def test_runtime_manifest_match(m3_editor):
    routes = set(exec_ok(m3_editor, "gdapi/routes")["routes"])
    assert len({route for route in routes if route.startswith("runtime/")}) == 35
    missing = EXPECTED_RUNTIME_ROUTES - routes
    assert not missing, f"missing runtime routes: {sorted(missing)}"
    unexpected_runtime = {r for r in routes if r.startswith("runtime/")} - EXPECTED_RUNTIME_ROUTES
    assert not unexpected_runtime, f"unexpected runtime routes: {sorted(unexpected_runtime)}"


def test_runtime_manifest_has_no_aliases(m3_editor):
    routes = [route for route in exec_ok(m3_editor, "gdapi/routes")["routes"] if route.startswith("runtime/")]
    assert len(routes) == len(set(routes)) == 35


def test_runtime_route_documentation_is_complete(m3_editor):
    bad = []
    for route in sorted(EXPECTED_RUNTIME_ROUTES):
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
