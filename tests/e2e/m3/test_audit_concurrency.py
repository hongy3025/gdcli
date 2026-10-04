"""Runtime callbacks and synchronous failures must not share audit ownership."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

from .conftest import exec_error, exec_ok, wait_for


def test_concurrent_runtime_mutations_keep_one_final_audit_each(m3_running):
    env = m3_running
    exec_ok(env, "gdapi/audit/clear")
    path = "/root/RuntimeMain/ProbeTarget"
    before = exec_ok(env, "runtime/node/get", {"node_path": path, "property": "counter"})["value"]
    with ThreadPoolExecutor(max_workers=4) as pool:
        first = pool.submit(exec_ok, env, "runtime/node/call", {
            "node_path": path, "method": "increment_later", "args": [2, 150],
        })
        second = pool.submit(exec_ok, env, "runtime/node/call", {
            "node_path": path, "method": "increment_later", "args": [3, 300],
        })
        failed = pool.submit(exec_error, env, "runtime/node/set", {
            "node_path": "/root/RuntimeMain/NoAuditNode", "property": "position", "value": 1,
        })
        ordinary = pool.submit(exec_error, env, "node/property/set", {})
        first_reply = first.result(timeout=35)
        second_reply = second.result(timeout=35)
        failed_reply = failed.result(timeout=35)
        ordinary_reply = ordinary.result(timeout=35)
    assert first_reply["ok"] is True and second_reply["ok"] is True
    assert failed_reply["code"] == "not_found", failed_reply
    assert ordinary_reply["code"] == "missing_param", ordinary_reply
    wait_for(lambda: exec_ok(env, "runtime/node/get", {
        "node_path": path, "property": "counter",
    })["value"] == before + 5)
    after = exec_ok(env, "runtime/node/get", {"node_path": path, "property": "counter"})["value"]
    assert after == before + 5
    entries = exec_ok(env, "gdapi/audit/list", {"limit": 1000})["entries"]
    calls = [entry for entry in entries if entry["route"] == "runtime/node/call"]
    assert len(calls) == 2, calls
    assert all(entry["ok"] is True and entry["safety"] == "runtime" for entry in calls), calls
    for route, safety, code in [
        ("runtime/node/set", "runtime", failed_reply["code"]),
        ("node/property/set", "mutation", ordinary_reply["code"]),
    ]:
        matching = [entry for entry in entries if entry["route"] == route]
        assert len(matching) == 1, matching
        assert matching[0]["ok"] is False and matching[0]["code"] == code, matching
        assert matching[0]["safety"] == safety, matching
    sequences = [entry["seq"] for entry in entries]
    assert sequences == sorted(set(sequences))
