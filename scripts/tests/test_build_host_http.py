#!/usr/bin/env python3
"""Offline test of build_host.http(): retry on a connection error, never on an HTTP status.

    python3 scripts/tests/test_build_host_http.py

Talks only to a throwaway server on 127.0.0.1 and to a closed local port. Exit 0 when every case
passes.
"""
from __future__ import annotations

import http.server
import socket
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_host  # noqa: E402

build_host.HTTP_RETRY_WAITS = (0.1, 0.1)   # keep the test quick; the count is what is tested


class Flaky(http.server.BaseHTTPRequestHandler):
    """Drops the first `drop` connections without answering, then answers `status`."""
    drop, status, seen = 0, 200, 0

    def handle_one_request(self):
        cls = type(self)
        cls.seen += 1
        if cls.seen <= cls.drop:
            self.connection.close()       # a reset: the client sees a connection error
            self.close_connection = True
            return
        super().handle_one_request()

    def _answer(self):
        if self.headers.get("Content-Length"):
            self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(type(self).status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok": true}')

    do_GET = do_PUT = do_POST = do_DELETE = _answer

    def log_message(self, *a):
        pass


def serve() -> tuple[http.server.HTTPServer, str]:
    srv = http.server.HTTPServer(("127.0.0.1", 0), Flaky)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}/x"


def closed_port_url() -> str:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return f"http://127.0.0.1:{port}/x"


def case(name: str, method: str, drop: int, status: int, want: str, want_seen: int | None, url: str | None = None) -> bool:
    Flaky.drop, Flaky.status, Flaky.seen = drop, status, 0
    try:
        code, _ = build_host.http(method, url or URL, {}, {"a": 1} if method in ("PUT", "POST") else None)
        got = str(code)
    except build_host.Fail as e:
        got = "Fail"
        detail = str(e)
    else:
        detail = ""
    ok = got == want and (want_seen is None or Flaky.seen == want_seen)
    print(f"{'ok  ' if ok else 'FAIL'}  {name}: got {got}, {Flaky.seen} request(s) reached the server"
          + (f" [{detail}]" if detail and not ok else ""))
    return ok


SRV, URL = serve()
results = [
    case("GET, healthy", "GET", 0, 200, "200", 1),
    case("GET, two connection errors then 200", "GET", 2, 200, "200", 3),
    case("PUT, one connection error then 200", "PUT", 1, 200, "200", 2),
    case("DELETE, one connection error then 404 (already gone)", "DELETE", 1, 404, "404", 2),
    case("GET, three connection errors: a Fail, not a traceback", "GET", 3, 200, "Fail", 3),
    case("POST, one connection error: not retried", "POST", 1, 200, "Fail", 1),
    case("GET, HTTP 500: returned, not retried", "GET", 0, 500, "500", 1),
    case("GET, nothing listening: Fail", "GET", 0, 200, "Fail", 0, closed_port_url()),
]
SRV.shutdown()
print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
