from __future__ import annotations

import json
from typing import Any

import pytest

from .conftest import exec_error, exec_ok, latest_audit

ALLOWED_EDITOR: list[tuple[str, dict[str, Any], Any]] = [
    ("a + b", {"a": 1, "b": 2}, 3),
    ("a <= b and a != 0", {"a": 1, "b": 2}, True),
    (
        "Vector2(a, b) + Vector2(1, 1)",
        {"a": 1, "b": 2},
        {"type": "Vector2", "value": [2.0, 3.0]},
    ),
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
    secret = "41 + 1"
    exec_ok(m6_editor_eval, "editor/eval", {"source": secret})
    event = latest_audit(m6_editor_eval, "editor/eval")
    assert secret not in json.dumps(event)
    assert event["ok"] is True
