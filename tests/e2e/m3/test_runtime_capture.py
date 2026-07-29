"""M3 capture E2E 测试"""

from __future__ import annotations

import base64
import hashlib
import time

import pytest

from .conftest import exec_ok, exec_error


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PROBE_TARGET = "/root/RuntimeMain/ProbeTarget"
CAPTURE_CAMERA = "/root/RuntimeMain/CaptureFixtureViewport/CaptureFixtureCamera"


def _png_signature_present(capture):
    data = base64.b64decode(capture["data_base64"])
    assert data[:8] == PNG_SIGNATURE
    assert len(data) > 8
    return data


def _prepare_capture_fixture(m3_running, mode):
    result = exec_ok(m3_running, "runtime/node/call", {
        "node_path": PROBE_TARGET,
        "method": "prepare_capture_fixture",
        "args": [mode],
    })
    assert result["method"] == "prepare_capture_fixture"
    return result["result"]


def _readbacks(m3_running):
    return exec_ok(m3_running, "runtime/node/get", {
        "node_path": PROBE_TARGET,
        "property": "capture_readbacks",
    })["value"]


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


def test_camera_capture_returns_valid_png_and_path(m3_running):
    fixture = _prepare_capture_fixture(m3_running, "camera")
    assert fixture["camera_path"] == CAPTURE_CAMERA
    capture = exec_ok(m3_running, "runtime/screenshot/camera", {
        "node_path": CAPTURE_CAMERA,
    })
    data = _png_signature_present(capture)
    assert capture["camera"] == CAPTURE_CAMERA
    assert hashlib.sha256(data).hexdigest() == capture["sha256"]


def test_oversized_camera_source_is_rejected_before_readback(m3_running):
    fixture = _prepare_capture_fixture(m3_running, "oversized")
    assert fixture["camera_path"] == CAPTURE_CAMERA
    before = _readbacks(m3_running)
    error = exec_error(m3_running, "runtime/screenshot/camera", {
        "node_path": CAPTURE_CAMERA,
    })
    assert error["code"] == "invalid_param"
    assert "pre-readback" in error["error"]
    assert _readbacks(m3_running) == before
    assert exec_ok(m3_running, "runtime/status")["state"] == "connected"


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


def test_real_high_entropy_capture_is_bounded_and_transport_recovers(m3_running):
    fixture = _prepare_capture_fixture(m3_running, "high_entropy")
    assert fixture["camera_path"] == CAPTURE_CAMERA
    started = time.monotonic()
    error = exec_error(m3_running, "runtime/screenshot/frames", {
        "count": 2,
        "interval_ms": 1,
        "timeout_ms": 10000,
        "camera_path": CAPTURE_CAMERA,
    })
    assert error["code"] == "invalid_param"
    assert "4 MiB" in error["error"]
    assert time.monotonic() - started < 10
    diagnostics = error["diagnostics"]
    reply_bytes = (diagnostics["stdout"] + diagnostics["stderr"]).encode("utf-8")
    assert len(reply_bytes) < 4 * 1024 * 1024
    assert exec_ok(m3_running, "runtime/status")["state"] == "connected"
    _png_signature_present(exec_ok(m3_running, "runtime/screenshot/viewport"))


def test_capture_deadline_stops_before_readback_and_transport_recovers(m3_running):
    fixture = _prepare_capture_fixture(m3_running, "delayed")
    assert fixture["camera_path"] == CAPTURE_CAMERA
    before = _readbacks(m3_running)
    error = exec_error(m3_running, "runtime/screenshot/camera", {
        "node_path": CAPTURE_CAMERA,
        "timeout_ms": 50,
    })
    assert error["code"] == "timeout"
    assert _readbacks(m3_running) == before
    time.sleep(0.35)
    assert _readbacks(m3_running) == before
    assert exec_ok(m3_running, "runtime/status")["state"] == "connected"
    _png_signature_present(exec_ok(m3_running, "runtime/screenshot/viewport"))
