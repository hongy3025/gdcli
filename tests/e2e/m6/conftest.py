"""M6 E2E fixtures — shared `e2e_editor` aliases and capability policy helpers.

The single Godot editor and unified project live in `tests/e2e/shared_fixture.py`,
re-exported through the root `tests/e2e/conftest.py` as `m6_editor*` and
friends. The local fixtures no longer start a new editor per module; they
return the shared session env and apply a per-test policy overlay through
`temporary_policy` so the capability tests can still deny individual routes.
"""

from __future__ import annotations

import concurrent.futures
import json
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

import pytest

_TESTS_DIR = Path(__file__).resolve().parents[2]
if str(_TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(_TESTS_DIR))

from e2e.m2.helpers import gdcli_bin, repo_root, require_godot_47, resolve_godot_bin  # noqa: E402
from e2e.m3.conftest import (  # noqa: E402
    command_doc,
    exec_error,
    exec_ok,
    project_run,
    project_stop,
)
from e2e.shared_fixture import (  # noqa: E402,F401
    m6_editor as session_m6_editor,
    m6_editor_bulk as session_m6_editor_bulk,
    m6_editor_eval as session_m6_editor_eval,
    m6_editor_network as session_m6_editor_network,
    m6_editor_process as session_m6_editor_process,
    temporary_policy,
)

M6_FIXTURE_SOURCE = repo_root() / "tests" / "fixtures" / "m6_project"

M6_HTTP_PORT: int = 18923

M6_EVAL_POLICY = {
    "version": 1,
    "capabilities": {
        "runtime_eval": {
            "enabled": True, "max_source_bytes": 16384,
            "allowed_input_keys": ["a", "b", "runtime_marker"],
        },
        "editor_eval": {
            "enabled": True, "max_source_bytes": 16384,
            "allowed_input_keys": ["a", "b", "runtime_marker"],
        },
        "process": {
            "enabled": True, "executables": ["sleep", "sleep.cmd", "echo_args", "echo_args.cmd", "echo_args.py"],
            "cwd_roots": ["res://tools"],
            "max_timeout_ms": 5000, "max_output_bytes": 65536,
        },
        "network": {
            "enabled": True, "schemes": ["http"], "hosts": ["127.0.0.1", "localhost"],
            "ports": [80, 443], "max_timeout_ms": 5000, "max_response_bytes": 1048576,
            "max_redirects": 5, "allow_private": True,
        },
    },
}

M6_BULK_POLICY = {
    "version": 1,
    "capabilities": {"bulk_files": {"enabled": True}},
}

M6_NETWORK_POLICY = {
    "version": 1,
    "capabilities": {
        "network": {
            "enabled": True,
            "schemes": ["http"],
            "hosts": ["127.0.0.1", "localhost"],
            "ports": [80, 443, M6_HTTP_PORT],
            "allow_private": True,
            "max_redirects": 5,
            "max_timeout_ms": 5000,
            "max_response_bytes": 1048576,
        },
    },
}

M6_PROCESS_POLICY = {
    "version": 1,
    "capabilities": {
        "process": {
            "enabled": True,
            "executables": ["sleep", "sleep.cmd", "echo_args", "echo_args.cmd", "echo_args.py"],
            "cwd_roots": ["res://tools"],
            "max_timeout_ms": 5000,
            "max_output_bytes": 65536,
        },
    },
}

# Default-deny policy: all capabilities disabled
M6_DEFAULT_DENY_POLICY = {
    "version": 1,
    "capabilities": {},
}


# ── module-scoped policy overlay fixtures ───────────────────────────────
# Each fixture wraps the session-scoped shared alias with a
# ``temporary_policy`` that applies the correct capability overlay for
# the test module.  The policy is restored to the default (all-enabled)
# when the fixture cleans up.


@pytest.fixture(scope="module")
def m6_editor(session_m6_editor: dict[str, Any]) -> dict[str, Any]:
    """Module-scoped alias with default-deny policy for contract tests."""
    with temporary_policy(session_m6_editor, M6_DEFAULT_DENY_POLICY):
        yield session_m6_editor


@pytest.fixture(scope="module")
def m6_editor_eval(session_m6_editor_eval: dict[str, Any]) -> dict[str, Any]:
    """Module-scoped alias with eval policy."""
    with temporary_policy(session_m6_editor_eval, M6_EVAL_POLICY):
        yield session_m6_editor_eval


@pytest.fixture(scope="module")
def m6_editor_process(session_m6_editor_process: dict[str, Any]) -> dict[str, Any]:
    """Module-scoped alias with process policy."""
    with temporary_policy(session_m6_editor_process, M6_PROCESS_POLICY):
        yield session_m6_editor_process


@pytest.fixture(scope="module")
def m6_editor_bulk(session_m6_editor_bulk: dict[str, Any]) -> dict[str, Any]:
    """Module-scoped alias with bulk_files policy."""
    with temporary_policy(session_m6_editor_bulk, M6_BULK_POLICY):
        yield session_m6_editor_bulk


@pytest.fixture(scope="module")
def m6_editor_network(session_m6_editor_network: dict[str, Any]) -> dict[str, Any]:
    """Module-scoped alias with network policy."""
    with temporary_policy(session_m6_editor_network, M6_NETWORK_POLICY):
        yield session_m6_editor_network


class _EchoHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/ok":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"payload-ok")
        elif self.path == "/large":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"x" * 2048)
            self.wfile.flush()
        elif self.path == "/delay":
            time.sleep(10)
            self.send_response(200)
            self.end_headers()
        elif self.path == "/redirect-ok":
            self.send_response(302)
            self.send_header("Location", "/ok")
            self.send_header("Connection", "close")
            self.end_headers()
        elif self.path == "/redirect-private":
            self.send_response(302)
            self.send_header("Location", "http://10.0.0.1/")
            self.send_header("Connection", "close")
            self.end_headers()
        elif self.path == "/redirect-loop":
            self.send_response(302)
            self.send_header("Location", "/redirect-loop")
            self.send_header("Connection", "close")
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass


class _ServerRef:
    def __init__(self, port: int) -> None:
        self.port = port

    def url(self, path: str) -> str:
        return f"http://127.0.0.1:{self.port}{path}"


@pytest.fixture(scope="module")
def local_http_server() -> _ServerRef:
    server = HTTPServer(("127.0.0.1", M6_HTTP_PORT), _EchoHandler)
    port: int = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield _ServerRef(port)
    finally:
        server.shutdown()


def latest_audit(env: dict[str, Any], route: str) -> dict[str, Any]:
    # Query with limit=1000 to capture all entries regardless of prior
    # module activity (M3 runtime tests can push 100+ entries).
    entries = exec_ok(env, "gdapi/audit/list", {"limit": 1000}).get("entries", [])
    matching = [e for e in entries if e.get("route") == route]
    if not matching:
        raise AssertionError(f"No audit entries found for route {route}")
    return matching[-1]


def audit_for_route(env: dict[str, Any], route: str) -> list[dict[str, Any]]:
    entries = exec_ok(env, "gdapi/audit/list", {"limit": 1000}).get("entries", [])
    return [e for e in entries if e.get("route") == route]


def _wait_for_game_running(env: dict[str, Any], timeout: float = 15.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last_status: dict[str, Any] = {}
    while time.monotonic() < deadline:
        status = exec_ok(env, "runtime/status")
        last_status = status
        if status.get("state") == "connected" and status.get("transport") != "none":
            return status
        time.sleep(0.2)
    raise RuntimeError(
        f"game never fully connected within {timeout}s (last status: {last_status})"
    )


def _wait_stopped(env: dict[str, Any], timeout: float = 10.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last_status: dict[str, Any] = {}
    while time.monotonic() < deadline:
        status = exec_ok(env, "runtime/status")
        last_status = status
        if status.get("state") == "stopped" and status.get("pending", 0) == 0:
            return status
        time.sleep(0.1)
    raise RuntimeError(
        f"game did not stop within {timeout}s (last status: {last_status})"
    )


@pytest.fixture(scope="module")
def m6_runtime_eval_running(m6_editor_eval: dict[str, Any]) -> dict[str, Any]:
    project_run(m6_editor_eval)
    _wait_for_game_running(m6_editor_eval)
    m6_editor_eval["game_attached"] = True
    try:
        yield m6_editor_eval
    finally:
        if m6_editor_eval.get("game_attached"):
            try:
                project_stop(m6_editor_eval)
                _wait_stopped(m6_editor_eval)
            finally:
                m6_editor_eval["game_attached"] = False


def _exec_raw(env: dict[str, Any], route: str, body: dict) -> dict[str, Any]:
    args = ["exec", route, "--project", str(env["project"]), "--data", json.dumps(body)]
    result = subprocess.run(
        [str(env["gdcli"]), "--json", *args],
        capture_output=True, encoding="utf-8", errors="replace",
        timeout=35,
    )
    for raw in (result.stdout, result.stderr):
        if not raw:
            continue
        for candidate in (raw.strip(), raw.split(": ", 1)[-1].strip()):
            try:
                payload = json.loads(candidate)
                if isinstance(payload, dict):
                    return payload
            except json.JSONDecodeError:
                continue
    return {"code": "unknown", "error": result.stderr or result.stdout}


def start_async_exec(
    env: dict[str, Any], route: str, body: dict,
) -> concurrent.futures.Future[dict[str, Any]]:
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    future = executor.submit(_exec_raw, env, route, body)
    future._executor = executor
    return future


def stop_game(env: dict[str, Any]) -> dict[str, Any]:
    project_stop(env)
    result = _wait_stopped(env)
    env["game_attached"] = False
    return result


# ── bulk file test helpers ─────────────────────────────────────────────

def project_file(env: dict[str, Any], rel: str) -> Path:
    return Path(env["project"]) / rel


def replace_plan(
    env: dict[str, Any], root: str, find: str, replace: str,
) -> dict[str, Any]:
    plan = exec_ok(env, "filesystem/batch/replace", {
        "root": root, "find": find, "replace": replace,
        "dry_run": True, "force": True,
    })
    plan["_root"] = root
    plan["_find"] = find
    plan["_replace"] = replace
    return plan


def apply_replace(env: dict[str, Any], plan: dict) -> dict[str, Any]:
    return _exec_raw(env, "filesystem/batch/replace", {
        "root": plan["_root"], "find": plan["_find"],
        "replace": plan["_replace"],
        "plan_hash": plan["plan_hash"], "force": True,
    })


def inject_apply_failure(env: dict[str, Any], fail_after: int) -> None:
    exec_ok(env, "filesystem/write", {
        "path": "res://.gdapi-debug-apply-fail",
        "content": str(fail_after),
        "force": True,
    })


def bulk_digest(env: dict[str, Any]) -> str:
    import hashlib
    bulk_dir = project_file(env, "bulk")
    if not bulk_dir.is_dir():
        return hashlib.sha256(b"").hexdigest()
    files = sorted(bulk_dir.iterdir(), key=lambda p: p.name)
    h = hashlib.sha256()
    for f in files:
        if f.is_file():
            h.update(f.name.encode())
            h.update(b"\x00")
            h.update(f.read_bytes())
    return h.hexdigest()


def delete_plan(env: dict[str, Any], paths: list[str]) -> dict[str, Any]:
    plan = exec_ok(env, "filesystem/batch/delete", {
        "paths": paths, "dry_run": True, "force": True,
    })
    plan["_paths"] = paths
    return plan


def apply_delete(env: dict[str, Any], plan: dict) -> dict[str, Any]:
    return _exec_raw(env, "filesystem/batch/delete", {
        "paths": plan["_paths"],
        "plan_hash": plan["plan_hash"], "force": True,
    })


__all__ = [
    "M6_BULK_POLICY",
    "M6_DEFAULT_DENY_POLICY",
    "M6_EVAL_POLICY",
    "M6_NETWORK_POLICY",
    "M6_PROCESS_POLICY",
    "apply_delete",
    "apply_replace",
    "audit_for_route",
    "bulk_digest",
    "command_doc",
    "delete_plan",
    "exec_error",
    "exec_ok",
    "inject_apply_failure",
    "latest_audit",
    "local_http_server",
    "m6_editor",
    "m6_editor_bulk",
    "m6_editor_eval",
    "m6_editor_network",
    "m6_editor_process",
    "m6_runtime_eval_running",
    "project_file",
    "project_run",
    "project_stop",
    "replace_plan",
    "start_async_exec",
    "stop_game",
    "temporary_policy",
]
