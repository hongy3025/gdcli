"""Successful-wait measurements and validated, explicit gate configuration."""
from __future__ import annotations

import json
import math
import os
import time
from functools import wraps
from pathlib import Path

# Defaults preserve the existing deadlines; telemetry never changes them.
DEFAULTS = {
    "GDAPI_E2E_BUDGET_SECONDS": 360.0,
    "GDAPI_E2E_SCENE_TIMEOUT_SECONDS": 5.0,
    "GDAPI_E2E_UNDO_TIMEOUT_SECONDS": 10.0,
    "GDAPI_E2E_WAIT_TIMEOUT_SECONDS": 15.0,
    "GDAPI_E2E_CONNECT_TIMEOUT_SECONDS": 60.0,
    "GDAPI_E2E_PLAY_TIMEOUT_SECONDS": 15.0,
    "GDAPI_E2E_STOP_TIMEOUT_SECONDS": 10.0,
    "GDAPI_E2E_METADATA_TIMEOUT_SECONDS": 45.0,
    "GDAPI_E2E_READY_TIMEOUT_SECONDS": 30.0,
    "GDAPI_E2E_PING_TIMEOUT_SECONDS": 180.0,
    "GDAPI_E2E_DEADLOCK_TIMEOUT_SECONDS": 180.0,
}


def positive_seconds(name: str, default: float | None = None) -> float:
    fallback = DEFAULTS[name] if default is None else default
    raw = os.environ.get(name, str(fallback))
    try:
        value = float(raw)
    except (TypeError, ValueError):
        value = float("nan")
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"{name}={raw!r}: expected a finite positive number of seconds; unset it to use {fallback:g}s")
    return value


def validate_configuration() -> None:
    for name in DEFAULTS:
        positive_seconds(name)
    transport = os.environ.get("GDAPI_E2E_TRANSPORT", "file")
    if transport not in ("file", "engine_debugger"):
        raise ValueError(f"GDAPI_E2E_TRANSPORT={transport!r}: expected file or engine_debugger")


def percentile(values: list[float], fraction: float) -> float:
    """Linear interpolation, including singleton samples (all units seconds)."""
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


class WaitTimings:
    def __init__(self) -> None:
        self.samples: dict[str, list[float]] = {}
        self.enabled = True

    def record(self, group: str, elapsed: float) -> None:
        if self.enabled:
            self.samples.setdefault(group, []).append(elapsed)

    def summary(self) -> dict:
        return {
            group: {
                "count": len(values),
                "p50_seconds": percentile(values, .50),
                "p95_seconds": percentile(values, .95),
                "p99_seconds": percentile(values, .99),
                "max_seconds": max(values),
                "recommended_timeout_seconds": percentile(values, .99) * 3,
                "samples_seconds": list(values),
            }
            for group, values in sorted(self.samples.items())
        }


TIMINGS = WaitTimings()


def successful_wait(group: str):
    """Measure real successful paths only; propagate failures without a sample."""
    def decorate(function):
        @wraps(function)
        def wrapped(*args, **kwargs):
            started = time.monotonic()
            result = function(*args, **kwargs)
            if result is not False and not (isinstance(result, dict) and result.get("ok") is False):
                TIMINGS.record(group, time.monotonic() - started)
            return result
        return wrapped
    return decorate


def write_report(path: Path, *, exitstatus: int, editor_starts: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "units": "seconds",
        "exitstatus": int(exitstatus),
        "editor_starts": editor_starts,
        "transport": os.environ.get("GDAPI_E2E_TRANSPORT", "file"),
        "thresholds": {name: positive_seconds(name) for name in DEFAULTS},
        "groups": TIMINGS.summary(),
    }
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
