"""M1 contract verification tests — error codes, doc completeness, and audit identity."""

import re
import subprocess
from pathlib import Path

from conftest import gdcli_json


STANDARD_CODES = {
    "missing_param", "invalid_param", "invalid_path", "not_found", "conflict",
    "not_supported", "permission_denied", "unsafe_operation", "timeout", "godot_error",
}


def test_all_command_docs_are_complete(godot_env):
    listing = gdcli_json(
        godot_env, "exec", "command/list", "--project", str(godot_env["fixture"])
    )
    for command in listing["commands"]:
        assert command["summary"], command["path"]
        detail = gdcli_json(
            godot_env, "exec", "command/doc", command["path"],
            "--project", str(godot_env["fixture"]),
        )["doc"]
        assert detail["returns"]["fields"], command["path"]
        if detail["params"]:
            assert detail["examples"], command["path"]


def test_literal_route_error_codes_are_standard(godot_env):
    root = Path(godot_env["root"]) / "gdapi" / "addon"
    pattern = re.compile(r'res\.error\([^\n]*,\s*"([a-z_]+)"')
    found = set()
    for path in root.rglob("*.gd"):
        found.update(pattern.findall(path.read_text(encoding="utf-8")))
    assert found <= STANDARD_CODES, sorted(found - STANDARD_CODES)


def test_audit_clear_records_exact_public_route(godot_env):
    gdcli_json(
        godot_env, "exec", "gdapi/audit/clear",
        "--project", str(godot_env["fixture"]),
        "--data", '{"force":true}',
    )
    rejected = subprocess.run(
        [
            str(godot_env["gdcli"]), "--json", "exec", "gdapi/audit/clear",
            "--project", str(godot_env["fixture"]), "--data", "{}",
        ],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    assert rejected.returncode == 2
    entries = gdcli_json(
        godot_env, "exec", "gdapi/audit/list",
        "--project", str(godot_env["fixture"]),
        "--data", '{"since":0,"limit":10}',
    )["entries"]
    assert entries[-1]["route"] == "gdapi/audit/clear"
    assert entries[-1]["ok"] is False