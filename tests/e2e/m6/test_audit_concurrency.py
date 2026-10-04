"""Concurrent deferred responses retain their own terminal audit outcome."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

from .conftest import _exec_raw, exec_error, exec_ok


def test_concurrent_process_network_and_mutation_audit_once(
    m6_editor_process, local_http_server,
):
    env = m6_editor_process
    exec_ok(env, "gdapi/audit/clear")
    with ThreadPoolExecutor(max_workers=4) as pool:
        timeout = pool.submit(_exec_raw, env, "process/run", {
            "executable": "sleep.cmd", "args": ["10"], "cwd": "res://tools",
            "timeout_ms": 800,
        })
        success = pool.submit(_exec_raw, env, "process/run", {
            "executable": "echo_args.cmd", "args": ["audit-concurrency"], "cwd": "res://tools",
        })
        network = pool.submit(_exec_raw, env, "network/http_request", {
            "url": local_http_server.url("/ok"), "timeout_ms": 3000,
        })
        failed = pool.submit(exec_error, env, "node/property/set", {})
        timeout_reply = timeout.result(timeout=35)
        success_reply = success.result(timeout=35)
        network_reply = network.result(timeout=35)
        failed_reply = failed.result(timeout=35)
    assert timeout_reply["code"] == "timeout", timeout_reply
    assert success_reply["ok"] is True and success_reply["exit_code"] == 0, success_reply
    assert "audit-concurrency" in success_reply["stdout"], success_reply
    assert network_reply["ok"] is True and network_reply["status"] == 200, network_reply
    assert failed_reply["code"] == "missing_param", failed_reply
    entries = exec_ok(env, "gdapi/audit/list", {"limit": 1000})["entries"]
    process = [entry for entry in entries if entry["route"] == "process/run"]
    assert len(process) == 2, process
    assert {(entry["ok"], entry["code"]) for entry in process} == {(True, ""), (False, "timeout")}
    assert all(entry["safety"] == "dangerous" for entry in process)
    by_executable = {entry["summary"]["executable"]: entry for entry in process}
    assert by_executable["sleep.cmd"]["ok"] is False
    assert by_executable["echo_args.cmd"]["ok"] is True
    for route, safety, ok, code in [
        ("network/http_request", "dangerous", True, ""),
        ("node/property/set", "mutation", False, "missing_param"),
    ]:
        matching = [entry for entry in entries if entry["route"] == route]
        assert len(matching) == 1, matching
        assert (matching[0]["safety"], matching[0]["ok"], matching[0]["code"]) == (safety, ok, code)
    # A later read must not trigger the obsolete deferred finish duplicate.
    assert exec_ok(env, "gdapi/audit/list", {"limit": 1000})["entries"] == entries
