"""M4 helpers navigate live tabs and use absolute scene-root paths for node APIs."""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

from e2e.m3.conftest import command_doc, exec_error, exec_ok
from e2e.m2.helpers import history_action


DOMAIN_SCENES = {
    "animation": "res://scenes/animation.tscn",
    "tilemap": "res://scenes/tilemap.tscn",
    "rendering": "res://scenes/rendering.tscn",
    "audio": "res://scenes/audio.tscn",
    "ui": "res://scenes/ui.tscn",
    "physics": "res://scenes/physics.tscn",
    "navigation": "res://scenes/navigation.tscn",
}


def select_domain(env: dict[str, Any], domain: str) -> None:
    """Keep the current live tab, otherwise select it and await navigation."""
    scene_path = DOMAIN_SCENES[domain]
    if exec_ok(env, "scene/current")["path"] != scene_path:
        # exec_ok waits for scene/open to become current before returning.
        exec_ok(env, "scene/open", {"path": scene_path})


def save_scene(env: dict[str, Any], scene_path: str) -> str:
    """Save ongoing editor state and return its actual persisted scene text."""
    exec_ok(env, "scene/current/save")
    return exec_ok(env, "filesystem/read", {"path": scene_path})["content"]


def editor_undo(env: dict[str, Any]) -> None:
    _editor_history_action(env, "undo")


def editor_redo(env: dict[str, Any]) -> None:
    _editor_history_action(env, "redo")


def _editor_history_action(env: dict[str, Any], action: str) -> None:
    """Use the same idempotent, retrying history bridge as M2."""
    payload = history_action(env, action)
    assert payload.get("ok") is True, payload


def source_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def audit_cursor(env: dict[str, Any]) -> int:
    entries = exec_ok(env, "gdapi/audit/list", {"limit": 1000})["entries"]
    return max((entry["seq"] for entry in entries), default=0)


__all__ = [
    "audit_cursor", "command_doc", "editor_redo", "editor_undo", "exec_error", "exec_ok",
    "select_domain", "save_scene", "source_digest",
]
