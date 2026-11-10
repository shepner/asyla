#!/usr/bin/env python3
"""Ask nats-1 whether a credential is accepted, or whether it serves anonymous clients.

A credential rotation is not finished when the new password works — it is finished when the
*old* one is refused. Proving that requires presenting the old credential to the broker, which
is exactly the moment careless output handling leaks it. This script exists so nobody has to
improvise that check: the value arrives on stdin and never reaches argv, a log, or stdout.

`--anonymous` asks the other question, the one the deploy asks after the configuration step
writes users.conf and reloads NATS: does the broker take a client that presents no credential?
NATS re-reads users.conf on a reload as it is and never re-checks it, so the answer is measured
here, on 4222 and on the WebSocket listener (8080) that a proxy serves to the LAN as wss://. It
sends no credential and prints only verdicts.

Usage:
    printf '%s\\n%s\\n' "$USER" "$PASS" | python3 scripts/nats_auth_probe.py [host] [port]

    # Typical: prove the credential currently in OpenBao is accepted.
    docker exec -e BAO_TOKEN -e VAULT_SKIP_VERIFY=true openbao-1 \\
      bao kv get -address=https://127.0.0.1:8200 -format=json \\
      secret/v2/communications/nats-webhook-mq | ... | python3 scripts/nats_auth_probe.py

    python3 scripts/nats_auth_probe.py --anonymous [host] [port] [--ws-port 8080]

Exit status, credential mode: 0 accepted, 1 refused, 2 protocol/usage problem, 3 unreachable.
Exit status, --anonymous: 0 refused on every transport, 1 ACCEPTED on any (the broker is open),
2 protocol problem or a refusal that is not NATS's authorization error, 3 unreachable.
Never print the credential. Compare hashes or rely on this verdict instead.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import socket
import sys

TIMEOUT = 8
WS_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class ProbeError(Exception):
    """The far end did not behave like NATS; no verdict."""


class _WebSocket:
    """Just enough of RFC 6455 for one NATS handshake: masked binary frames out, lines in."""

    def __init__(self, sock: socket.socket, host: str, port: int) -> None:
        self.sock = sock
        key = base64.b64encode(os.urandom(16))
        sock.sendall(
            b"GET / HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            b"Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"
            % (host.encode(), port, key)
        )
        self.raw = b""
        while b"\r\n\r\n" not in self.raw:
            self._recv_more()
        head, self.raw = self.raw.split(b"\r\n\r\n", 1)
        lines = head.split(b"\r\n")
        if b" 101 " not in lines[0] + b" ":
            raise ProbeError(f"no WebSocket upgrade: {lines[0].decode(errors='replace')}")
        accept = base64.b64encode(hashlib.sha1(key + WS_GUID).digest())  # noqa: S324 (RFC 6455)
        headers = {
            k.strip().lower(): v.strip()
            for k, _, v in (ln.partition(b":") for ln in lines[1:])
        }
        if headers.get(b"sec-websocket-accept") != accept:
            raise ProbeError("WebSocket upgrade without the right Sec-WebSocket-Accept")
        self.data = b""
        self.closed = False

    def _recv_more(self) -> None:
        chunk = self.sock.recv(65536)
        if not chunk:
            raise ProbeError("connection closed mid-frame")
        self.raw += chunk

    def _take(self, n: int) -> bytes:
        while len(self.raw) < n:
            self._recv_more()
        out, self.raw = self.raw[:n], self.raw[n:]
        return out

    def _send(self, opcode: int, payload: bytes) -> None:
        mask = os.urandom(4)
        n = len(payload)
        if n < 126:
            head = bytes([0x80 | opcode, 0x80 | n])
        elif n < 65536:
            head = bytes([0x80 | opcode, 0x80 | 126]) + n.to_bytes(2, "big")
        else:
            head = bytes([0x80 | opcode, 0x80 | 127]) + n.to_bytes(8, "big")
        body = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(head + mask + body)

    def _read_frame(self) -> None:
        b0, b1 = self._take(2)
        opcode, n = b0 & 0x0F, b1 & 0x7F
        if n == 126:
            n = int.from_bytes(self._take(2), "big")
        elif n == 127:
            n = int.from_bytes(self._take(8), "big")
        mask = self._take(4) if b1 & 0x80 else b""
        payload = self._take(n)
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        if opcode == 0x8:
            self.closed = True
        elif opcode == 0x9:
            self._send(0xA, payload)
        elif opcode in (0x0, 0x1, 0x2):
            self.data += payload

    def readline(self) -> bytes:
        while b"\n" not in self.data and not self.closed:
            try:
                self._read_frame()
            except ProbeError:
                self.closed = True
        if b"\n" not in self.data:
            line, self.data = self.data, b""
            return line
        line, self.data = self.data.split(b"\n", 1)
        return line + b"\n"

    def write(self, data: bytes) -> None:
        self._send(0x2, data)

    def flush(self) -> None:
        return None


def _converse(stream, credentials: dict[str, str]) -> tuple[str, str]:
    """CONNECT + PING over an open stream: ("ok"|"refused"|"error", what the server said)."""
    if not (stream.readline() or b"").startswith(b"INFO"):
        return "error", "no INFO greeting — is this a NATS port?"
    connect = {
        "verbose": False,
        "pedantic": False,
        **credentials,
        "lang": "python",
        "version": "auth-probe",
        "protocol": 1,
    }
    stream.write(b"CONNECT " + json.dumps(connect).encode() + b"\r\nPING\r\n")
    stream.flush()
    for _ in range(10):
        line = stream.readline()
        if not line:
            break
        if line.startswith(b"PONG"):
            return "ok", "PONG"
        if line.startswith(b"-ERR"):
            # The server's error text carries no secret material, so it is safe to show.
            return "refused", line.decode(errors="replace").strip()
    return "error", "no verdict from the server"


def probe(host: str, port: int, transport: str, credentials: dict[str, str]) -> tuple[str, str]:
    """One connection over "tcp" or "ws": ("ok"|"refused"|"error"|"unreachable", detail)."""
    try:
        sock = socket.create_connection((host, port), timeout=TIMEOUT)
    except OSError as exc:
        return "unreachable", exc.__class__.__name__
    try:
        sock.settimeout(TIMEOUT)
        try:
            stream = _WebSocket(sock, host, port) if transport == "ws" else sock.makefile("rwb")
            return _converse(stream, credentials)
        except ProbeError as exc:
            return "error", str(exc)
        except OSError as exc:
            return "error", exc.__class__.__name__
    finally:
        sock.close()


def anonymous(host: str, tcp_port: int, ws_port: int) -> int:
    worst = 0
    for transport, scheme, port in (("tcp", "nats", tcp_port), ("ws", "ws", ws_port)):
        kind, detail = probe(host, port, transport, {})
        where = f"anonymous {scheme}://{host}:{port}"
        if kind == "ok":
            print(f"{where}: ACCEPTED — the broker serves clients without credentials")
            worst = 1
        elif kind == "refused" and "authorization violation" in detail.lower():
            print(f"{where}: refused ({detail})")
        elif kind == "unreachable":
            print(f"{where}: TCP_UNREACHABLE ({detail})")
            worst = worst or 3
        else:
            print(f"{where}: PROBE_ERROR ({detail}) — not NATS's authorization refusal")
            worst = worst or 2
    return worst


def credential(host: str, port: int) -> int:
    user = sys.stdin.readline().strip()
    password = sys.stdin.readline().strip()
    if not user or not password:
        # Guard against the classic mistake: a pipeline that silently delivered nothing, which
        # would otherwise look like a clean "refused" and be mistaken for proof.
        print("PROBE_ERROR: expected 'user\\npassword' on stdin")
        return 2
    kind, detail = probe(host, port, "tcp", {"user": user, "pass": password})
    password = ""
    if kind == "ok":
        print("AUTH_OK")
        return 0
    if kind == "refused":
        print(f"AUTH_REJECTED ({detail})")
        return 1
    if kind == "unreachable":
        print(f"TCP_UNREACHABLE: {detail}")
        return 3
    print(f"PROBE_ERROR: {detail}")
    return 2


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("host", nargs="?", default="127.0.0.1")
    ap.add_argument("port", nargs="?", type=int, default=4222, help="the NATS (TCP) port")
    ap.add_argument("--anonymous", action="store_true",
                    help="present no credential, on the TCP and the WebSocket port")
    ap.add_argument("--ws-port", type=int, default=8080, help="the WebSocket port (--anonymous)")
    args = ap.parse_args(argv)
    if args.anonymous:
        return anonymous(args.host, args.port, args.ws_port)
    return credential(args.host, args.port)


if __name__ == "__main__":
    raise SystemExit(main())
