"""E2E tests for export/android/deploy_many bulk deploy route."""

from __future__ import annotations

from typing import Any

import pytest

from .conftest import command_doc, exec_error


def test_bulk_deploy_is_default_deny(m6_editor: dict[str, Any]) -> None:
    body: dict[str, Any] = {
        "serials": ["device-a"],
        "apk_path": "res://build/app.apk",
        "package": "org.example",
        "activity": "com.godot.game.GodotApp",
        "dry_run": True,
        "force": True,
    }
    error = exec_error(m6_editor, "export/android/deploy_many", body)
    assert error["code"] == "permission_denied"


def test_bulk_deploy_docs_are_complete(m6_editor: dict[str, Any]) -> None:
    doc = command_doc(m6_editor, "export/android/deploy_many")
    assert doc["summary"]
    assert doc["returns"]["fields"]
    assert doc["examples"]
