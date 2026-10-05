"""M6 E2E fixtures — module-scoped aliases of the shared session editor.

The single Godot editor and unified project live in `tests/e2e/shared_fixture.py`,
re-exported through the root `tests/e2e/conftest.py` as `m6_editor*` and
friends. The local fixtures no longer start a new editor per module and no
longer overlay a capability policy; they return the shared session env as-is.
"""

from __future__ import annotations

import concurrent.futures
import json
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import pytest

_TESTS_DIR = Path(__file__).resolve().parents[2]
if str(_TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(_TESTS_DIR))

from e2e.m3.conftest import (  # noqa: E402
    command_doc,
    exec_error,
    exec_ok,
)
from e2e.shared_fixture import (  # noqa: E402,F401
    m6_editor as session_m6_editor,
    m6_editor_bulk as session_m6_editor_bulk,
    m6_editor_eval as session_m6_editor_eval,
    m6_editor_network as session_m6_editor_network,
    m6_editor_process as session_m6_editor_process,
)


M6_HTTP_PORT: int = 18923



@pytest.fixture(scope="module")
def m6_editor(session_m6_editor: dict[str, Any]) -> dict[str, Any]:
    """Module-scoped alias of the shared editor (no capability overlay)."""
    return session_m6_editor


@pytest.fixture(scope="module")
def m6_editor_eval(session_m6_editor_eval: dict[str, Any]) -> dict[str, Any]:
    """Module-scoped alias of the shared editor (no capability overlay)."""
    return session_m6_editor_eval


@pytest.fixture(scope="module")
def m6_editor_process(session_m6_editor_process: dict[str, Any]) -> dict[str, Any]:
    """Module-scoped alias of the shared editor (no capability overlay)."""
    return session_m6_editor_process


@pytest.fixture(scope="module")
def m6_editor_bulk(session_m6_editor_bulk: dict[str, Any]) -> dict[str, Any]:
    """Module-scoped alias of the shared editor (no capability overlay)."""
    return session_m6_editor_bulk


@pytest.fixture(scope="module")
def m6_editor_network(session_m6_editor_network: dict[str, Any]) -> dict[str, Any]:
    """Module-scoped alias of the shared editor (no capability overlay)."""
    return session_m6_editor_network


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
            self.send_header("Content-Length", "2048")
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
    server = ThreadingHTTPServer(("127.0.0.1", M6_HTTP_PORT), _EchoHandler)
    port: int = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield _ServerRef(port)
    finally:
        server.shutdown()
        server.server_close()


def latest_audit(env: dict[str, Any], route: str, *, since: int = 0) -> dict[str, Any]:
    matching = audit_for_route(env, route, since=since)
    if not matching:
        raise AssertionError(f"No audit entries found for route {route} after seq {since}")
    return matching[-1]


def audit_for_route(
    env: dict[str, Any], route: str, *, since: int = 0,
) -> list[dict[str, Any]]:
    entries = exec_ok(env, "gdapi/audit/list", {"since": since, "limit": 1000}).get("entries", [])
    return [e for e in entries if e.get("route") == route]


def audit_cursor(env: dict[str, Any], route: str) -> int:
    """Use retained sequence numbers, not list lengths that shift as the log fills."""
    return max((entry["seq"] for entry in audit_for_route(env, route)), default=0)




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




# ── bulk file test helpers ─────────────────────────────────────────────

def project_file(env: dict[str, Any], rel: str) -> Path:
    return Path(env["project"]) / rel


def replace_plan(
    env: dict[str, Any], root: str, find: str, replace: str,
) -> dict[str, Any]:
    plan = exec_ok(env, "filesystem/batch/replace", {
        "root": root, "find": find, "replace": replace,
        "dry_run": True,
    })
    plan["_root"] = root
    plan["_find"] = find
    plan["_replace"] = replace
    return plan


def apply_replace(env: dict[str, Any], plan: dict) -> dict[str, Any]:
    return _exec_raw(env, "filesystem/batch/replace", {
        "root": plan["_root"], "find": plan["_find"],
        "replace": plan["_replace"],
        "plan_hash": plan["plan_hash"],
    })


def inject_apply_failure(env: dict[str, Any], fail_after: int) -> None:
    exec_ok(env, "filesystem/write", {
        "path": "res://.gdapi-debug-apply-fail",
        "content": str(fail_after),
    })


def inject_recover_failure(env: dict[str, Any], fail_after: int) -> None:
    exec_ok(env, "filesystem/write", {
        "path": "res://.gdapi-debug-recover-fail",
        "content": str(fail_after),
    })


def clear_recover_failure(env: dict[str, Any]) -> None:
    project_file(env, ".gdapi-debug-recover-fail").unlink(missing_ok=True)


def delete_plan(env: dict[str, Any], paths: list[str]) -> dict[str, Any]:
    plan = exec_ok(env, "filesystem/batch/delete", {
        "paths": paths, "dry_run": True,
    })
    plan["_paths"] = paths
    return plan


def apply_delete(env: dict[str, Any], plan: dict) -> dict[str, Any]:
    return _exec_raw(env, "filesystem/batch/delete", {
        "paths": plan["_paths"],
        "plan_hash": plan["plan_hash"],
    })


__all__ = [
    "apply_delete",
    "apply_replace",
    "audit_cursor",
    "audit_for_route",
    "clear_recover_failure",
    "command_doc",
    "delete_plan",
    "exec_error",
    "exec_ok",
    "inject_apply_failure",
    "inject_recover_failure",
    "latest_audit",
    "local_http_server",
    "m6_editor",
    "m6_editor_bulk",
    "m6_editor_eval",
    "m6_editor_network",
    "m6_editor_process",
    "project_file",
    "replace_plan",
    "start_async_exec",
]
