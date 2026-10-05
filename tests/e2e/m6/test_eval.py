from __future__ import annotations

import json
from typing import Any

import pytest

from .conftest import audit_cursor, exec_error, exec_ok, latest_audit

ALLOWED_EDITOR: list[tuple[str, dict[str, Any], Any]] = [
    ("a + b", {"a": 1, "b": 2}, 3),
    ("a <= b and a != 0", {"a": 1, "b": 2}, True),
    (
        "Vector2(a, b) + Vector2(1, 1)",
        {"a": 1, "b": 2},
        {"type": "Vector2", "value": [2.0, 3.0]},
    ),
    ("a", {"a": {"type": "Vector2", "value": [2, 3]}},
     {"type": "Vector2", "value": [2.0, 3.0]}),
    ("a", {"a": [1, {"safe": True}, None]}, [1, {"safe": True}, None]),
]

DENIED_EDITOR: list[tuple[str, dict[str, Any]]] = [
    ("instance_from_id(1)", {}),
    ("Engine", {}),
    ("a = b", {"a": 1, "b": 2}),
    ("a.b", {"a": 1}),
]


@pytest.mark.parametrize("source,inputs,expected", ALLOWED_EDITOR)
def test_editor_eval_allow(
    m6_editor_eval: dict[str, Any], source: str, inputs: dict[str, Any], expected: Any
) -> None:
    body = {"source": source, "inputs": inputs}
    result = exec_ok(m6_editor_eval, "editor/eval", body)
    assert result["value"] == expected


@pytest.mark.parametrize("source,inputs", DENIED_EDITOR)
def test_editor_eval_deny(
    m6_editor_eval: dict[str, Any], source: str, inputs: dict[str, Any]
) -> None:
    body = {"source": source, "inputs": inputs}
    error = exec_error(m6_editor_eval, "editor/eval", body)
    assert error["code"] == "permission_denied"


def test_eval_source_never_appears_in_audit(m6_editor_eval: dict[str, Any]) -> None:
    before = audit_cursor(m6_editor_eval, "editor/eval")
    secret = "41 + 1"
    exec_ok(m6_editor_eval, "editor/eval", {"source": secret})
    event = latest_audit(m6_editor_eval, "editor/eval", since=before)
    assert secret not in json.dumps(event)
    assert event["ok"] is True


@pytest.mark.parametrize("type_name", [
    "Object", "Resource", "RID", "Callable", "Signal", "GDScript", "PackedScene",
])
@pytest.mark.parametrize("nested", [False, True])
def test_eval_rejects_object_encodings(m6_editor_eval, type_name, nested):
    encoded = {"type": type_name, "value": "user://not-loaded.gd"}
    value = {"nested": [encoded]} if nested else encoded
    error = exec_error(m6_editor_eval, "editor/eval", {
        "source": "1", "inputs": {"a": value},
    })
    assert error["code"] == "invalid_param"
