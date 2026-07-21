"""M1 路由基础设施端到端验证。

需要 Godot 编辑器可用。运行方式：
  uv run pytest tests/e2e/test_m1_smoke.py -v

跳过：
  uv run pytest tests/e2e/test_m1_smoke.py -v -k "not e2e"
"""
import json
import subprocess

import pytest

from conftest import gdcli_json, gdcli_expect_fail


pytestmark = pytest.mark.e2e

# 当前 gdapi 公开路由集合（与 gdapi/routes + command/list 返回结果一致）
EXPECTED_ROUTES = {
    "command/doc",
    "command/list",
    "console/output",
    "gdapi/audit/clear",
    "gdapi/audit/list",
    "gdapi/health/pathcheck",
    "gdapi/health/ping",
    "gdapi/loglevel",
    "gdapi/routes",
    "godot/version",
    "project/info",
    "project/run",
    "project/stop",
    "scene/add_node",
    "scene/create",
    "scene/export_mesh_library",
    "scene/load_sprite",
    "scene/save",
    "uid/get",
    "uid/update_all",
}


def _exec(env: dict, route: str, data: str | None = None) -> dict:
    args = ["exec", route, "--project", str(env["fixture"])]
    if data is not None:
        args += ["--data", data]
    return gdcli_json(env, *args)


def _exec_fail(env: dict, route: str, data: str | None = None) -> int:
    args = ["exec", route, "--project", str(env["fixture"])]
    if data is not None:
        args += ["--data", data]
    return gdcli_expect_fail(env, *args)


# ── 连通性 ──────────────────────────────────────────────

class TestConnectivity:
    def test_ping(self, godot_env):
        """gdcli exec gdapi/health/ping 返回 ok:true"""
        resp = _exec(godot_env, "gdapi/health/ping")
        assert resp["ok"] is True

    def test_ping_contains_editor_version(self, godot_env):
        """gdapi/health/ping 响应包含 editor_version"""
        resp = _exec(godot_env, "gdapi/health/ping")
        assert "editor_version" in resp

    def test_ping_contains_gdapi_version(self, godot_env):
        """gdapi/health/ping 响应包含 gdapi_version"""
        resp = _exec(godot_env, "gdapi/health/ping")
        assert "gdapi_version" in resp


# ── 路由命名空间 ─────────────────────────────────────────

class TestRouteNamespace:
    def test_routes_match_current_public_surface(self, godot_env):
        """gdapi/routes 返回的 route 集合与 EXPECTED_ROUTES 完全一致"""
        resp = _exec(godot_env, "gdapi/routes")
        assert resp["ok"] is True
        assert resp["routes"] == sorted(EXPECTED_ROUTES)

    def test_removed_aliases_are_not_exposed(self, godot_env):
        """旧别名 routes / commands / help / command-help 不再暴露"""
        for removed in ("routes", "commands", "help", "command-help"):
            _exec_fail(godot_env, removed)


# ── 命令元数据 ─────────────────────────────────────────

class TestCommandsMetadata:
    def test_commands_list_matches_route_surface(self, godot_env):
        """command/list 返回的 path 集合与 EXPECTED_ROUTES 完全一致"""
        resp = _exec(godot_env, "command/list")
        assert resp["ok"] is True
        paths = [c["path"] for c in resp["commands"]]
        assert sorted(paths) == sorted(EXPECTED_ROUTES)


# ── 路径安全 ─────────────────────────────────────────

class TestPathGuard:
    def test_relative_path_normalized(self, godot_env):
        """相对路径被规范化为 res://"""
        resp = _exec(godot_env, "gdapi/health/pathcheck",
                     '{"path":"scenes/test.tscn","mode":"read"}')
        assert resp["path"] == "res://scenes/test.tscn"
        assert resp["ok"] is True

    def test_res_path_accepted(self, godot_env):
        """res:// 路径直接接受"""
        resp = _exec(godot_env, "gdapi/health/pathcheck",
                     '{"path":"res://scenes/test.tscn","mode":"read"}')
        assert resp["path"] == "res://scenes/test.tscn"

    def test_path_traversal_rejected(self, godot_env):
        """路径遍历攻击被拒绝"""
        _exec_fail(godot_env, "gdapi/health/pathcheck",
                   '{"path":"../outside.txt","mode":"read"}')

    def test_absolute_path_rejected(self, godot_env):
        """绝对系统路径被拒绝"""
        _exec_fail(godot_env, "gdapi/health/pathcheck",
                   '{"path":"/etc/passwd","mode":"read"}')


# ── 审计日志 ─────────────────────────────────────────

class TestAuditLog:
    def test_audit_clear_requires_force(self, godot_env):
        """audit/clear 无 force 参数被拒绝"""
        _exec_fail(godot_env, "gdapi/audit/clear", "{}")

    def test_audit_clear_with_force(self, godot_env):
        """audit/clear 带 force:true 成功"""
        resp = _exec(godot_env, "gdapi/audit/clear", '{"force":true}')
        assert resp["ok"] is True
        assert resp["cleared"] is True

    def test_audit_list_returns_entries(self, godot_env):
        """audit/list 返回条目（含刚才 clear 失败的记录）"""
        # 先触发一次失败的 clear 来产生审计记录
        _exec_fail(godot_env, "gdapi/audit/clear", "{}")
        resp = _exec(godot_env, "gdapi/audit/list", '{"limit":10}')
        assert resp["ok"] is True
        assert isinstance(resp["entries"], list)
        assert len(resp["entries"]) > 0


# ── 路径安全（扩展） ──────────────────────────────────

def _exec_error(env: dict, route: str, data: dict) -> dict:
    result = subprocess.run(
        [
            str(env["gdcli"]), "--json", "exec", route,
            "--project", str(env["fixture"]),
            "--data", json.dumps(data),
        ],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    assert result.returncode != 0, result.stdout
    return json.loads(result.stderr.split(": ", 1)[1])


def test_pathcheck_rejects_unknown_mode(godot_env):
    error = _exec_error(
        godot_env,
        "gdapi/health/pathcheck",
        {"path": "res://test.tscn", "mode": "execute"},
    )
    assert error["code"] == "invalid_param"


def test_uid_update_requires_force(godot_env):
    error = _exec_error(godot_env, "uid/update_all", {"project_path": "res://tests"})
    assert error["code"] == "unsafe_operation"


def test_uid_update_cannot_touch_protected_metadata(godot_env):
    metadata = godot_env["fixture"] / ".godot" / "gdapi.json"
    before = metadata.read_bytes()
    error = _exec_error(
        godot_env,
        "uid/update_all",
        {"project_path": "res://.godot", "force": True},
    )
    assert error["code"] == "permission_denied"
    assert metadata.read_bytes() == before
