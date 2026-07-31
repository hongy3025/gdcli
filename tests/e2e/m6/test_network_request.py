from __future__ import annotations

import json

import pytest

from .conftest import exec_error, exec_ok, latest_audit


def test_network_request_unreachable_host(m6_editor_network):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": "http://127.0.0.1:1/ok", "timeout_ms": 1000,
    })
    assert error["code"] in {"godot_error", "timeout"}


def test_network_request_redirect_is_followed(m6_editor_network, local_http_server):
    result = exec_ok(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/redirect-ok"),
    })
    assert result["status"] == 200
    assert result["redirects"] == 1


def test_redirect_loop_is_rejected(m6_editor_network, local_http_server):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/redirect-loop"),
    })
    assert error["code"] == "conflict"


def test_redirect_to_allowed_target_succeeds(m6_editor_network, local_http_server):
    result = exec_ok(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/redirect-ok"),
    })
    assert result["status"] == 200
    assert result["redirects"] == 1


def test_timeout_returns_timeout_code(m6_editor_network, local_http_server):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/delay"), "timeout_ms": 500,
    })
    assert error["code"] == "timeout"


def test_response_cap_truncates_or_errors(m6_editor_network, local_http_server):
    from .conftest import _exec_raw
    result = _exec_raw(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/large"), "max_response_bytes": 1024,
    })
    assert result.get("code") is None or result.get("code") == ""
    assert result["truncated"] is True
    assert result["size"] <= 1024


def test_audit_redacts_body_and_headers(m6_editor_network, local_http_server):
    exec_ok(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/ok"),
    })
    event = latest_audit(m6_editor_network, "network/http_request")
    body = json.dumps(event)
    assert "payload-ok" not in body
