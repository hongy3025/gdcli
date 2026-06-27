"""基础端到端验证：gdcli exec ping 连通性测试。

需要 Godot 编辑器可用。运行方式：
  uv run pytest tests/e2e/test_e2e_ping.py -v
"""
import json
import subprocess

import pytest

from conftest import gdcli_json


pytestmark = pytest.mark.e2e


class TestPing:
    def test_exec_ping_ok(self, godot_env):
        """gdcli exec ping 返回 ok:true"""
        resp = gdcli_json(godot_env, "exec", "ping", "--project", str(godot_env["fixture"]))
        assert resp["ok"] is True

    def test_exec_ping_returns_editor_version(self, godot_env):
        """ping 响应包含 editor_version 字段"""
        resp = gdcli_json(godot_env, "exec", "ping", "--project", str(godot_env["fixture"]))
        assert "editor_version" in resp
        assert isinstance(resp["editor_version"], str)
        assert len(resp["editor_version"]) > 0

    def test_exec_ping_returns_gdapi_version(self, godot_env):
        """ping 响应包含 gdapi_version 字段"""
        resp = gdcli_json(godot_env, "exec", "ping", "--project", str(godot_env["fixture"]))
        assert "gdapi_version" in resp
        assert resp["gdapi_version"] == "0.2.0"

    def test_exec_ping_too_many_args_rejected(self, godot_env):
        """ping 不接受额外位置参数"""
        result = subprocess.run(
            [str(godot_env["gdcli"]), "--json", "exec", "ping", "extra_arg",
             "--project", str(godot_env["fixture"])],
            capture_output=True, encoding="utf-8", errors="replace",
        )
        assert result.returncode != 0
