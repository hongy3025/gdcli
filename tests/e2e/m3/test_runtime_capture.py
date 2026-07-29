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
    assert 0 < capture["width"] <= 1920
    assert 0 < capture["height"] <= 1080
    assert hashlib.sha256(data).hexdigest() == capture["sha256"]


def test_camera_capture_invalid_node_returns_invalid_param(m3_running):
    error = exec_error(m3_running, "runtime/screenshot/camera", {
        "node_path": "/root/RuntimeMain/ProbeTarget",
    })
    assert error["code"] == "invalid_param"


@pytest.mark.parametrize(
    ("payload", "expected_code"),
    [
        ({"node_path": "RuntimeMain/ProbeTarget"}, "invalid_param"),
        ({"node_path": "/root/RuntimeMain/MissingCamera"}, "not_found"),
        ({"node_path": 17}, "invalid_param"),
        ({"node_path": "/root/" + "x" * 1025}, "invalid_param"),
    ],
)
def test_camera_path_is_strictly_validated(m3_running, payload, expected_code):
    error = exec_error(m3_running, "runtime/screenshot/camera", payload)
    assert error["code"] == expected_code


def test_frame_limits_over_sixty_returns_invalid_param(m3_running):
    error = exec_error(m3_running, "runtime/screenshot/frames", {"count": 61, "interval_ms": 1})
    assert error["code"] == "invalid_param"


@pytest.mark.parametrize(
    "payload",
    [
        {"count": 1.5},
        {"count": 0},
        {"interval_ms": 0},
        {"interval_ms": 1.5},
        {"camera_path": 17},
        {"count": 60, "interval_ms": 1000, "timeout_ms": 25000},
    ],
)
def test_frame_parameters_reject_before_capture(m3_running, payload):
    error = exec_error(m3_running, "runtime/screenshot/frames", payload)
    assert error["code"] == "invalid_param"


def test_frame_capture_returns_dict(m3_running):
    capture = exec_ok(
        m3_running,
        "runtime/screenshot/frames",
        {"count": 2, "interval_ms": 16, "timeout_ms": 5000},
    )
    assert capture["count"] == 2
    assert isinstance(capture["frames"], list)
    assert len(capture["frames"]) == 2
    for frame in capture["frames"]:
        data = _png_signature_present(frame)
        assert 0 < frame["width"] <= 1920
        assert 0 < frame["height"] <= 1080
        assert hashlib.sha256(data).hexdigest() == frame["sha256"]
