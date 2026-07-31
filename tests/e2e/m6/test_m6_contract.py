from __future__ import annotations

import pytest

from e2e.route_manifests import M6_ROUTES
from .conftest import _exec_raw, command_doc


@pytest.mark.parametrize("route", sorted(M6_ROUTES))
def test_m6_route_no_longer_requires_policy(m6_editor, route):
    """Policy requirement removed: routes must not answer permission_denied."""
    body = {"force": True}  # force 字段被忽略，不应再触发拒绝
    if route == "runtime/eval":
        body["source"] = "1 + 1"
    result = _exec_raw(m6_editor, route, body)
    assert result.get("code") != "permission_denied"


@pytest.mark.parametrize("route", sorted(M6_ROUTES))
def test_m6_route_docs_are_complete(m6_editor, route):
    doc = command_doc(m6_editor, route)
    assert doc["summary"]
    assert doc["returns"]["fields"]
    assert doc["examples"]
