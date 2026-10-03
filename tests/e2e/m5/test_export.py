"""Desktop export routes: preset discovery and PCK export."""

from __future__ import annotations

import hashlib
from pathlib import Path

from .conftest import exec_error, exec_export, exec_ok


PRESET_NAME = "M5 PCK"
OUTPUT_RELATIVE = "build/m5.pck"


def _artifact(env: dict) -> Path:
    return Path(env["project"]) / OUTPUT_RELATIVE


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    digest.update(path.read_bytes())
    return digest.hexdigest()


def test_export_presets_lists_desktop_preset(m5_editor):
    presets = exec_ok(m5_editor, "export/presets")["presets"]
    by_name = {preset["name"]: preset for preset in presets}
    assert PRESET_NAME in by_name, presets
    assert by_name[PRESET_NAME]["platform"] == "Windows Desktop"


def test_export_run_produces_matching_artifact_digest(m5_editor):
    output = _artifact(m5_editor)
    try:
        result = exec_export(
            m5_editor,
            "export/run",
            {"preset": PRESET_NAME, "path": "res://" + OUTPUT_RELATIVE},
        )
        assert output.is_file(), result
        assert result["size"] == output.stat().st_size
        assert result["sha256"] == _sha256(output)
    finally:
        output.unlink(missing_ok=True)


def test_export_run_overwrites_previous_artifact(m5_editor):
    """同一路径重复导出必须成功覆盖，且响应摘要与落盘文件一致。

    产物本身位于项目内，因此第二次导出会把它当作资源一起打包：
    两次摘要不要求相同，只要求各自与当次落盘文件一致。
    """
    output = _artifact(m5_editor)
    payload = {"preset": PRESET_NAME, "path": "res://" + OUTPUT_RELATIVE}
    try:
        exec_export(m5_editor, "export/run", payload)
        assert output.is_file()
        second = exec_export(m5_editor, "export/run", payload)
        assert output.is_file()
        assert second["size"] == output.stat().st_size
        assert second["sha256"] == _sha256(output)
    finally:
        output.unlink(missing_ok=True)


def test_export_run_rejects_path_outside_project(m5_editor):
    error = exec_error(
        m5_editor,
        "export/run",
        {"preset": PRESET_NAME, "path": "user://outside.pck"},
    )
    assert error["code"] == "invalid_path"
    assert not _artifact(m5_editor).exists()


def test_export_run_rejects_unknown_preset(m5_editor):
    error = exec_error(
        m5_editor,
        "export/run",
        {"preset": "Missing Preset", "path": "res://" + OUTPUT_RELATIVE},
    )
    assert error["code"] == "not_found"
    assert not _artifact(m5_editor).exists()
