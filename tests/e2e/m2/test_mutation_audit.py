"""统一 mutation 审计：handler 未自行审计时由 router 补记，且不重复。"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

from .helpers import exec_error, exec_ok


def _audit_seq(env):
    entries = exec_ok(env, "gdapi/audit/list", {"limit": 1000})["entries"]
    return max((entry["seq"] for entry in entries), default=0)


def _audit_entries(env, route: str, seq: int) -> list:
    payload = exec_ok(env, "gdapi/audit/list", {"since": seq, "limit": 1000})
    return [entry for entry in payload.get("entries", []) if entry.get("route") == route]


def test_unselfaudited_mutation_gets_one_mutation_entry(m2_editor, m2_main):
    """node/property/set 没有自行审计：router 必须补恰好一条 mutation 记录。"""
    exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Node2D", "name": "AuditProbe",
    })
    seq = _audit_seq(m2_editor)
    exec_ok(m2_editor, "node/property/set", {
        "node_path": "/root/Main/AuditProbe",
        "property": "position",
        "value": {"type": "Vector2", "value": [3, 4]},
    })
    entries = _audit_entries(m2_editor, "node/property/set", seq)
    assert len(entries) == 1, entries
    assert entries[0]["safety"] == "mutation", entries
    assert entries[0]["ok"] is True, entries


def test_selfaudited_mutation_is_not_duplicated(m2_editor):
    """已自行审计的 mutation（scene/open 记为 file 类）不得再被补记一条。"""
    seq = _audit_seq(m2_editor)
    exec_ok(m2_editor, "scene/open", {"path": "res://scenes/main.tscn"})
    entries = _audit_entries(m2_editor, "scene/open", seq)
    assert len(entries) == 1, entries
    assert entries[0]["safety"] == "file", entries


def _raw_post(env, route: str, body: str) -> tuple[int, dict]:
    meta = json.loads(
        (Path(env["project"]) / ".godot" / "gdapi.json").read_text(encoding="utf-8")
    )
    request = urllib.request.Request(
        f"http://127.0.0.1:{meta['http_port']}/{route}",
        data=body.encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + meta["token"],
        },
        method="POST",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=30) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read().decode("utf-8"))


@pytest.mark.parametrize("body,code", [
    ({}, "missing_param"),
    ({"node_path": "/root/Main/NoAuditNode", "property": "position", "value": 1}, "not_found"),
    ({"node_path": "/root/Main", "property": "__no_such_property__", "value": 1}, "not_found"),
    ({"node_path": "/root/Main", "property": "position", "value": {"type": "Vector2", "value": "bad"}}, "invalid_param"),
])
def test_failed_mutation_without_changed_is_audited(m2_editor, m2_main, body, code):
    seq = _audit_seq(m2_editor)
    error = exec_error(m2_editor, "node/property/set", body)
    assert error["code"] == code, error
    entries = _audit_entries(m2_editor, "node/property/set", seq)
    assert len(entries) == 1, entries
    assert entries[0]["ok"] is False, entries
    assert entries[0]["code"] == error["code"], entries
    assert entries[0]["safety"] == "mutation", entries
    assert entries[0]["summary"]["changed"] is False, entries


@pytest.mark.parametrize("route,safety", [
    ("node/property/set", "mutation"),
    ("filesystem/write", "file"),
    ("editor/eval", "dangerous"),
    ("scene/delete", "dangerous"),
    ("scene/batch/apply", "file"),
    ("resource/set", "file"),
    ("audio/bus/set", "file"),
    ("editor/settings/set", "file"),
    ("editor/plugins/enable", "file"),
    ("editor/screenshot/viewport", "file"),
])
def test_malformed_json_is_audited_before_handler(m2_editor, route, safety):
    seq = _audit_seq(m2_editor)
    status, error = _raw_post(m2_editor, route, "{")
    assert status == 400 and error["code"] == "invalid_param", error
    entries = _audit_entries(m2_editor, route, seq)
    assert len(entries) == 1, entries
    assert entries[0]["safety"] == safety, entries
    assert entries[0]["ok"] is False, entries
    assert entries[0]["code"] == error["code"], entries


def test_dangerous_failure_is_not_duplicated(m2_editor):
    seq = _audit_seq(m2_editor)
    error = exec_error(m2_editor, "editor/eval", {"source": "OS.execute()"})
    entries = _audit_entries(m2_editor, "editor/eval", seq)
    assert len(entries) == 1, entries
    assert entries[0]["ok"] is False and entries[0]["code"] == error["code"], entries
    assert entries[0]["safety"] == "dangerous", entries


def test_audit_retains_protected_entries_during_normal_traffic(m2_editor):
    seq = _audit_seq(m2_editor)
    exec_error(m2_editor, "editor/eval", {"source": "OS.execute()"})
    exec_error(m2_editor, "filesystem/write", {})
    protected = [
        entry for entry in exec_ok(m2_editor, "gdapi/audit/list", {"since": seq, "limit": 1000})["entries"]
        if entry["safety"] in {"dangerous", "file"}
    ]
    with ThreadPoolExecutor(max_workers=8) as pool:
        replies = list(pool.map(
            lambda _: _raw_post(m2_editor, "node/property/set", "{}"), range(4),
        ))
    assert all(status == 400 and body["code"] == "missing_param" for status, body in replies)
    entries = exec_ok(m2_editor, "gdapi/audit/list", {"since": seq, "limit": 1000})["entries"]
    assert len(entries) == len(protected) + 4
    sequences = [entry["seq"] for entry in entries]
    assert sequences == sorted(set(sequences))
    assert all(entry in entries for entry in protected)
    ordinary = [entry for entry in entries if entry["safety"] == "mutation"]
    assert len(ordinary) == 4
    assert all(entry["ok"] is False for entry in ordinary)
    for safety in ("mutation", "runtime", "file", "dangerous"):
        filtered = exec_ok(m2_editor, "gdapi/audit/list", {
            "since": seq, "limit": 1000, "safety": safety,
        })["entries"]
        assert filtered == [entry for entry in entries if entry["safety"] == safety]
    first = exec_ok(m2_editor, "gdapi/audit/list", {"since": seq, "limit": 3})["entries"]
    second = exec_ok(m2_editor, "gdapi/audit/list", {
        "since": first[-1]["seq"], "limit": 4,
    })["entries"]
    assert first + second == entries
    assert exec_ok(m2_editor, "gdapi/audit/list", {
        "since": entries[-1]["seq"],
    })["entries"] == []


def test_audit_safety_filter_rejects_unknown_values(m2_editor):
    error = exec_error(m2_editor, "gdapi/audit/list", {"safety": "unknown"})
    assert error["code"] == "invalid_param", error


def test_read_only_failure_is_not_a_mutation(m2_editor, m2_main):
    seq = _audit_seq(m2_editor)
    failure = exec_error(m2_editor, "node/property/get", {
        "node_path": "/root/Main/NoAuditNode", "property": "position",
    })
    assert failure["code"] == "not_found", failure
    assert _audit_entries(m2_editor, "node/property/get", seq) == []
