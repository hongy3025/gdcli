from pathlib import Path

import pytest

from .conftest import exec_error, exec_export

pytestmark = pytest.mark.skip(
    reason="android export requires Android SDK/ADB environment"
)

def test_export_run_returns_matching_artifact_digest(m5_editor):
    output = Path(m5_editor["project"]) / "build" / "m5.pck"
    try:
        result = exec_export(m5_editor, "export/run", {
            "preset": "M5 PCK", "path": "res://build/m5.pck", "force": True,
        })
        assert output.is_file()
        assert result["size"] == output.stat().st_size
        assert result["sha256"]
    finally:
        output.unlink(missing_ok=True)


def test_android_routes_are_deterministic_without_real_device(m5_editor):
    devices = exec_error(m5_editor, "export/android/devices", {}, extra_args=["--timeout", "60"])
    assert devices["code"] in {"not_found", "godot_error"} or isinstance(devices.get("devices"), list)
    missing = exec_error(m5_editor, "export/run", {
        "preset": "M5 Android Missing Template", "path": "res://build/missing.apk", "force": True,
    }, extra_args=["--timeout", "60"])
    assert missing["code"] == "not_supported"
    assert not (Path(m5_editor["project"]) / "build" / "missing.apk").exists()
