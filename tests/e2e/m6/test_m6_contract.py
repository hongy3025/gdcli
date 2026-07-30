from __future__ import annotations

import pytest

from e2e.route_manifests import M6_ROUTES
from .conftest import command_doc, exec_error


@pytest.mark.parametrize("route", sorted(M6_ROUTES))
def test_m6_route_is_default_deny(m6_editor, route):
    body = {"force": True}
    if route == "runtime/eval":
        body["source"] = "1 + 1"
    error = exec_error(m6_editor, route, body)
    assert error["code"] == "permission_denied"


@pytest.mark.parametrize("route", sorted(M6_ROUTES))
def test_m6_route_docs_are_complete(m6_editor, route):
    doc = command_doc(m6_editor, route)
    assert doc["summary"]
    assert doc["returns"]["fields"]
    assert doc["examples"]
