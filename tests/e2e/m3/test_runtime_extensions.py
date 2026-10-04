"""Broker-backed recording, monitoring, QA and real PNG pixel regressions."""
from __future__ import annotations

import base64
from concurrent.futures import ThreadPoolExecutor
import struct
import time
import zlib

import pytest

from .conftest import exec_error, exec_ok, runtime_counter, wait_for, reset_fixture, _fixture_hook_reset_once

TARGET = "/root/RuntimeMain/ProbeTarget"


def png(width=2, height=2, changed=None):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend((255, 0, 0, 255) if changed == (x, y) else (0, 0, 0, 255))
    raw = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    raw += chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
    return {"data_base64": base64.b64encode(raw).decode("ascii")}


def test_record_real_input_reset_then_replay(m3_running):
    env = m3_running
    started = exec_ok(env, "runtime/recording/start", {"max_events": 4})
    for _ in range(2):
        exec_ok(env, "runtime/input/key", {"keycode": 32, "pressed": True})
        exec_ok(env, "runtime/input/key", {"keycode": 32, "pressed": False})
    wait_for(lambda: runtime_counter(env, "input_keys") == 4)
    stopped = exec_ok(env, "runtime/recording/stop")
    recorded = exec_ok(env, "runtime/recording/read", {"limit": 100})
    assert recorded["recording_id"] == started["recording_id"]
    assert stopped["count"] == 4
    assert [item["data"]["pressed"] for item in recorded["items"]] == [True, False, True, False]
    assert [item["cursor"] for item in recorded["items"]] == [1, 2, 3, 4]
    assert recorded["status"] == "limit_reached"
    page = exec_ok(env, "runtime/recording/read", {"after_cursor": 2, "limit": 1})
    assert page["items"] == [recorded["items"][2]]
    _fixture_hook_reset_once(env)
    assert exec_error(env, "runtime/recording/read")["code"] == "not_found"
    replay = exec_ok(env, "runtime/recording/replay", {"events": recorded["items"], "timeout_ms": 10000})
    assert replay["status"] == "completed"
    assert replay["completed_events"] == 4
    assert replay["elapsed_ms"] >= recorded["items"][-1]["at_ms"]
    wait_for(lambda: runtime_counter(env, "input_keys") == 4)


def test_replay_timeout_and_cancellation_complete_real_requests(m3_running):
    event = {"at_ms": 1000, "route": "runtime/input/key", "data": {"keycode": 32}}
    result = exec_ok(m3_running, "runtime/recording/replay", {"events": [event], "timeout_ms": 50})
    assert result["status"] == "timed_out"
    assert result["completed_events"] == 0
    assert runtime_counter(m3_running, "input_keys") == 0
    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(exec_ok, m3_running, "runtime/recording/replay", {"events": [dict(event, at_ms=4000)], "timeout_ms": 10000})
        wait_for(lambda: exec_ok(m3_running, "runtime/recording/cancel")["changed"])
        result = future.result(timeout=15)
    assert result["status"] == "cancelled"
    assert result["completed_events"] == 0
    assert runtime_counter(m3_running, "input_keys") == 0


@pytest.mark.parametrize("payload", [{"max_events": 0}, {"max_events": True}, {"max_events": 1001}])
def test_recording_event_bounds(m3_running, payload):
    assert exec_error(m3_running, "runtime/recording/start", payload)["code"] == "invalid_param"


def test_monitor_real_cross_frame_typed_changes_cursor_stop_and_reset(m3_running):
    env = m3_running
    monitor = exec_ok(env, "runtime/monitor/start", {"node_path": TARGET, "property": "position", "interval_ms": 1})
    mid = monitor["monitor_id"]
    first = exec_ok(env, "runtime/monitor/read", {"monitor_id": mid})
    assert first["items"][0]["value"] == {"type": "Vector2", "value": [0, 0]}
    for value in ([4, 5], [8, 9]):
        exec_ok(env, "runtime/node/set", {"node_path": TARGET, "property": "position", "value": {"type": "Vector2", "value": value}})
        wait_for(lambda: exec_ok(env, "runtime/monitor/read", {"monitor_id": mid})["items"][-1].get("value") == {"type": "Vector2", "value": value})
    page = exec_ok(env, "runtime/monitor/read", {"monitor_id": mid, "after_cursor": first["next_cursor"]})
    assert [item["value"]["value"] for item in page["items"]] == [[4, 5], [8, 9]]
    assert page["items"][0]["frame"] < page["items"][1]["frame"]
    exec_ok(env, "runtime/monitor/stop", {"monitor_id": mid})
    exec_ok(env, "runtime/node/set", {"node_path": TARGET, "property": "position", "value": {"type": "Vector2", "value": [10, 11]}})
    time.sleep(0.05)
    assert exec_ok(env, "runtime/monitor/read", {"monitor_id": mid, "after_cursor": page["next_cursor"]})["items"] == []
    _fixture_hook_reset_once(env)
    assert exec_error(env, "runtime/monitor/read", {"monitor_id": mid})["code"] == "not_found"


def test_monitor_missing_target_terminates_subscription(m3_running):
    exec_ok(m3_running, "runtime/node/create", {"parent_path": "/root/RuntimeMain", "type": "Node2D", "name": "MonitorTarget"})
    path = "/root/RuntimeMain/MonitorTarget"
    monitor = exec_ok(m3_running, "runtime/monitor/start", {"node_path": path, "property": "position"})
    exec_ok(m3_running, "runtime/node/remove", {"node_path": path})
    wait_for(lambda: exec_ok(m3_running, "runtime/monitor/read", {"monitor_id": monitor["monitor_id"]})["status"] == "target_missing")
    page = exec_ok(m3_running, "runtime/monitor/read", {"monitor_id": monitor["monitor_id"]})
    assert page["items"][-1]["code"] == "not_found"


def test_qa_json_scene_script_real_assertions_cleanup_and_report(m3_running):
    result = exec_ok(m3_running, "runtime/test/run", {"script_path": "res://scenes/runtime_qa_scenario.json"})
    assert result["status"] == "passed"
    assert result["passed_iterations"] == 1
    assert result["samples"][0]["steps"][2]["value"] is True
    assert result["samples"][0]["steps"][3]["result"]["text"] == "Runtime QA ready"
    assert result["samples"][0]["steps"][4]["result"]["passed"] is True
    saved = exec_ok(m3_running, "runtime/test/report", {"report_id": result["report_id"]})
    assert saved["samples"] == result["samples"]
    assert exec_ok(m3_running, "runtime/node/find", {"name": "Scene"})["total"] == 0
    _fixture_hook_reset_once(m3_running)
    assert exec_error(m3_running, "runtime/test/report", {"report_id": result["report_id"]})["code"] == "not_found"


def test_qa_failed_and_timeout_results_are_saved(m3_running):
    failed = exec_ok(m3_running, "runtime/test/run", {"scenario": {"steps": [{"op": "runtime/node/call", "data": {"node_path": TARGET, "method": "queue_free"}}]}})
    assert failed["status"] == "failed"
    assert failed["samples"][0]["steps"][0]["code"] == "permission_denied"
    started = time.monotonic()
    timeout = exec_ok(m3_running, "runtime/test/run", {"timeout_ms": 60, "scenario": {"scene_path": "res://scenes/runtime_qa_scene.tscn", "steps": [{"op": "runtime/assert/property_equals", "data": {"node_path": "$scene", "property": "counter", "value": 99}}]}})
    assert timeout["status"] == "timed_out"
    assert timeout["elapsed_ms"] >= 60
    assert time.monotonic() - started < 5
    saved = exec_ok(m3_running, "runtime/test/report", {"report_id": timeout["report_id"]})
    assert saved["samples"][0]["steps"][0]["code"] == "timeout"
    assert exec_ok(m3_running, "runtime/node/find", {"name": "Scene"})["total"] == 0


@pytest.mark.parametrize("payload", [
    {"script_path": "res://addons/gdapi/runtime/runtime_probe.gd"},
    {"script_path": "res://../escape.json"},
    {"scenario": {"steps": [{"op": "eval", "data": {"source": "1+1"}}]}},
])
def test_qa_does_not_bypass_capability_boundaries(m3_running, payload):
    assert exec_error(m3_running, "runtime/test/run", payload)["code"] in {"permission_denied", "invalid_path", "invalid_param"}


def test_stress_actually_executes_concurrent_iterations(m3_running):
    result = exec_ok(m3_running, "runtime/test/stress", {"iterations": 8, "concurrency": 4, "scenario": {"steps": [{"op": "runtime/node/call", "data": {"node_path": TARGET, "method": "increment", "args": [1]}}, {"op": "wait", "data": {"duration_ms": 20}}]}})
    assert result["status"] == "passed"
    assert result["completed_iterations"] == result["passed_iterations"] == 8
    assert result["failed_iterations"] == 0
    assert runtime_counter(m3_running, "counter") == 8
    assert all(sample["passed"] and sample["elapsed_ms"] >= 20 for sample in result["samples"])
    assert exec_ok(m3_running, "runtime/test/report", {"report_id": result["report_id"]})["samples"] == result["samples"]


def test_png_comparison_identical_changed_threshold_and_dimensions(m3_running):
    black = png()
    red = png(changed=(1, 0))
    equal = exec_ok(m3_running, "runtime/screenshot/compare", {"expected": black, "actual": black})
    assert equal["matches"] is True
    assert equal["diff_pixels"] == equal["diff_ratio"] == equal["max_error"] == equal["mean_squared_error"] == 0
    assert equal["diff_bbox"] is None
    changed = exec_ok(m3_running, "runtime/screenshot/compare", {"expected": black, "actual": red})
    assert changed["matches"] is False
    assert changed["diff_pixels"] == 1
    assert changed["diff_ratio"] == 0.25
    assert changed["max_error"] == 1
    assert changed["mean_squared_error"] == pytest.approx(1 / 16)
    assert changed["diff_bbox"] == {"x": 1, "y": 0, "width": 1, "height": 1}
    tolerated = exec_ok(m3_running, "runtime/screenshot/compare", {"expected": black, "actual": red, "max_diff_ratio": 0.25})
    assert tolerated["matches"] is True
    threshold = exec_ok(m3_running, "runtime/screenshot/compare", {"expected": black, "actual": red, "threshold": 1})
    assert threshold["diff_pixels"] == 0
    assert threshold["mean_squared_error"] > 0
    mismatch = exec_ok(m3_running, "runtime/screenshot/compare", {"expected": black, "actual": png(3, 1)})
    assert mismatch["dimensions_match"] is False
    assert mismatch["matches"] is False


@pytest.mark.parametrize("payload", [
    {"expected": {"data_base64": "not PNG"}, "actual": png()},
    {"expected": png(), "actual": png(), "threshold": -0.1},
    {"expected": png(), "actual": png(), "max_diff_ratio": 1.1},
    {"expected": {"path": "res://../escape.png"}, "actual": png()},
])
def test_png_comparison_rejects_invalid_boundaries(m3_running, payload):
    assert exec_error(m3_running, "runtime/screenshot/compare", payload)["code"] in {"invalid_param", "invalid_path"}


def test_screen_text_reads_controls_and_reports_real_timeout(m3_running):
    result = exec_ok(m3_running, "runtime/test/run", {"scenario": {"scene_path": "res://scenes/runtime_qa_scene.tscn", "steps": [{"op": "runtime/assert/screen_text", "data": {"node_path": "$scene/Status", "text": "QA ready", "match": "contains"}}]}})
    assert result["status"] == "passed"
    assert result["samples"][0]["steps"][0]["result"]["source"] == "Control.text"
    error = exec_error(m3_running, "runtime/assert/screen_text", {"node_path": TARGET, "text": "not a Control text", "timeout_ms": 40})
    assert error["code"] == "timeout"


def test_stress_retains_actual_failure_samples(m3_running):
    result = exec_ok(m3_running, "runtime/test/stress", {"iterations": 3, "concurrency": 2, "scenario": {"steps": [{"op": "runtime/node/call", "data": {"node_path": TARGET, "method": "queue_free"}}]}})
    assert result["status"] == "failed"
    assert result["completed_iterations"] == result["failed_iterations"] == 3
    assert result["passed_iterations"] == 0
    assert all(sample["steps"][0]["code"] == "permission_denied" for sample in result["samples"])
    assert runtime_counter(m3_running, "counter") == 0


def test_reset_cancels_pending_qa_and_releases_signal_wait(m3_running):
    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(exec_ok, m3_running, "runtime/test/run", {"timeout_ms": 10000, "scenario": {"steps": [{"op": "runtime/assert/signal_received", "data": {"node_path": TARGET, "signal": "finished"}}]}})
        wait_for(lambda: any("GdApiTest_" in node["node_path"] for node in exec_ok(m3_running, "runtime/node/find", {"type": "Node", "limit": 200})["nodes"]))
        _fixture_hook_reset_once(m3_running)
        result = future.result(timeout=5)
    assert result["status"] == "cancelled"
    assert runtime_counter(m3_running, "counter") == 0
    assert not any("GdApiTest_" in node["node_path"] for node in exec_ok(m3_running, "runtime/node/find", {"type": "Node", "limit": 200})["nodes"])


def test_png_comparison_current_viewport_and_dimension_allocation_bound(m3_running):
    result = exec_ok(m3_running, "runtime/screenshot/compare", {"expected": png()})
    assert result["dimensions_match"] is False
    assert result["actual_size"][0] > 2
    assert result["actual_size"][1] > 2
    assert result["diff_pixels"] is None
    oversized = bytearray(base64.b64decode(png()["data_base64"]))
    oversized[16:20] = struct.pack(">I", 1921)
    error = exec_error(m3_running, "runtime/screenshot/compare", {"expected": {"data_base64": base64.b64encode(oversized).decode("ascii")}, "actual": png()})
    assert error["code"] == "invalid_param"


def test_particle_runtime_observes_both_gpu_types_in_game_process(m3_running):
    reset_fixture(m3_running)
    for name, kind, amount, lifetime, draw in [
        ("GPU2D", "GPUParticles2D", 12, 2.5, "texture"),
        ("GPU3D", "GPUParticles3D", 18, 3.5, "draw_pass_1"),
    ]:
        result = exec_ok(m3_running, "runtime/particles/info", {"node_path": "/root/RuntimeMain/ParticlesFixture/" + name})
        assert (result["type"], result["amount"], result["lifetime"]) == (kind, amount, lifetime)
        assert result["emitting"] is False
        assert result["inside_tree"] is True
        assert result["process_frame"] > 0
        assert result["process_material"]["class"] == "ParticleProcessMaterial"
        assert result["properties"][draw]["class"] == ("GradientTexture2D" if name == "GPU2D" else "QuadMesh")
    assert exec_error(m3_running, "runtime/particles/info", {"node_path": "/root/RuntimeMain/ProbeTarget"})["code"] == "invalid_param"
    assert exec_error(m3_running, "runtime/particles/info", {"node_path": "/root/RuntimeMain/Missing"})["code"] == "not_found"


def _tween_status(env, tween_id):
    return exec_ok(env, "runtime/tween/status", {"id": tween_id})


def test_tween_intermediate_completion_and_cancellation(m3_running):
    reset_fixture(m3_running)
    request = {"node_path": TARGET, "property": "position", "from": {"type": "Vector2", "value": [0, 0]}, "to": {"type": "Vector2", "value": [100, 40]}, "duration": 1.5, "trans": 0, "ease": 0}
    started = exec_ok(m3_running, "runtime/tween/start", request)
    tween_id = started["id"]
    assert started["state"] == "running" and started["undoable"] is False
    time.sleep(0.2)
    intermediate = _tween_status(m3_running, tween_id)
    assert intermediate["state"] == "running"
    assert 0 < intermediate["progress"] < 1
    assert 0 < intermediate["value"]["value"][0] < 100
    later = _tween_status(m3_running, tween_id)
    assert later["value"]["value"][0] > intermediate["value"]["value"][0]
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        finished = _tween_status(m3_running, tween_id)
        if finished["state"] == "completed":
            break
        time.sleep(0.05)
    assert finished["state"] == "completed"
    assert finished["value"] == {"type": "Vector2", "value": [100.0, 40.0]}
    second = exec_ok(m3_running, "runtime/tween/start", request | {"to": {"type": "Vector2", "value": [500, 100]}, "duration": 3.0})
    time.sleep(0.2)
    stopped = exec_ok(m3_running, "runtime/tween/stop", {"id": second["id"]})
    assert stopped["state"] == "cancelled" and stopped["changed"] is True
    assert stopped["value"]["value"][0] < 500
    time.sleep(0.2)
    assert _tween_status(m3_running, second["id"])["value"] == stopped["value"]
    assert exec_ok(m3_running, "runtime/node/get", {"node_path": TARGET, "property": "position"})["value"] == stopped["value"]
    assert exec_ok(m3_running, "runtime/tween/stop", {"id": second["id"]})["changed"] is False


def test_tween_invalid_requests_conflicts_and_target_cleanup(m3_running):
    reset_fixture(m3_running)
    request = {"node_path": TARGET, "property": "position", "to": {"type": "Vector2", "value": [100, 40]}, "duration": 2.0}
    baseline = exec_ok(m3_running, "runtime/node/get", {"node_path": TARGET, "property": "position"})["value"]
    for changes, code in [
        ({"duration": 0}, "invalid_param"),
        ({"duration": -1}, "invalid_param"),
        ({"to": 5}, "invalid_param"),
        ({"ease": 10}, "invalid_param"),
        ({"trans": -1}, "invalid_param"),
        ({"property": "script"}, "permission_denied"),
        ({"node_path": "/root/GdApiRuntimeProbe"}, "permission_denied"),
    ]:
        assert exec_error(m3_running, "runtime/tween/start", request | changes)["code"] == code
        assert exec_ok(m3_running, "runtime/node/get", {"node_path": TARGET, "property": "position"})["value"] == baseline
    started = exec_ok(m3_running, "runtime/tween/start", request)
    assert exec_error(m3_running, "runtime/tween/start", request)["code"] == "conflict"
    exec_ok(m3_running, "runtime/tween/stop", {"id": started["id"]})
    created = exec_ok(m3_running, "runtime/node/create", {"parent_path": "/root/RuntimeMain", "type": "Node2D", "name": "TweenDisposable"})
    disposable = exec_ok(m3_running, "runtime/tween/start", request | {"node_path": created["node_path"]})
    exec_ok(m3_running, "runtime/node/remove", {"node_path": created["node_path"]})
    time.sleep(0.1)
    assert _tween_status(m3_running, disposable["id"])["state"] == "target_lost"
    assert exec_error(m3_running, "runtime/tween/status", {"id": "missing"})["code"] == "not_found"
