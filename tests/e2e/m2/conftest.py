"""Explicit scene navigation within the persistent shared editor."""

import json

import pytest

from .helpers import exec_ok, gdcli_exec


@pytest.fixture
def m2_main(m2_editor):
    """Focus Main when a scenario needs it, preserving its live native state."""
    result = gdcli_exec(m2_editor, "exec", "scene/current", "--project", str(m2_editor["project"]), check=False)
    current = json.loads(result.stdout)
    assert current.get("ok") is True or current.get("code") == "not_found", current
    if current.get("path") != "res://scenes/main.tscn":
        exec_ok(m2_editor, "scene/open", {"path": "res://scenes/main.tscn"})
    return m2_editor
