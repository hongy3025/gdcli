"""Independent, opt-in EngineDebugger session: never accept file fallback."""
from __future__ import annotations

import base64
import hashlib
import os
import struct

import pytest

from .conftest import (
    attach_game, detach_game, exec_error, exec_ok, runtime_counter,
    wait_for, wait_for_connected,
)

pytestmark = pytest.mark.engine_transport
TARGET = "/root/RuntimeMain/ProbeTarget"


def test_engine_debugger_protocol_two_real_data_plane(m3_editor):
    assert os.environ.get("GDAPI_E2E_TRANSPORT") == "engine_debugger", (
        "Use python scripts/check.py --gate engine, or explicitly set "
        "GDAPI_E2E_TRANSPORT=engine_debugger and pytest -m engine_transport"
    )
    attach_game(m3_editor, recovery_restarts=0)
    try:
        status = wait_for_connected(m3_editor)
        assert status["transport"] == "engine_debugger", status
        assert status["protocol_version"] == 2, status
        assert status["pending"] == 0, status
        pid = m3_editor["godot"].pid
        tree = exec_ok(m3_editor, "runtime/scene/tree", {"max_depth": 2})
        assert tree["root"]["name"] == "RuntimeMain"
        exec_ok(m3_editor, "runtime/node/set", {
            "node_path": TARGET, "property": "position",
            "value": {"type": "Vector2", "value": [31, 42]},
        })
        assert exec_ok(m3_editor, "runtime/node/get", {
            "node_path": TARGET, "property": "position",
        })["value"] == {"type": "Vector2", "value": [31.0, 42.0]}
        assert exec_error(m3_editor, "runtime/node/info", {
            "node_path": "/root/RuntimeMain/NoSuchNode",
        })["code"] == "not_found"
        # A failed data request must not poison the following input/capture request.
        before = runtime_counter(m3_editor, "input_keys")
        exec_ok(m3_editor, "runtime/input/key", {"keycode": 32, "pressed": True})
        wait_for(lambda: runtime_counter(m3_editor, "input_keys") == before + 1)
        exec_ok(m3_editor, "runtime/input/key", {"keycode": 32, "pressed": False})
        capture = exec_ok(m3_editor, "runtime/screenshot/viewport")
        png = base64.b64decode(capture["data_base64"], validate=True)
        assert png[:8] == b"\x89PNG\r\n\x1a\n"
        assert png[12:16] == b"IHDR"
        assert struct.unpack(">II", png[16:24]) == (capture["width"], capture["height"])
        assert capture["width"] > 0 and capture["height"] > 0
        assert hashlib.sha256(png).hexdigest() == capture["sha256"]
        active = exec_ok(m3_editor, "runtime/status")
        assert active["transport"] == "engine_debugger"
        assert active["protocol_version"] == 2
        assert m3_editor["godot"].pid == pid
        assert m3_editor["editor_start_count"] == 1
    finally:
        stopped = detach_game(m3_editor)
    assert stopped["state"] == "stopped"
    assert stopped["pending"] == 0
    assert stopped["editor_playing"] is False
    assert exec_error(m3_editor, "runtime/node/get", {
        "node_path": TARGET, "property": "position",
    })["code"] == "conflict"
