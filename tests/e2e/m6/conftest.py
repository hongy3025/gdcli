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

from e2e.m2.helpers import gdcli_bin, repo_root, require_godot_47, resolve_godot_bin
from e2e.m3.conftest import attach_editor, command_doc, exec_error, exec_ok, detach_editor, project_run, project_stop

M6_FIXTURE_SOURCE = repo_root() / "tests" / "fixtures" / "m6_project"

M6_HTTP_PORT: int = 18923

M6_EVAL_POLICY = {
    "version": 1,
    "capabilities": {
        "runtime_eval": {
            "enabled": True, "max_source_bytes": 16384,
            "allowed_input_keys": ["runtime_marker"],
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


@pytest.fixture(scope="module")
def m6_editor(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    godot_bin = resolve_godot_bin()
    require_godot_47(godot_bin)
    project = tmp_path_factory.mktemp("m6_editor") / "project"
    shutil.copytree(M6_FIXTURE_SOURCE, project)
    install = subprocess.run(
        [str(gdcli_bin()), "install", "--project", str(project), "--force"],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    assert install.returncode == 0, install.stderr
    log_path = project / ".godot" / "godot.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_handle = log_path.open("w", encoding="utf-8")
    env: dict[str, Any] = {"project": project, "godot_bin": godot_bin,
                            "gdcli": gdcli_bin(), "godot_log": log_handle,
                            "godot_log_path": log_path}
    godot, meta = attach_editor(project, godot_bin, log_handle)
    env.update({"godot": godot, "meta": meta})
    try:
        yield env
    finally:
        detach_editor(env)
        log_handle.close()


def latest_audit(env: dict[str, Any], route: str) -> dict[str, Any]:
    entries = exec_ok(env, "gdapi/audit/list", {"limit": 100}).get("entries", [])
    matching = [e for e in entries if e.get("route") == route]
    if not matching:
        raise AssertionError(f"No audit entries found for route {route}")
    return matching[-1]


def audit_for_route(env: dict[str, Any], route: str) -> list[dict[str, Any]]:
    entries = exec_ok(env, "gdapi/audit/list", {"limit": 100}).get("entries", [])
    return [e for e in entries if e.get("route") == route]


@pytest.fixture(scope="module")
def m6_editor_process(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    godot_bin = resolve_godot_bin()
    require_godot_47(godot_bin)
    project = tmp_path_factory.mktemp("m6_editor_process") / "project"
    shutil.copytree(M6_FIXTURE_SOURCE, project)
    policy_dir = project / ".godot"
    policy_dir.mkdir(parents=True, exist_ok=True)
    (policy_dir / "gdapi-policy.json").write_text(
        json.dumps(M6_EVAL_POLICY), encoding="utf-8"
    )
    install = subprocess.run(
        [str(gdcli_bin()), "install", "--project", str(project), "--force"],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    assert install.returncode == 0, install.stderr
    log_path = project / ".godot" / "godot.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_handle = log_path.open("w", encoding="utf-8")
    env: dict[str, Any] = {"project": project, "godot_bin": godot_bin,
                            "gdcli": gdcli_bin(), "godot_log": log_handle,
                            "godot_log_path": log_path}
    godot, meta = attach_editor(project, godot_bin, log_handle)
    env.update({"godot": godot, "meta": meta})
    try:
        yield env
    finally:
        detach_editor(env)
        log_handle.close()


@pytest.fixture(scope="module")
def m6_editor_eval(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    godot_bin = resolve_godot_bin()
    require_godot_47(godot_bin)
    project = tmp_path_factory.mktemp("m6_editor") / "project"
    shutil.copytree(M6_FIXTURE_SOURCE, project)
    policy_dir = project / ".godot"
    policy_dir.mkdir(parents=True, exist_ok=True)
    (policy_dir / "gdapi-policy.json").write_text(
        json.dumps(M6_EVAL_POLICY), encoding="utf-8"
    )
    install = subprocess.run(
        [str(gdcli_bin()), "install", "--project", str(project), "--force"],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    assert install.returncode == 0, install.stderr
    log_path = project / ".godot" / "godot.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_handle = log_path.open("w", encoding="utf-8")
    env: dict[str, Any] = {"project": project, "godot_bin": godot_bin,
                            "gdcli": gdcli_bin(), "godot_log": log_handle,
                            "godot_log_path": log_path,
                            "game_run_count": 0, "game_stop_count": 0}
    godot, meta = attach_editor(project, godot_bin, log_handle)
    env.update({"godot": godot, "meta": meta})
    try:
        yield env
    finally:
        detach_editor(env)
        log_handle.close()


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
def m6_editor_bulk(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    godot_bin = resolve_godot_bin()
    require_godot_47(godot_bin)
    project = tmp_path_factory.mktemp("m6_editor_bulk") / "project"
    shutil.copytree(M6_FIXTURE_SOURCE, project)
    policy_dir = project / ".godot"
    policy_dir.mkdir(parents=True, exist_ok=True)
    (policy_dir / "gdapi-policy.json").write_text(
        json.dumps({
            "version": 1,
            "capabilities": {
                "bulk_files": {"enabled": True},
            },
        }),
        encoding="utf-8",
    )
    install = subprocess.run(
        [str(gdcli_bin()), "install", "--project", str(project), "--force"],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    assert install.returncode == 0, install.stderr
    log_path = project / ".godot" / "godot.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_handle = log_path.open("w", encoding="utf-8")
    env: dict[str, Any] = {"project": project, "godot_bin": godot_bin,
                            "gdcli": gdcli_bin(), "godot_log": log_handle,
                            "godot_log_path": log_path,
                            "game_run_count": 0, "game_stop_count": 0}
    godot, meta = attach_editor(project, godot_bin, log_handle)
    env.update({"godot": godot, "meta": meta})
    try:
        yield env
    finally:
        detach_editor(env)
        log_handle.close()


@pytest.fixture(scope="module")
def m6_editor_network(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    godot_bin = resolve_godot_bin()
    require_godot_47(godot_bin)
    project = tmp_path_factory.mktemp("m6_editor_network") / "project"
    shutil.copytree(M6_FIXTURE_SOURCE, project)
    policy_dir = project / ".godot"
    policy_dir.mkdir(parents=True, exist_ok=True)
    network_policy = {
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
    (policy_dir / "gdapi-policy.json").write_text(
        json.dumps(network_policy), encoding="utf-8"
    )
    install = subprocess.run(
        [str(gdcli_bin()), "install", "--project", str(project), "--force"],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    assert install.returncode == 0, install.stderr
    log_path = project / ".godot" / "godot.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_handle = log_path.open("w", encoding="utf-8")
    env: dict[str, Any] = {"project": project, "godot_bin": godot_bin,
                            "gdcli": gdcli_bin(), "godot_log": log_handle,
                            "godot_log_path": log_path,
                            "game_run_count": 0, "game_stop_count": 0}
    godot, meta = attach_editor(project, godot_bin, log_handle)
    env.update({"godot": godot, "meta": meta})
    try:
        yield env
    finally:
        detach_editor(env)
        log_handle.close()


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
	"apply_delete", "apply_replace",
	"audit_for_route", "bulk_digest",
	"command_doc", "delete_plan",
	"exec_error", "exec_ok",
	"inject_apply_failure", "latest_audit",
	"local_http_server", "m6_editor", "m6_editor_bulk", "m6_editor_eval",
	"m6_editor_network", "m6_editor_process", "m6_runtime_eval_running",
	"project_file", "replace_plan",
	"start_async_exec", "stop_game",
]
