"""M2 acceptance: route inventory, command listing, and standardized error codes."""

from __future__ import annotations

import re
import sys
from pathlib import Path

import pytest

_REPO_ROOT_CANDIDATE = Path(__file__).resolve().parents[2]
_TESTS_DIR = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT_CANDIDATE) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT_CANDIDATE))
if str(_TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(_TESTS_DIR))

from .helpers import exec_ok


# gdapi addon 扫描 autoload routes/ 下所有 .gd 文件, 因此所有 milestone 的 route
# 都会在运行时可见. 本清单仅校验 M1+M2 baseline route 不缺失, 不要求 strict 超集.
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



def test_routes_match_expected_inventory(m2_editor):
    routes = exec_ok(m2_editor, "gdapi/routes")["routes"]
    actual = set(routes)
    missing = M2_BASELINE_ROUTES - actual
    assert not missing, f"missing M2 baseline routes: {sorted(missing)}"


def test_commands_list_contains_m2_baseline_routes(m2_editor):
    listing = exec_ok(m2_editor, "command/list")
    paths = {command["path"] for command in listing["commands"]}
    missing = M2_BASELINE_ROUTES - paths
    assert not missing, f"missing M2 routes in command/list: {sorted(missing)}"



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
