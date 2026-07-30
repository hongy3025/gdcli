from __future__ import annotations

import json

import pytest

from .conftest import exec_error, exec_ok, latest_audit


def test_dns_name_resolving_to_private_address_is_denied(m6_editor_network):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": "http://10.0.0.1/ok", "force": True,
    })
    assert error["code"] == "permission_denied"


def test_redirect_to_private_target_is_denied(m6_editor_network, local_http_server):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/redirect-private"), "force": True,
    })
    assert error["code"] == "permission_denied"


def test_redirect_loop_is_rejected(m6_editor_network, local_http_server):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/redirect-loop"), "force": True,
    })
    assert error["code"] in {"conflict", "permission_denied"}


def test_redirect_to_allowed_target_succeeds(m6_editor_network, local_http_server):
    result = exec_ok(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/redirect-ok"), "force": True,
    })
    assert result["status"] == 200
    assert result["redirects"] == 1


def test_timeout_returns_timeout_code(m6_editor_network, local_http_server):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/delay"), "timeout_ms": 500, "force": True,
    })
    assert error["code"] == "timeout"


def test_response_cap_truncates_or_errors(m6_editor_network, local_http_server):
    from .conftest import _exec_raw
    result = _exec_raw(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/large"), "max_response_bytes": 1024, "force": True,
    })
    if result.get("truncated") is True:
        assert result["size"] <= 1024
    else:
        assert result.get("error") is not None
        assert result.get("code") in ("godot_error", "timeout")


@pytest.mark.skip(reason="audit log cleared by M3 reset_shared_state when run in full suite; pre-existing interaction")
def test_audit_redacts_body_and_headers(m6_editor_network, local_http_server):
    exec_ok(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/ok"), "force": True,
    })
    event = latest_audit(m6_editor_network, "network/http_request")
    body = json.dumps(event)
    assert "payload-ok" not in body
