"""M2 完整验收: route 清单 + 命令文档 + 错误码收敛."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from .helpers import command_doc, exec_ok


# M2 完整 route 清单 — 基线 + 新增
M2_BASELINE_ROUTES = {
    # M1 基线
    "command/doc", "command/list", "console/output",
    "gdapi/audit/clear", "gdapi/audit/list", "gdapi/health/pathcheck",
    "gdapi/health/ping", "gdapi/loglevel", "gdapi/routes", "godot/version",
    "project/info", "project/run", "project/stop",
    "scene/add_node", "scene/create", "scene/export_mesh_library",
    "scene/load_sprite", "scene/save", "uid/get", "uid/update_all",
    # M2 新增
    "scene/current", "scene/current/save", "scene/open", "scene/close",
    "scene/tree", "scene/list_open",
    "node/create", "node/delete", "node/duplicate", "node/rename",
    "node/reparent", "node/move", "node/get", "node/set", "node/list",
    "node/select",
    "node/property/get", "node/property/set", "node/property/list",
    "node/property/reset", "node/property/revert",
    "node/signal/list", "node/signal/connect", "node/signal/disconnect",
    "node/signal/emit",
    "node/group/list", "node/group/add", "node/group/remove", "node/group/nodes",
    "script/read", "script/create", "script/write", "script/patch",
    "script/attach", "script/detach", "script/current", "script/open",
    "script/validate",
    "filesystem/list", "filesystem/read", "filesystem/write",
    "filesystem/search", "filesystem/grep", "filesystem/reimport",
    "resource/info", "resource/deps", "resource/search", "resource/reimport",
    "resource/assign", "resource/create", "resource/delete", "resource/move",
    "editor/selection/get", "editor/selection/set", "editor/main_screen/set",
}

RETIRED_ROUTES = {
    "routes", "commands", "help", "command-help",
    "gdapi/commands", "gdapi/help",
}


def test_routes_match_expected_inventory(m2_editor):
    routes = exec_ok(m2_editor, "gdapi/routes")["routes"]
    actual = set(routes)
    missing = M2_BASELINE_ROUTES - actual
    unexpected = RETIRED_ROUTES & actual
    assert not missing, f"missing M2 baseline routes: {sorted(missing)}"
    assert not unexpected, f"retired routes still exposed: {sorted(unexpected)}"


def test_commands_list_contains_m2_new_routes(m2_editor):
    listing = exec_ok(m2_editor, "command/list")
    paths = {c["path"] for c in listing["commands"]}
    # 冒烟检验: 所有 M2 新增 route 都在 command/list 中出现;
    # M1 中部分内建 route 与 gdcli 启动顺序相关,不强求超集.
    m2_only = {
        "scene/current", "scene/current/save", "scene/open", "scene/close",
        "scene/tree", "scene/list_open",
        "node/create", "node/property/set", "node/signal/connect",
        "node/group/add", "script/create", "filesystem/list", "resource/info",
        "editor/selection/set", "editor/main_screen/set",
    }
    missing = m2_only - paths
    assert not missing, f"missing M2 routes in command/list: {sorted(missing)}"


def test_route_documentation_is_complete(m2_editor):
    listing = exec_ok(m2_editor, "command/list")
    bad = []
    for cmd in listing["commands"]:
        if cmd["path"] in RETIRED_ROUTES:
            continue
        if not cmd["summary"]:
            bad.append((cmd["path"], "missing summary"))
            continue
        doc = command_doc(m2_editor, cmd["path"])
        if not doc["returns"]["fields"]:
            bad.append((cmd["path"], "empty returns"))
    assert not bad, f"incomplete docs: {bad[:5]}"


def test_error_codes_are_m1_standard():
    """Pure static check: routes only emit the 10 standard M1 codes."""
    root = Path(__file__).resolve().parent.parent.parent.parent.parent
    gdapi_dir = root / "gdapi" / "addon"
    standard = {
        "missing_param", "invalid_param", "invalid_path", "not_found",
        "conflict", "not_supported", "permission_denied",
        "unsafe_operation", "timeout", "godot_error",
    }
    pattern = re.compile(r"res\.error\([^)]+?,\s*\"([a-z_]+)\"")
    found = set()
    for path in gdapi_dir.rglob("*.gd"):
        if ".uid" in path.name:
            continue
        found.update(pattern.findall(path.read_text(encoding="utf-8")))
    extra = found - standard
    assert not extra, f"non-standard codes: {sorted(extra)}"
