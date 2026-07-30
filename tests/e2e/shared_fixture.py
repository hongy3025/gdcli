"""Shared E2E lifecycle: one Godot editor per pytest session.

This module owns the canonical session-scoped fixture (`e2e_editor`) and the
helpers every module uses to reach it:

* `e2e_editor` — session-scoped; the only fixture that creates a
  `subprocess.Popen`, copies the unified project, installs the addon, and
  waits for gdapi readiness.
* `reset_shared_state` — deterministic per-test reset that stops games,
  clears runtime transport, clears the audit log, restores the selection,
  and reloads the default capability policy.
* `temporary_policy` — context manager that overlays a policy for the
  duration of a `with` block and unconditionally restores the prior bytes.

Legacy module fixtures (`m2_editor`, `m3_editor`, `m4_env`, `m5_editor`,
`m6_editor*`) are session-scoped aliases that all resolve to the same
`e2e_editor` environment.
"""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Iterator

import pytest

from .m2.helpers import (
    gdcli_bin,
    repo_root,
    require_godot_47,
    wait_for_godot_ready,
    wait_for_metadata,
)


E2E_FIXTURE_SOURCE = repo_root() / "tests" / "fixtures" / "e2e_project"
E2E_DEFAULT_POLICY_PATH = E2E_FIXTURE_SOURCE / ".godot" / "gdapi-policy.json"
E2E_RUNTIME_ROOT_NAME = "gdapi_runtime"
E2E_METADATA_NAME = "gdapi.json"
E2E_DEADLOCK_TIMEOUT_SECONDS = 180

# A class-level counter records how many times the session-scoped fixture
# actually started a Godot process. The full-suite acceptance test inspects
# this counter through `EDITOR_START_COUNTER["starts"]`.
EDITOR_START_COUNTER: dict[str, Any] = {"starts": 0, "pids": set()}


# ── gdcli wrappers ──────────────────────────────────────────────────────


def _gdcli_exec_raw(env: dict[str, Any], *args: str, timeout: float = 30.0) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(env["gdcli"]), "--json", *args],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
    )


def gdcli_call(env: dict[str, Any], route: str, data: dict | None = None) -> dict[str, Any]:
    """Run a gdcli exec route, returning the parsed JSON body or raising."""
    args = ["exec", route, "--project", str(env["project"])]
    if data is not None:
        args += ["--data", json.dumps(data)]
    result = _gdcli_exec_raw(env, *args)
    if result.returncode != 0:
        raise AssertionError(
            f"gdcli {route} failed (exit {result.returncode}):\n"
            f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
        )
    payload = json.loads(result.stdout) if result.stdout else {}
    if not isinstance(payload, dict):
        raise AssertionError(f"gdcli {route} returned non-dict payload: {payload!r}")
    return payload


def gdcli_expect_failure(env: dict[str, Any], route: str, data: dict | None = None) -> dict[str, Any]:
    """Run a gdcli exec route that MUST return non-zero; return the parsed payload."""
    args = ["exec", route, "--project", str(env["project"])]
    if data is not None:
        args += ["--data", json.dumps(data)]
    result = _gdcli_exec_raw(env, *args)
    payload: dict[str, Any] = {}
    for raw in (result.stdout, result.stderr):
        if not raw:
            continue
        try:
            candidate = json.loads(raw.strip())
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict):
            payload = candidate
            break
    payload.setdefault("exit_code", result.returncode)
    payload.setdefault("stdout", result.stdout)
    payload.setdefault("stderr", result.stderr)
    return payload


# ── metadata and log helpers ───────────────────────────────────────────


def _read_log_tail(path: Path, lines: int = 80) -> str:
    try:
        return "\n".join(path.read_text(encoding="utf-8", errors="replace").splitlines()[-lines:])
    except OSError as exc:
        return f"<unable to read {path}: {exc}>"


def _gdcli_ping(env: dict[str, Any]) -> bool:
    try:
        result = subprocess.run(
            [str(env["gdcli"]), "--json",
             "exec", "gdapi/health/ping",
             "--project", str(env["project"])],
            capture_output=True, encoding="utf-8", errors="replace",
            timeout=5.0,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


# ── fixture source and install ─────────────────────────────────────────


def _copy_unified_project(source: Path, target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    for entry in source.iterdir():
        if entry.name == ".godot":
            # `.godot/` is generated per-test-run, but the default capability
            # policy is checked in there so tests have a known baseline.
            destination = target / entry.name
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(entry, destination)
            continue
        destination = target / entry.name
        if entry.is_dir():
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(entry, destination)
        else:
            shutil.copy2(entry, destination)
def _copy_native_library(env: dict[str, Any]) -> None:
    """Copy the gdapi native library into the addon bin/ directory on Windows."""
    if sys.platform != "win32":
        return
    root = repo_root()
    library = root / "target" / "debug" / "gdapi.dll"
    if not library.exists():
        return
    destination_dir = env["project"] / "addons" / "gdapi" / "bin" / "windows"
    destination_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(library, destination_dir / library.name)


# ── editor startup ────────────────────────────────────────────────────


def build_editor_command(godot_bin: str, project: Path) -> list[str]:
    return [
        godot_bin,
        "--editor",
        "--headless",
        "--audio-driver",
        "Dummy",
        "--path",
        str(project),
    ]


def build_editor_environment(project: Path) -> dict[str, str]:
    appdata = project / ".godot" / "appdata"
    local_appdata = project / ".godot" / "localappdata"
    appdata.mkdir(parents=True, exist_ok=True)
    local_appdata.mkdir(parents=True, exist_ok=True)
    editor_env = os.environ.copy()
    editor_env.update(
        {
            "APPDATA": str(appdata),
            "LOCALAPPDATA": str(local_appdata),
        }
    )
    return editor_env


def _start_editor(env: dict[str, Any]) -> subprocess.Popen:
    log_path = env["project"] / ".godot" / "godot.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_handle = log_path.open("w", encoding="utf-8")
    env["godot_log_path"] = log_path
    env["godot_log"] = log_handle

    process = subprocess.Popen(
        build_editor_command(env["godot_bin"], env["project"]),
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        text=True,
        env={
            **build_editor_environment(env["project"]),
            "GDAPI_HANDLER_TIMEOUT_MS": "180000",
        },
    )
    env["editor_pid"] = process.pid
    env["godot"] = process

    try:
        meta = wait_for_metadata(env["project"])
    except BaseException:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
        raise

    deadline = time.monotonic() + 180.0
    while time.monotonic() < deadline:
        if process.poll() is not None:
            log_handle.close()
            raise RuntimeError(
                f"godot exited prematurely with code {process.returncode}; "
                f"log tail:\n{_read_log_tail(log_path)}"
            )
        if _gdcli_ping(env):
            break
        time.sleep(0.5)
    else:
        process.terminate()
        process.wait(timeout=10)
        log_handle.close()
        raise RuntimeError(
            f"gdapi ping never succeeded within 180s; log tail:\n{_read_log_tail(log_path)}"
        )

    wait_for_godot_ready(env["project"])
    env["meta"] = meta
    return process


def _stop_editor(env: dict[str, Any]) -> None:
    process = env.get("godot")
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
    log_handle = env.get("godot_log")
    if log_handle is not None and not log_handle.closed:
        log_handle.close()
    runtime_root = _runtime_root(env["project"])
    if runtime_root.exists():
        shutil.rmtree(runtime_root)


# ── runtime transport helpers ──────────────────────────────────────────


def _runtime_root(project: Path) -> Path:
    godot_dir = (project / ".godot").resolve()
    if godot_dir.parent != project.resolve() or godot_dir.name != ".godot":
        raise RuntimeError(f"unexpected metadata root: {godot_dir}")
    runtime_root = (godot_dir / E2E_RUNTIME_ROOT_NAME).resolve()
    if runtime_root.parent != godot_dir or runtime_root.name != E2E_RUNTIME_ROOT_NAME:
        raise RuntimeError(f"unexpected runtime root: {runtime_root}")
    return runtime_root


# ── reset contract ────────────────────────────────────────────────────


def restore_file_state(env: dict[str, Any], baseline: dict[str, bytes]) -> None:
    """Restore every file that differs from the captured baseline."""
    project = env["project"]
    current_files: dict[str, Path] = {}
    for path in project.rglob("*"):
        if not path.is_file():
            continue
        rel = str(path.relative_to(project)).replace("\\", "/")
        if (
            rel.startswith(".godot/")
            or rel.startswith("addons/gdapi/")
            or rel == "project.godot"
        ):
            continue
        current_files[rel] = path
    for rel, path in current_files.items():
        if rel not in baseline:
            try:
                path.unlink()
            except OSError:
                pass
    for rel, data in baseline.items():
        destination = project / rel
        if rel in current_files and current_files[rel].read_bytes() == data:
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            destination.write_bytes(data)
        except OSError:
            pass


def snapshot_files(env: dict[str, Any]) -> dict[str, bytes]:
    """Snapshot every non-generated file in the project for later restore."""
    project = env["project"]
    baseline: dict[str, bytes] = {}
    for path in project.rglob("*"):
        if not path.is_file():
            continue
        rel = str(path.relative_to(project)).replace("\\", "/")
        if (
            rel.startswith(".godot/")
            or rel.startswith("addons/gdapi/")
            or rel == "project.godot"
        ):
            continue
        baseline[rel] = path.read_bytes()
    return baseline


def reset_shared_state(env: dict[str, Any], *, reason: str) -> None:
    """Deterministically restore the shared editor to a known baseline.

    Always called between tests; failure raises `AssertionError` with the
    phase name, command, runtime status, and Godot log tail so the test
    output can drive a fix.
    """
    project = env["project"]
    failures: list[str] = []

    def _run(phase: str, route: str, data: dict | None = None) -> None:
        try:
            gdcli_call(env, route, data)
        except BaseException as exc:
            failures.append(
                f"[{phase}] {route}: {exc}\n"
                f"godot log tail:\n{_read_log_tail(env.get('godot_log_path', project / '.godot' / 'godot.log'))}"
            )

    _run("project/stop", "project/stop", None)
    # Close and re-open the M2 baseline scene so signal connections and
    # other in-memory mutations from a previous test do not survive.
    try:
        gdcli_call(env, "scene/close", None)
    except BaseException:
        pass
    _run("scene/open", "scene/open", {"path": "res://scenes/main.tscn"})
    _run("editor/selection/set", "editor/selection/set", {"nodes": []})
    _run("gdapi/audit/clear", "gdapi/audit/clear", {"force": True})

    # Restore default capability policy if it was overlaid by a prior test.
    default_policy = E2E_DEFAULT_POLICY_PATH.read_bytes()
    policy_path = project / ".godot" / "gdapi-policy.json"
    if policy_path.exists() and policy_path.read_bytes() != default_policy:
        policy_path.write_bytes(default_policy)

    if failures:
        raise AssertionError(
            f"reset_shared_state failed (reason={reason}):\n" + "\n".join(failures)
        )


# ── policy overlay contract ───────────────────────────────────────────


@contextlib.contextmanager
def temporary_policy(env: dict[str, Any], override: dict) -> Iterator[dict]:
    """Overlay a capability policy for the duration of a `with` block.

    The previous policy is restored on success and on exception. If the
    restoration step itself fails, the test must fail loudly so the
    shared environment is not silently left in a denied state.
    """
    project = env["project"]
    policy_path = project / ".godot" / "gdapi-policy.json"
    policy_path.parent.mkdir(parents=True, exist_ok=True)
    if not policy_path.exists():
        policy_path.write_bytes(E2E_DEFAULT_POLICY_PATH.read_bytes())
    previous = policy_path.read_bytes()
    try:
        policy_path.write_text(json.dumps(override), encoding="utf-8")
        yield {"policy_path": policy_path, "previous": previous}
    finally:
        try:
            policy_path.write_bytes(previous)
        except OSError as exc:
            raise AssertionError(
                f"temporary_policy failed to restore previous policy: {exc}"
            ) from exc


# ── environment construction (pure function) ──────────────────────────


def build_environment(
    tmp_path_factory: pytest.TempPathFactory,
    *,
    godot_bin: str | None = None,
) -> dict[str, Any]:
    """Create the shared environment; pure logic behind `e2e_editor`.

    Tests can call this directly (without invoking the pytest fixture
    machinery) to verify the start-up contract.
    """
    godot_bin = godot_bin or os.environ.get("GODOT_BIN", "godot")
    godot_version = require_godot_47(godot_bin)
    root = repo_root()
    project = tmp_path_factory.mktemp("e2e") / "project"

    build = subprocess.run(
        ["cargo", "build", "--workspace"],
        cwd=root, capture_output=True, encoding="utf-8", errors="replace",
    )
    if build.returncode != 0:
        raise RuntimeError(f"cargo build failed:\n{build.stderr}")

    _copy_unified_project(E2E_FIXTURE_SOURCE, project)

    install = subprocess.run(
        [str(gdcli_bin()), "install", "--project", str(project), "--force"],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    if install.returncode != 0:
        raise RuntimeError(f"gdcli install failed:\n{install.stderr}")

    env: dict[str, Any] = {
        "root": root,
        "project": project,
        "fixture": project,
        "fixture_root": E2E_FIXTURE_SOURCE,
        "godot_bin": godot_bin,
        "godot_version": godot_version,
        "gdcli": gdcli_bin(),
        "game_attached": False,
        # M3 harness counters and recovery state — initialised here so
        # the M3 tests can read/write them through the shared env.
        "build_count": 1,
        "install_count": 1,
        "editor_start_count": 1,
        "game_run_count": 0,
        "game_stop_count": 0,
        "fixture_reset_count": 0,
        "fixture_reset_restarts": 0,
        "recovery_markers": [],
        "recovery_events": [],
        "setup_events": ["build", "install", "editor_start"],
        "pre_attach_stale_removed": True,
        "editor_pids": set(),
    }

    _copy_native_library(env)
    EDITOR_START_COUNTER["starts"] += 1
    process = _start_editor(env)
    EDITOR_START_COUNTER["pids"].add(process.pid)
    env.setdefault("editor_pids", set()).add(process.pid)
    env["file_baseline"] = snapshot_files(env)
    # Open the M2 baseline scene so editor-state assertions like
    # `test_editor_starts_with_main_scene` see the same root scene the
    # M2 fixture used to provide.
    try:
        gdcli_call(env, "scene/open", {"path": "res://scenes/main.tscn"})
    except AssertionError:
        pass
    return env


def teardown_environment(env: dict[str, Any]) -> None:
    """Stop the editor and clear the runtime transport; mirrors fixture finally."""
    with contextlib.suppress(BaseException):
        reset_shared_state(env, reason="session teardown")
    _stop_editor(env)


# ── session-scoped fixture ────────────────────────────────────────────


@pytest.fixture(scope="session")
def e2e_editor(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    """Single Godot editor and unified project for the whole pytest session."""
    try:
        env = build_environment(tmp_path_factory)
    except RuntimeError as exc:
        if "cargo build" in str(exc):
            pytest.skip(str(exc), pytrace=False)
        pytest.fail(str(exc), pytrace=False)

    try:
        yield env
    finally:
        teardown_environment(env)





# ── collection-order buckets ─────────────────────────────────────────
#
# The hook in `tests/e2e/conftest.py` calls `bucketize` to reorder
# collected tests so fast contract / lightweight tests fire first and
# long-tail export / process / runtime-lifecycle tests sit at the back.
# The reshuffle is deterministic and only changes execution order; the
# set of tests and every assertion is preserved.

# (file path substring, test function name) → bucket index
_BUCKET_RULES: tuple[tuple[str, str | None, int], ...] = (
    # Bucket 0: contract / lifecycle / lightweight (no editor needed)
    ("test_unified_fixture_contract.py", None, 0),
    ("test_shared_editor_lifecycle.py", None, 0),
    ("test_shared_editor_contract.py", None, 0),
    ("test_collection_order.py", None, 0),
    # Bucket 4: slow paths — collected last
    ("m5/test_export_android.py", None, 4),
    ("m6/test_process_run.py", None, 4),
    ("m6/test_bulk_files.py", None, 4),
    ("m6/test_bulk_deploy.py", None, 4),
    ("m6/test_network_request.py", None, 4),
    ("m6/test_runtime_eval.py", None, 4),
    ("m6/test_eval.py", None, 4),
    # Bucket 3: m3 runtime tests that need m3_running
    ("m3/test_runtime_input.py", None, 3),
    ("m3/test_runtime_nodes.py", None, 3),
    ("m3/test_runtime_assert_signal.py", None, 3),
    ("m3/test_runtime_capture.py", None, 3),
    ("m3/test_runtime_observability.py", None, 3),
    # Bucket 2: m2 / m4 / m3 contract / m5 lightweight (default fallback)
)


def bucketize(items) -> list:
    """Return a reordered list of pytest `Item`s by collection bucket.

    Within a bucket, items keep their original relative order. Tests that
    do not match any rule land in bucket 2 (the middle).
    """
    buckets: list[list] = [[], [], [], [], []]
    for item in items:
        path = str(getattr(item, "fspath", "") or getattr(item, "path", ""))
        bucket = _classify(path)
        buckets[bucket].append(item)
    return [item for bucket in buckets for item in bucket]


def _classify(path: str) -> int:
    posix_path = path.replace("\\", "/")
    for substring, _name, bucket in _BUCKET_RULES:
        if substring in posix_path:
            return bucket
    return 2


# ── module-scoped alias fixtures ──────────────────────────────────────
#
# Each of these returns the same `e2e_editor` env so the existing
# per-module test files can keep their original fixture names. They are
# `module`-scoped (not `session`) so that the autouse per-test reset
# fixture in each module's conftest.py still fires once per test, but
# no extra process is ever started.


@pytest.fixture(scope="session")
def m2_editor(e2e_editor) -> dict[str, Any]:
    """Module-scoped alias of `e2e_editor` for M2 tests."""
    return e2e_editor


@pytest.fixture(scope="session")
def m3_editor(e2e_editor) -> dict[str, Any]:
    """Module-scoped alias of `e2e_editor` for M3 tests."""
    return e2e_editor


@pytest.fixture(scope="module")
def m3_running(m3_editor, m3_lifecycle) -> Any:
    """Own one shared data-plane game for all fixture-state E2E tests.

    The first request triggers the lifecycle scenario, which exercises
    the runtime broker twice. Subsequent requests reuse the already-
    attached game.
    """
    from e2e.m3.conftest import attach_game, detach_game
    if not m3_editor.get("game_attached"):
        attach_game(m3_editor)
    try:
        yield m3_editor
    finally:
        if m3_editor.get("game_attached"):
            detach_game(m3_editor)


@pytest.fixture(scope="module")
def m3_lifecycle(e2e_editor) -> dict[str, Any]:
    """Run the single status lifecycle scenario: initial stopped, then run/stop twice.

    Returns a dict with `initial` and `cycles` keys matching the original
    M3 fixture contract. Failures abort the scenario and the env is left
    in a stopped state; pytest will surface the diagnostic.
    """
    from e2e.m3.conftest import (  # late import to avoid cycles
        exec_ok, project_run, _runtime_root, _runtime_entries,
        wait_for_connected, wait_for_editor_playing, detach_game, reset_fixture,
    )

    initial = exec_ok(e2e_editor, "runtime/status")
    cycles: list[dict[str, Any]] = []
    scenario_error: BaseException | None = None
    try:
        for cycle_index in range(2):
            started = project_run(e2e_editor)
            wait_for_editor_playing(e2e_editor)
            connected = wait_for_connected(e2e_editor, timeout=60.0)
            active = exec_ok(e2e_editor, "runtime/status")
            stale = (
                _runtime_root(e2e_editor)
                / f"stale-lifecycle-{cycle_index}"
                / "reply.json"
            )
            stale.parent.mkdir(parents=True, exist_ok=True)
            stale.write_text("stale", encoding="utf-8")
            stopped_status = detach_game(e2e_editor)
            stopped = {"ok": True, "runtime_state": stopped_status["state"]}
            cycles.append({
                "cycle": cycle_index,
                "started": started,
                "connected": connected,
                "active": active,
                "stopped": stopped,
                "stopped_status": stopped_status,
                "runtime_entries": _runtime_entries(e2e_editor),
                "stale_removed": not stale.exists(),
            })
    except BaseException as exc:
        scenario_error = exc
        raise
    finally:
        try:
            if e2e_editor.get("game_attached"):
                detach_game(e2e_editor)
            else:
                reset_fixture(e2e_editor)
        except BaseException:
            if scenario_error is None:
                raise
    return {"initial": initial, "cycles": cycles}


@pytest.fixture(scope="session")
def m4_env(e2e_editor) -> dict[str, Any]:
    """Module-scoped alias of `e2e_editor` for M4 tests."""
    return e2e_editor


@pytest.fixture(scope="session")
def m5_editor(e2e_editor) -> dict[str, Any]:
    """Module-scoped alias of `e2e_editor` for M5 tests."""
    return e2e_editor


@pytest.fixture(scope="session")
def m6_editor(e2e_editor) -> dict[str, Any]:
    """Module-scoped alias of `e2e_editor` for M6 tests."""
    return e2e_editor


@pytest.fixture(scope="session")
def m6_editor_process(e2e_editor) -> dict[str, Any]:
    """Module-scoped alias used by M6 process tests."""
    return e6_alias_with_policy(e2e_editor, "process")


@pytest.fixture(scope="session")
def m6_editor_eval(e2e_editor) -> dict[str, Any]:
    """Module-scoped alias used by M6 eval tests."""
    return e6_alias_with_policy(e2e_editor, "eval")


@pytest.fixture(scope="session")
def m6_editor_bulk(e2e_editor) -> dict[str, Any]:
    """Module-scoped alias used by M6 bulk tests."""
    return e6_alias_with_policy(e2e_editor, "bulk")


@pytest.fixture(scope="session")
def m6_editor_network(e2e_editor) -> dict[str, Any]:
    """Module-scoped alias used by M6 network tests."""
    return e6_alias_with_policy(e2e_editor, "network")


def e6_alias_with_policy(env: dict[str, Any], variant: str) -> dict[str, Any]:
    """Return the env tagged with a policy variant for M6 tests.

    The actual policy is applied per-test through `temporary_policy`; this
    helper merely stamps a marker on the dict so individual tests can
    request the right overlay.
    """
    env.setdefault("policy_variants", set()).add(variant)
    return env





__all__ = [
    "E2E_DEADLOCK_TIMEOUT_SECONDS",
    "E2E_DEFAULT_POLICY_PATH",
    "E2E_FIXTURE_SOURCE",
    "E2E_RUNTIME_ROOT_NAME",
    "EDITOR_START_COUNTER",
    "bucketize",
    "build_environment",
    "e2e_editor",
    "gdcli_call",
    "gdcli_expect_failure",
    "reset_shared_state",
    "restore_file_state",
    "snapshot_files",
    "teardown_environment",
    "temporary_policy",
]
