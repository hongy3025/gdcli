"""M1 路由基础设施端到端验证。

需要 Godot 编辑器可用。运行方式：
  uv run pytest tests/e2e/test_m1_smoke.py -v

跳过：
  uv run pytest tests/e2e/test_m1_smoke.py -v -k "not e2e"
"""
import pytest

from conftest import gdcli_json, gdcli_expect_fail


pytestmark = pytest.mark.e2e

FIXTURE_PROJECT_ARGS = ["--project", "{fixture}"]


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
        """gdcli exec ping 返回 ok:true"""
        resp = _exec(godot_env, "ping")
        assert resp["ok"] is True

    def test_ping_contains_editor_version(self, godot_env):
        """ping 响应包含 editor_version"""
        resp = _exec(godot_env, "ping")
        assert "editor_version" in resp

    def test_ping_contains_gdapi_version(self, godot_env):
        """ping 响应包含 gdapi_version"""
        resp = _exec(godot_env, "ping")
        assert "gdapi_version" in resp


# ── 路由命名空间 ─────────────────────────────────────────

class TestRouteNamespace:
    def test_editor_scene_create_exists(self, godot_env):
        """editor/scene/create 路由存在"""
        resp = _exec(godot_env, "routes")
        assert "editor/scene/create" in resp["routes"]

    def test_legacy_scene_create_exists(self, godot_env):
        """scene/create 旧路由仍可用"""
        resp = _exec(godot_env, "routes")
        assert "scene/create" in resp["routes"]

    def test_shared_godot_version_exists(self, godot_env):
        """shared/godot/version 路由存在"""
        resp = _exec(godot_env, "routes")
        assert "shared/godot/version" in resp["routes"]

    def test_legacy_godot_version_exists(self, godot_env):
        """godot/version 旧路由仍可用"""
        resp = _exec(godot_env, "routes")
        assert "godot/version" in resp["routes"]

    def test_project_health_path_check_exists(self, godot_env):
        """project/health/path_check 路由存在"""
        resp = _exec(godot_env, "routes")
        assert "project/health/path_check" in resp["routes"]

    def test_project_audit_list_exists(self, godot_env):
        """project/audit/list 路由存在"""
        resp = _exec(godot_env, "routes")
        assert "project/audit/list" in resp["routes"]

    def test_project_audit_clear_exists(self, godot_env):
        """project/audit/clear 路由存在"""
        resp = _exec(godot_env, "routes")
        assert "project/audit/clear" in resp["routes"]


# ── 别名元数据 ─────────────────────────────────────────

class TestAliasMetadata:
    def test_alias_scene_create(self, godot_env):
        """scene/create 别名指向 editor/scene/create"""
        resp = _exec(godot_env, "routes")
        assert resp["aliases"]["scene/create"] == "editor/scene/create"

    def test_alias_godot_version(self, godot_env):
        """godot/version 别名指向 shared/godot/version"""
        resp = _exec(godot_env, "routes")
        assert resp["aliases"]["godot/version"] == "shared/godot/version"


# ── 命令元数据 ─────────────────────────────────────────

class TestCommandsMetadata:
    def test_commands_contains_editor_scene_create(self, godot_env):
        """commands 列表包含 editor/scene/create"""
        resp = _exec(godot_env, "commands")
        paths = [c["path"] for c in resp["commands"]]
        assert "editor/scene/create" in paths

    def test_canonical_path_in_commands(self, godot_env):
        """editor/scene/create 的 canonical_path 正确"""
        resp = _exec(godot_env, "commands")
        entry = next(c for c in resp["commands"] if c["path"] == "editor/scene/create")
        assert entry["canonical_path"] == "editor/scene/create"

    def test_command_help_legacy_alias(self, godot_env):
        """command-help scene/create 解析到正确 canonical_path"""
        resp = gdcli_json(
            godot_env,
            "exec", "command-help", "scene/create",
            "--project", str(godot_env["fixture"]),
        )
        assert resp["doc"]["canonical_path"] == "editor/scene/create"


# ── 路径安全 ─────────────────────────────────────────

class TestPathGuard:
    def test_relative_path_normalized(self, godot_env):
        """相对路径被规范化为 res://"""
        resp = _exec(godot_env, "project/health/path_check",
                     '{"path":"scenes/test.tscn","mode":"read"}')
        assert resp["path"] == "res://scenes/test.tscn"
        assert resp["ok"] is True

    def test_res_path_accepted(self, godot_env):
        """res:// 路径直接接受"""
        resp = _exec(godot_env, "project/health/path_check",
                     '{"path":"res://scenes/test.tscn","mode":"read"}')
        assert resp["path"] == "res://scenes/test.tscn"

    def test_path_traversal_rejected(self, godot_env):
        """路径遍历攻击被拒绝"""
        _exec_fail(godot_env, "project/health/path_check",
                   '{"path":"../outside.txt","mode":"read"}')

    def test_absolute_path_rejected(self, godot_env):
        """绝对系统路径被拒绝"""
        _exec_fail(godot_env, "project/health/path_check",
                   '{"path":"/etc/passwd","mode":"read"}')


# ── 审计日志 ─────────────────────────────────────────

class TestAuditLog:
    def test_audit_clear_requires_force(self, godot_env):
        """audit/clear 无 force 参数被拒绝"""
        _exec_fail(godot_env, "project/audit/clear", "{}")

    def test_audit_clear_with_force(self, godot_env):
        """audit/clear 带 force:true 成功"""
        resp = _exec(godot_env, "project/audit/clear", '{"force":true}')
        assert resp["ok"] is True
        assert resp["cleared"] is True

    def test_audit_list_returns_entries(self, godot_env):
        """audit/list 返回条目（含刚才 clear 失败的记录）"""
        # 先触发一次失败的 clear 来产生审计记录
        _exec_fail(godot_env, "project/audit/clear", "{}")
        resp = _exec(godot_env, "project/audit/list", '{"limit":10}')
        assert resp["ok"] is True
        assert isinstance(resp["entries"], list)
        assert len(resp["entries"]) > 0
