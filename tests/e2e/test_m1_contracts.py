"""M1 contract verification tests — error codes, doc completeness, and audit identity."""

import re
import subprocess
from pathlib import Path

from conftest import gdcli_json


STANDARD_CODES = {
    "missing_param", "invalid_param", "invalid_path", "not_found", "conflict",
    "not_supported", "permission_denied", "unsafe_operation", "timeout", "godot_error",
}


def test_all_command_docs_are_complete(e2e_editor):
    listing = gdcli_json(
        e2e_editor, "exec", "command/list", "--project", str(e2e_editor["fixture"])
    )
    for command in listing["commands"]:
        assert command["summary"], command["path"]
        detail = gdcli_json(
            e2e_editor, "exec", "command/doc", command["path"],
            "--project", str(e2e_editor["fixture"]),
        )["doc"]
        assert detail["returns"]["fields"], command["path"]
        if detail["params"]:
            assert detail["examples"], command["path"]


def test_literal_route_error_codes_are_standard(e2e_editor):
    root = Path(e2e_editor["root"]) / "gdapi" / "addon"
    pattern = re.compile(r'res\.error\([^\n]*,\s*"([a-z_]+)"')
    found = set()
    for path in root.rglob("*.gd"):
        found.update(pattern.findall(path.read_text(encoding="utf-8")))
    assert found <= STANDARD_CODES, sorted(found - STANDARD_CODES)


def test_audit_clear_records_exact_public_route(e2e_editor):
    gdcli_json(
        e2e_editor, "exec", "gdapi/audit/clear",
        "--project", str(e2e_editor["fixture"]),
        "--data", '{"force":true}',
    )
    rejected = subprocess.run(
        [
            str(e2e_editor["gdcli"]), "--json", "exec", "gdapi/audit/clear",
            "--project", str(e2e_editor["fixture"]), "--data", "{}",
        ],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    assert rejected.returncode == 2
    entries = gdcli_json(
        e2e_editor, "exec", "gdapi/audit/list",
        "--project", str(e2e_editor["fixture"]),
        "--data", '{"since":0,"limit":10}',
    )["entries"]
    assert entries[-1]["route"] == "gdapi/audit/clear"
    assert entries[-1]["ok"] is False