"""基础端到端验证：gdcli exec gdapi/health/ping 连通性测试。

需要 Godot 编辑器可用。运行方式：
  uv run pytest tests/e2e/test_e2e_ping.py -v
"""
import json
import subprocess

import pytest

from conftest import gdcli_json


pytestmark = pytest.mark.e2e


class TestPing:
    def test_exec_ping_ok(self, e2e_editor):
        """gdcli exec gdapi/health/ping 返回 ok:true"""
        resp = gdcli_json(e2e_editor, "exec", "gdapi/health/ping", "--project", str(e2e_editor["fixture"]))
        assert resp["ok"] is True

    def test_exec_ping_returns_editor_version(self, e2e_editor):
        """gdapi/health/ping 响应包含 editor_version 字段"""
        resp = gdcli_json(e2e_editor, "exec", "gdapi/health/ping", "--project", str(e2e_editor["fixture"]))
        assert "editor_version" in resp
        assert isinstance(resp["editor_version"], str)
        assert len(resp["editor_version"]) > 0

    def test_exec_ping_returns_gdapi_version(self, e2e_editor):
        """gdapi/health/ping 响应包含 gdapi_version 字段"""
        resp = gdcli_json(e2e_editor, "exec", "gdapi/health/ping", "--project", str(e2e_editor["fixture"]))
        assert "gdapi_version" in resp
        assert resp["gdapi_version"] == "0.2.0"

    def test_exec_ping_too_many_args_rejected(self, e2e_editor):
        """gdapi/health/ping 不接受额外位置参数"""
        result = subprocess.run(
            [str(e2e_editor["gdcli"]), "--json", "exec", "gdapi/health/ping", "extra_arg",
             "--project", str(e2e_editor["fixture"])],
            capture_output=True, encoding="utf-8", errors="replace",
        )
        assert result.returncode != 0
