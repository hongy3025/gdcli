"""Stable M4 E2E helpers shared by every game-system domain test."""

from __future__ import annotations

import hashlib
import time
from pathlib import Path
from typing import Any

from e2e.m3.conftest import command_doc, exec_error, exec_ok, wait_for_connected, wait_stopped
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


def open_domain(env: dict[str, Any], domain: str) -> None:
    """Open a domain by running its fixed scene through the editor."""
    run_domain(env, domain)


def run_domain(env: dict[str, Any], domain: str) -> None:
    """Start a fixed M4 scene and wait for its runtime broker connection."""
    scene_path = DOMAIN_SCENES[domain]
    exec_ok(env, "project/run", {"scene_path": scene_path})
    env["game_attached"] = True
    wait_for_connected(env, timeout=60.0)
    time.sleep(0.1)


def stop_domain(env: dict[str, Any], domain: str) -> None:
    """Stop an M4 domain and require the broker to drain completely."""
    del domain
    exec_ok(env, "project/stop")
    status = wait_stopped(env, timeout=15.0)
    assert status["pending"] == 0
    env["game_attached"] = False


def save_reopen(env: dict[str, Any], scene_path: str) -> None:
    exec_ok(env, "scene/current/save")
    exec_ok(env, "scene/open", {"path": scene_path})


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


__all__ = [
    "command_doc", "editor_redo", "editor_undo", "exec_error", "exec_ok",
    "open_domain", "run_domain", "save_reopen", "source_digest", "stop_domain",
]
