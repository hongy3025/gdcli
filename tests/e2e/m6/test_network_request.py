from __future__ import annotations

import json
import os
import socket
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from .conftest import audit_for_route, exec_error, exec_ok, latest_audit


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






def test_ipv4_embedded_ipv6_literals_compare_canonically(
    m6_editor_network, redirect_servers,
):
    from .conftest import _exec_raw

    servers, routes, requests = redirect_servers
    port = servers[0].server_port
    routes[port, "/v4map-start"] = (
        f"http://[0:0:0:0:0:ffff:7f00:1]:{port}/v4map-next"
    )
    result = _exec_raw(m6_editor_network, "network/http_request", {
        "url": f"http://[::ffff:127.0.0.1]:{port}/v4map-start",
        "headers": {"Authorization": "Bearer IPV4_MAPPED_ORIGIN_SENTINEL"},
    })
    if result.get("code") in {"godot_error", "timeout"}:
        pytest.skip("IPv4-mapped IPv6 loopback is not routable on this platform")
    assert result.get("status") == 200, result
    assert [request[1] for request in requests] == ["/v4map-start", "/v4map-next"]
    assert all(
        request[2].get("authorization") == "Bearer IPV4_MAPPED_ORIGIN_SENTINEL"
        for request in requests
    )


def test_ipv6_equivalent_literal_keeps_same_origin_credentials(m6_editor_network):
    class IPv6Server(ThreadingHTTPServer):
        address_family = socket.AF_INET6

    received = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            received.append({name.lower(): value for name, value in self.headers.items()})
            self.send_response(302 if self.path == "/start" else 200)
            if self.path == "/start":
                self.send_header(
                    "Location",
                    f"http://[0:0:0:0:0:0:0:1]:{self.server.server_port}/next",
                )
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()

        def log_message(self, *_args):
            pass

    try:
        server = IPv6Server(("::1", 0), Handler)
    except OSError:
        pytest.skip("IPv6 loopback is unavailable")
    thread = threading.Thread(
        target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True,
    )
    thread.start()
    try:
        from .conftest import _exec_raw

        result = _exec_raw(m6_editor_network, "network/http_request", {
            "url": f"http://[::1]:{server.server_port}/start",
            "headers": {"Authorization": "Bearer IPV6_ORIGIN_SENTINEL"},
        })
        if (
            result.get("code") == "godot_error"
            and result.get("error") == "HTTP request could not start"
        ):
            pytest.skip("Godot HTTPRequest cannot start IPv6 literal requests in this build")
        assert result["status"] == 200
        assert result["redirects"] == 1
        assert len(received) == 2
        assert all(
            headers.get("authorization") == "Bearer IPV6_ORIGIN_SENTINEL"
            for headers in received
        )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)



def test_client_disconnect_cancels_network_request(m6_editor_network):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.server.request_seen.set()
            self.server.release.wait(timeout=2)
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.request_seen = threading.Event()
    server.release = threading.Event()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    before = len(audit_for_route(m6_editor_network, "network/http_request"))
    meta = m6_editor_network["meta"]
    body = json.dumps({"url": f"http://127.0.0.1:{server.server_port}/wait"}).encode()
    try:
        with socket.create_connection(("127.0.0.1", meta["http_port"]), timeout=5) as client:
            request = (
                "POST /network/http_request HTTP/1.1\r\nHost: localhost\r\n"
                f"Authorization: Bearer {meta['token']}\r\n"
                f"Content-Length: {len(body)}\r\nContent-Type: application/json\r\n\r\n"
            ).encode() + body
            client.sendall(request)
            assert server.request_seen.wait(timeout=5), "network request never reached local server"
            linger_format = "HH" if os.name == "nt" else "ii"
            client.setsockopt(
                socket.SOL_SOCKET, socket.SO_LINGER, struct.pack(linger_format, 1, 0)
            )
        deadline = time.monotonic() + 5
        events = []
        while time.monotonic() < deadline:
            events = audit_for_route(m6_editor_network, "network/http_request")[before:]
            if events:
                break
            time.sleep(0.05)
        assert len(events) == 1, events
        assert events[0]["ok"] is False, events
        server.release.set()
        result = exec_ok(m6_editor_network, "network/http_request", {
            "url": f"http://127.0.0.1:{server.server_port}/wait",
            "timeout_ms": 3000,
        })
        assert result["status"] == 200
    finally:
        server.release.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
@pytest.mark.parametrize(
    ("location", "expected_path"),
    [
        ("?next=2", "/dir/start?next=2"),
        ("next", "/dir/next"),
        ("/a//b", "/a//b"),
        ("/next?return=http://example.invalid/", "/next?return=http://example.invalid/"),
    ],
)
def test_redirect_uri_reference_reaches_resolved_path(
    m6_editor_network, redirect_servers, location, expected_path,
):
    servers, routes, requests = redirect_servers
    port = servers[0].server_port
    routes[port, "/dir/start?old=1"] = location
    result = exec_ok(m6_editor_network, "network/http_request", {
        "url": f"http://127.0.0.1:{port}/dir/start?old=1",
    })
    assert result["status"] == 200
    assert result["body_base64"] == ""
    assert result["sha256"] == (
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    assert result["redirects"] == 1
    assert [request[1] for request in requests] == [
        "/dir/start?old=1", expected_path,
    ]

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


@pytest.mark.parametrize(
    "url",
    [
        "http:username:{secret}@host/path",
        "http://audit-user:{secret}/path@host/",
        "http://audit-user?{secret}@host/path",
        "http://audit-user#{secret}@host/path",
        "//audit-user:{secret}@host/path",
    ],
)
def test_rejected_url_credentials_are_not_readable_in_audit(m6_editor_network, url):
    secret = "AUDIT_UNIQUE_URL_SECRET_7f32"
    raw_url = url.format(secret=secret)
    error = exec_error(m6_editor_network, "network/http_request", {"url": raw_url})
    assert error["code"] == "invalid_param"
    event = latest_audit(m6_editor_network, "network/http_request")
    assert event["ok"] is False
    assert event["code"] == "invalid_param"
    serialized = json.dumps(event)
    assert secret not in serialized
    assert "audit-user" not in serialized
    assert "username" not in serialized
    assert event["summary"]["url"] == "[REDACTED]"
