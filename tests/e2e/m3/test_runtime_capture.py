"""M3 capture E2E 测试"""

from __future__ import annotations

import base64
import hashlib

import pytest

from .conftest import exec_ok, exec_error


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _png_signature_present(capture):
    data = base64.b64decode(capture["data_base64"])
    assert data[:8] == PNG_SIGNATURE
    assert len(data) > 8
    return data


def test_viewport_capture_is_valid_png(m3_running):
    capture = exec_ok(m3_running, "runtime/screenshot/viewport")
    data = _png_signature_present(capture)
    assert capture["width"] > 0 and capture["height"] > 0
    assert hashlib.sha256(data).hexdigest() == capture["sha256"]


def test_camera_capture_invalid_node_returns_invalid_param(m3_running):
    error = exec_error(m3_running, "runtime/screenshot/camera", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
    })
    assert error["code"] == "invalid_param"


def test_frame_limits_over_sixty_returns_invalid_param(m3_running):
    error = exec_error(m3_running, "runtime/screenshot/frames", {"count": 61, "interval_ms": 1})
    assert error["code"] == "invalid_param"


def test_frame_capture_returns_dict(m3_running):
    capture = exec_ok(m3_running, "runtime/screenshot/frames", {"count": 2, "interval_ms": 16})
    assert capture["count"] == 2
    assert isinstance(capture["frames"], list)
    assert len(capture["frames"]) >= 1
    for frame in capture["frames"]:
        assert "index" in frame
        assert "sha256" in frame
