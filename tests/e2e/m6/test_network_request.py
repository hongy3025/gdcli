from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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


@pytest.fixture
def redirect_servers():
    requests = []
    routes = {}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append((self.server.server_port, self.path, {
                name.lower(): value for name, value in self.headers.items()
            }))
            location = routes.get((self.server.server_port, self.path))
            self.send_response(302 if location else 200)
            if location:
                self.send_header("Location", location)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()

        def log_message(self, *_args):
            pass

    servers = [ThreadingHTTPServer(("127.0.0.1", 0), Handler) for _ in range(2)]
    threads = [
        threading.Thread(
            target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True,
        )
        for server in servers
    ]
    for thread in threads:
        thread.start()
    try:
        yield servers, routes, requests
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join(timeout=2)


@pytest.mark.parametrize("chain", [
    "same-origin", "same-origin-query", "cross-port", "return-to-origin",
])
def test_redirect_credentials_follow_origin_boundary(
    m6_editor_network, redirect_servers, chain,
):
    servers, routes, requests = redirect_servers
    first, second = [server.server_port for server in servers]
    same_origin = chain.startswith("same-origin")
    second_hop = first if same_origin else second
    start_path = "/?request=1" if chain == "same-origin-query" else "/start"
    routes[first, start_path] = (
        "/next" if same_origin else f"http://127.0.0.1:{second_hop}/next"
    )
    if chain == "return-to-origin":
        routes[second, "/next"] = f"http://127.0.0.1:{first}/final"
    credentials = {
        "aUtHoRiZaTiOn": "Bearer REDIRECT_AUTH_SENTINEL",
        "cOoKiE": "session=REDIRECT_COOKIE_SENTINEL",
        "Proxy-Authorization": "Basic REDIRECT_PROXY_SENTINEL",
        "X-Api-Key": "REDIRECT_API_SENTINEL",
    }
    start_url = f"http://127.0.0.1:{first}"
    start_url += "?request=1" if chain == "same-origin-query" else "/start"
    result = exec_ok(m6_editor_network, "network/http_request", {
        "url": start_url,
        "headers": {**credentials, "X-Public": "retained"},
    })
    assert result["status"] == 200
    assert result["redirects"] == (2 if chain == "return-to-origin" else 1)
    assert len(requests) == result["redirects"] + 1
    assert [port for port, _, _ in requests] == (
        [first, second, first] if chain == "return-to-origin" else [first, second_hop]
    )
    for index, (_, _, received) in enumerate(requests):
        assert received["x-public"] == "retained"
        for name, value in credentials.items():
            if index == 0 or same_origin:
                assert received[name.lower()] == value
            else:
                assert name.lower() not in received


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


def test_failed_request_is_audited_as_failure(m6_editor_network, local_http_server):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/delay"), "timeout_ms": 500,
    })
    assert error["code"] == "timeout", error
    event = latest_audit(m6_editor_network, "network/http_request")
    assert event["ok"] is False, event
    assert event["code"] == "timeout", event


@pytest.mark.parametrize("secret", ["AUDIT_PASSWORD_SENTINEL", "AUDIT PASSWORD SENTINEL"])
def test_rejected_url_credentials_are_not_readable_in_audit(m6_editor_network, secret):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": f"http://audit-user:{secret}@example.invalid/",
    })
    assert error["code"] == "invalid_param"
    event = latest_audit(m6_editor_network, "network/http_request")
    assert event["ok"] is False
    assert event["code"] == "invalid_param"
    assert secret not in json.dumps(event)
    assert "audit-user" not in json.dumps(event)
    assert event["summary"]["url"] == "http://[REDACTED]@example.invalid/"
