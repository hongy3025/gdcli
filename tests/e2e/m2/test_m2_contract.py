"""M2 acceptance: native route inventory and command listing."""

from __future__ import annotations

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


