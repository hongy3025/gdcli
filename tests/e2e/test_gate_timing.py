"""No-engine unit boundaries for timing configuration, reports and gate failure flow."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from e2e import timing
from e2e.m2 import helpers as history_helpers
from e2e.m3 import conftest as runtime_helpers
from e2e import shared_fixture
from e2e.test_full_suite_budget import run_budget_session
from scripts import check


@pytest.mark.parametrize("raw", ["", "abc", "0", "-1", "nan", "inf"])
def test_thresholds_reject_nonpositive_nonfinite_and_bad_numbers(monkeypatch, raw):
    name = "GDAPI_E2E_BUDGET_SECONDS"
    monkeypatch.setenv(name, raw)
    with pytest.raises(ValueError, match=name + "=.*finite positive.*unset"):
        timing.positive_seconds(name)


def test_threshold_override_and_existing_budget_default(monkeypatch):
    monkeypatch.delenv("GDAPI_E2E_BUDGET_SECONDS", raising=False)
    assert timing.positive_seconds("GDAPI_E2E_BUDGET_SECONDS") == 360
    monkeypatch.setenv("GDAPI_E2E_WAIT_TIMEOUT_SECONDS", "2.75")
    assert timing.positive_seconds("GDAPI_E2E_WAIT_TIMEOUT_SECONDS", 15) == 2.75

@pytest.mark.parametrize("mode", ["", "software"])
def test_editor_mode_rejects_unknown_values(monkeypatch, mode):
    monkeypatch.setenv("GDAPI_E2E_EDITOR_MODE", mode)
    with pytest.raises(ValueError, match="GDAPI_E2E_EDITOR_MODE=.*expected headless or gui"):
        timing.validate_configuration()


def test_percentiles_and_json_preserve_success_samples(monkeypatch, tmp_path):
    measurements = timing.WaitTimings()
    for value in [1, 2, 3, 4, 5]:
        measurements.record("predicate", value)
    monkeypatch.setattr(timing, "TIMINGS", measurements)
    row = measurements.summary()["predicate"]
    assert row["count"] == 5
    assert row["p50_seconds"] == 3
    assert row["p95_seconds"] == pytest.approx(4.8)
    assert row["p99_seconds"] == pytest.approx(4.96)
    assert row["max_seconds"] == 5
    assert row["recommended_timeout_seconds"] == pytest.approx(14.88)
    measurements.record("singleton", .125)
    assert measurements.summary()["singleton"]["p99_seconds"] == .125
    path = tmp_path / "nested" / "waits.json"
    monkeypatch.setenv("GDAPI_E2E_EDITOR_MODE", "gui")
    timing.write_report(path, exitstatus=1, editor_starts=1)
    report = json.loads(path.read_text(encoding="utf-8"))
    assert report["groups"]["predicate"]["samples_seconds"] == [1, 2, 3, 4, 5]
    assert report["exitstatus"] == 1
    assert report["editor_starts"] == 1
    assert report["editor_mode"] == "gui"


def test_successful_wait_excludes_false_error_results_and_exceptions(monkeypatch):
    measurements = timing.WaitTimings()
    monkeypatch.setattr(timing, "TIMINGS", measurements)
    clock = iter([10, 12.5, 13, 14, 15, 16, 17])
    monkeypatch.setattr(timing.time, "monotonic", lambda: next(clock))
    assert timing.successful_wait("ok")(lambda: {"ok": True})() == {"ok": True}
    assert timing.successful_wait("false")(lambda: False)() is False
    assert timing.successful_wait("error")(lambda: {"ok": False})() == {"ok": False}
    def fail():
        raise RuntimeError("real failure")
    with pytest.raises(RuntimeError, match="real failure"):
        timing.successful_wait("raises")(fail)()
    assert measurements.samples == {"ok": [2.5]}


class Clock:
    def __init__(self):
        self.value = 0.0

    def monotonic(self):
        return self.value

    def sleep(self, seconds):
        self.value += seconds


@pytest.fixture
def wait_clock(monkeypatch):
    clock = Clock()
    measurements = timing.WaitTimings()
    monkeypatch.setattr(timing.time, "monotonic", clock.monotonic)
    monkeypatch.setattr(timing.time, "sleep", clock.sleep)
    monkeypatch.setattr(timing, "TIMINGS", measurements)
    return clock, measurements


def test_predicate_wait_measures_success_and_honors_configured_deadline(monkeypatch, wait_clock):
    clock, measurements = wait_clock
    monkeypatch.setenv("GDAPI_E2E_WAIT_TIMEOUT_SECONDS", ".2")
    runtime_helpers.wait_for(lambda: clock.value >= .1, interval=.05)
    assert measurements.samples["predicate"] == pytest.approx([.1])
    with pytest.raises(AssertionError, match="never became true"):
        runtime_helpers.wait_for(lambda: False, interval=.05)
    assert measurements.samples["predicate"] == pytest.approx([.1])
    assert clock.value >= .3


def test_scene_switch_wait_does_not_record_a_timeout(monkeypatch, wait_clock):
    clock, measurements = wait_clock
    monkeypatch.setenv("GDAPI_E2E_SCENE_TIMEOUT_SECONDS", ".1")
    monkeypatch.setattr(shared_fixture, "_current_scene_path", lambda env: "res://a.tscn")
    assert shared_fixture.wait_for_scene({}, "res://a.tscn") is True
    assert shared_fixture.wait_for_scene({}, "res://b.tscn") is False
    assert measurements.samples == {"scene_switch": [0.0]}
    assert clock.value == pytest.approx(.1)


def test_history_bridge_records_only_completed_success(monkeypatch, tmp_path, wait_clock):
    clock, measurements = wait_clock
    result = tmp_path / ".godot" / "gdapi-test-result.json"
    result.parent.mkdir()
    result.write_text('{"ok": true}', encoding="utf-8")
    assert history_helpers.wait_for_test_result({"project": tmp_path}) == {"ok": True}
    result.write_text('{"ok": false}', encoding="utf-8")
    assert history_helpers.wait_for_test_result({"project": tmp_path}) == {"ok": False}
    result.unlink()
    monkeypatch.setenv("GDAPI_E2E_UNDO_TIMEOUT_SECONDS", ".1")
    with pytest.raises(RuntimeError, match="never produced"):
        history_helpers.wait_for_test_result({"project": tmp_path})
    assert measurements.samples == {"undo_bridge": [0.0]}
    assert clock.value == pytest.approx(.1)




def test_runner_orders_file_before_engine_and_stops_on_failure(monkeypatch, tmp_path):
    calls = []
    def execute(command, **kwargs):
        calls.append((command, kwargs["env"]["GDAPI_E2E_TRANSPORT"]))
        return subprocess.CompletedProcess(command, 7)
    monkeypatch.setattr(check.subprocess, "run", execute)
    assert check.main(["--gate", "engine", "--gate", "file", "--artifact-dir", str(tmp_path)]) == 7
    assert len(calls) == 1
    assert calls[0][1] == "file"
    assert "not budget and not engine_transport and not real_renderer" in calls[0][0]




def test_runner_missing_executable_and_bad_configuration_are_nonzero(monkeypatch, tmp_path):
    def missing(*args, **kwargs):
        raise FileNotFoundError("cargo unavailable")
    monkeypatch.setattr(check.subprocess, "run", missing)
    assert check.main(["--gate", "clippy", "--artifact-dir", str(tmp_path)]) == 127
    monkeypatch.setenv("GDAPI_E2E_BUDGET_SECONDS", "nan")
    with pytest.raises(SystemExit) as exc:
        check.main(["--gate", "file"])
    assert exc.value.code == 2


def test_budget_uses_parent_wall_clock_not_child_summary(monkeypatch, tmp_path):
    monkeypatch.setenv("GDAPI_E2E_BUDGET_SECONDS", "360")
    ticks = iter([100, 461])
    monkeypatch.setattr(timing.time, "monotonic", lambda: next(ticks))
    report = tmp_path / "report.json"
    report.write_text('{"editor_starts":1,"exitstatus":0}', encoding="utf-8")
    def execute(command, **kwargs):
        assert kwargs["timeout"] == 390
        assert kwargs["env"]["GDAPI_E2E_TRANSPORT"] == "file"
        return subprocess.CompletedProcess(command, 0, "===== 400 passed in 0.01s =====", "")
    monkeypatch.setattr(subprocess, "run", execute)
    with pytest.raises(AssertionError, match="parent wall-clock 361.*360"):
        run_budget_session(tmp_path, report)


@pytest.mark.parametrize("exitcode,editor_starts", [(5, 1), (0, 2)])
def test_budget_rejects_child_failure_and_multiple_editors(monkeypatch, tmp_path, exitcode, editor_starts):
    ticks = iter([0, 1])
    monkeypatch.setattr(timing.time, "monotonic", lambda: next(ticks))
    report = tmp_path / "report.json"
    report.write_text(json.dumps({"editor_starts": editor_starts, "exitstatus": exitcode}), encoding="utf-8")
    monkeypatch.setattr(subprocess, "run", lambda command, **kwargs: subprocess.CompletedProcess(command, exitcode, "failed", ""))
    with pytest.raises(AssertionError):
        run_budget_session(tmp_path, report)


def test_mocked_waits_are_not_mixed_into_real_session_measurements(monkeypatch):
    from e2e import conftest as hooks
    from types import SimpleNamespace
    measurements = timing.WaitTimings()
    monkeypatch.setattr(hooks, "TIMINGS", measurements)
    hooks.pytest_runtest_setup(SimpleNamespace(fixturenames=["tmp_path", "monkeypatch"]))
    measurements.record("predicate", 999)
    assert measurements.samples == {}
    hooks.pytest_runtest_setup(SimpleNamespace(fixturenames=["m3_running", "m3_editor", "e2e_editor"]))
    measurements.record("predicate", .02)
    assert measurements.samples == {"predicate": [.02]}


@pytest.mark.parametrize("function,group,env_name,first,last", [
    ("wait_for_editor_playing", "runtime_playing", "GDAPI_E2E_PLAY_TIMEOUT_SECONDS",
     {"ok": True, "editor_playing": False},
     {"ok": True, "editor_playing": True}),
    ("wait_for_connected", "runtime_connect", "GDAPI_E2E_CONNECT_TIMEOUT_SECONDS",
     {"ok": True, "state": "connecting", "transport": "none"},
     {"ok": True, "state": "connected", "transport": "engine_debugger"}),
    ("wait_stopped", "runtime_stop", "GDAPI_E2E_STOP_TIMEOUT_SECONDS",
     {"ok": True, "state": "stopped", "pending": 1, "editor_playing": False},
     {"ok": True, "state": "stopped", "pending": 0, "editor_playing": False}),
])
def test_lifecycle_waits_measure_only_the_accepted_status(
    monkeypatch, wait_clock, function, group, env_name, first, last,
):
    clock, measurements = wait_clock
    monkeypatch.setenv(env_name, ".5")
    statuses = iter([first, last])
    result = subprocess.CompletedProcess([], 0, "", "")
    monkeypatch.setattr(
        runtime_helpers, "_poll_runtime_status",
        lambda env: (["exec", "runtime/status"], result, next(statuses)),
    )
    assert getattr(runtime_helpers, function)({}) == last
    assert measurements.samples == {group: [.1]}
    assert clock.value == pytest.approx(.1)


def test_invalid_transport_has_actionable_configuration_error(monkeypatch):
    monkeypatch.setenv("GDAPI_E2E_TRANSPORT", "automatic")
    with pytest.raises(ValueError, match="GDAPI_E2E_TRANSPORT=.*file or engine_debugger"):
        timing.validate_configuration()
