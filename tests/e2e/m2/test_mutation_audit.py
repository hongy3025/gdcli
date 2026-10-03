"""统一 mutation 审计：handler 未自行审计时由 router 补记，且不重复。"""

from __future__ import annotations

from .helpers import exec_ok


def _audit_entries(env, route: str) -> list:
    payload = exec_ok(env, "gdapi/audit/list", {"limit": 1000})
    return [entry for entry in payload.get("entries", []) if entry.get("route") == route]


def test_unselfaudited_mutation_gets_one_mutation_entry(m2_editor):
    """node/property/set 没有自行审计：router 必须补恰好一条 mutation 记录。"""
    exec_ok(m2_editor, "node/create", {
        "parent_path": "/root/Main", "type": "Node2D", "name": "AuditProbe",
    })
    exec_ok(m2_editor, "node/property/set", {
        "node_path": "/root/Main/AuditProbe",
        "property": "position",
        "value": {"type": "Vector2", "value": [3, 4]},
    })
    entries = _audit_entries(m2_editor, "node/property/set")
    assert len(entries) == 1, entries
    assert entries[0]["safety"] == "mutation", entries
    assert entries[0]["ok"] is True, entries


def test_selfaudited_mutation_is_not_duplicated(m2_editor):
    """已自行审计的 mutation（scene/open 记为 file 类）不得再被补记一条。"""
    exec_ok(m2_editor, "scene/open", {"path": "res://scenes/main.tscn"})
    entries = _audit_entries(m2_editor, "scene/open")
    assert len(entries) == 1, entries
    assert entries[0]["safety"] == "file", entries
