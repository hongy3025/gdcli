"""Desktop export routes: preset discovery and PCK export."""

from __future__ import annotations

import hashlib
from pathlib import Path
from uuid import uuid4

import pytest

from .conftest import exec_error, exec_export, exec_ok


PRESET_NAME = "M5 PCK"


@pytest.fixture()
def export_artifact(m5_editor):
    output = Path(m5_editor["project"]) / "build" / ("m5_" + uuid4().hex + ".pck")
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        yield output
    finally:
        output.unlink(missing_ok=True)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    digest.update(path.read_bytes())
    return digest.hexdigest()


def test_export_presets_lists_desktop_preset(m5_editor):
    presets = exec_ok(m5_editor, "export/presets")["presets"]
    by_name = {preset["name"]: preset for preset in presets}
    assert PRESET_NAME in by_name, presets
    assert by_name[PRESET_NAME]["platform"] == "Windows Desktop"



def test_export_run_overwrites_previous_artifact(m5_editor, export_artifact):
    """A real export overwrites its owned artifact and reports its actual digest."""
    output = export_artifact
    stale = b"stale export artifact"
    output.write_bytes(stale)
    payload = {"preset": PRESET_NAME, "path": "res://build/" + output.name}
    result = exec_export(m5_editor, "export/run", payload)
    assert output.is_file(), result
    assert result["size"] == output.stat().st_size
    assert result["sha256"] == _sha256(output)
    assert (result["size"], result["sha256"]) != (
        len(stale),
        hashlib.sha256(stale).hexdigest(),
    )


def test_export_run_rejects_path_outside_project(m5_editor, export_artifact):
    export_artifact.write_bytes(b"owned artifact before rejected export")
    before = export_artifact.read_bytes()
    error = exec_error(
        m5_editor,
        "export/run",
        {"preset": PRESET_NAME, "path": "user://outside.pck"},
    )
    assert error["code"] == "invalid_path"
    assert export_artifact.read_bytes() == before


def test_export_run_rejects_unknown_preset(m5_editor, export_artifact):
    export_artifact.write_bytes(b"owned artifact before rejected export")
    before = export_artifact.read_bytes()
    error = exec_error(
        m5_editor,
        "export/run",
        {"preset": "Missing Preset", "path": "res://build/" + export_artifact.name},
    )
    assert error["code"] == "not_found"
    assert export_artifact.read_bytes() == before
