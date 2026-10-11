#!/usr/bin/env python3
"""A local stand-in for ms-chronicle's backup download route, for the tests of
d03/apps/ms-chronicle-backup (python3 standard library only; listens on 127.0.0.1).

It answers as theOrg memory-system ms-chronicle-mcp/README.md, "Off-host copy: the pull contract"
(origin/main 705a1d8) says the route on the Mini answers: the two GETs, the bearer check, the
X-Chronicle-* headers copied from the manifest, and the error bodies. It is not that route's code.

  STUB_TOKEN=<bearer> chronicle_backup_stub.py <port> <scenario.json> <request-log>

The scenario file is read again on every request, so one process serves every test case:

  {"stamp": "20261011T030000Z",   the snapshot is chronicle-<stamp>, created at that UTC time
   "episodes": 5,
   "observations": 2,             null: a schema 1 snapshot (archive only, no observations header)
   "fault": ""}                   or one of FAULTS below

The request log gets one line per request: method, path with query, and bearer=ok|wrong|none.
"""
import datetime as dt
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

FAULTS = (
    "",
    "corrupt_body",        # the tarball's bytes differ from what the headers and manifest say
    "truncated",           # the connection closes before Content-Length bytes were sent
    "bad_name",            # X-Chronicle-Snapshot is not a snapshot name (a path)
    "wrong_manifest",      # the manifest served is another snapshot's
    "manifest_error",      # the manifest request answers 500
    "created_header",      # X-Chronicle-Created differs from the manifest's created
    "volume_unavailable",  # 503: the backup volume is not mounted on the Mini
    "no_snapshot",         # 404: nothing published yet
    "misconfigured",       # 503: the Mini has no backup token, the route is off
)
PORT, SCENARIO, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
TOKEN = os.environ["STUB_TOKEN"]


def snapshot(stamp, episodes, observations):
    """(tarball bytes, manifest dict) built the way the contract describes a published snapshot:
    regular files only, archive/ and observations/ apart, every file's sha256 in the manifest."""
    name = "chronicle-" + stamp
    when = dt.datetime.strptime(stamp, "%Y%m%dT%H%M%SZ").replace(tzinfo=dt.timezone.utc)
    trees = {"archive": {}, "observations": {}}
    for i in range(episodes):
        trees["archive"]["episodes/ep-%04d.json" % i] = json.dumps({"episode": i, "text": "episode %d" % i}).encode()
    trees["archive"]["index/episodes.idx"] = b"index of %d\n" % episodes
    for i in range(observations or 0):
        trees["observations"]["agent/obs-%04d.md" % i] = b"observation %d\n" % i
    raw = io.BytesIO()
    with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as zipped, tarfile.open(fileobj=zipped, mode="w") as tar:
        for tree in ("archive", "observations"):
            for path, data in sorted(trees[tree].items()):
                info = tarfile.TarInfo(tree + "/" + path)
                info.size, info.mtime = len(data), int(when.timestamp())
                tar.addfile(info, io.BytesIO(data))
    body = raw.getvalue()

    def table(tree):
        return {p: {"sha256": hashlib.sha256(d).hexdigest(), "size": len(d)} for p, d in trees[tree].items()}

    manifest = {"schema": 1 if observations is None else 2, "name": name, "created": when.isoformat(),
                "episodes": episodes, "bytes": sum(len(d) for d in trees["archive"].values()),
                "tarball_sha256": hashlib.sha256(body).hexdigest(), "tarball_bytes": len(body),
                "files": table("archive")}
    if observations is not None:
        manifest["observations"] = observations
        manifest["observation_files"] = table("observations")
    return body, manifest


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, body, content_type, headers=None, send=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body if send is None else send)

    def error(self, status, code, message):
        self.answer(status, json.dumps({"detail": {"code": code, "message": message}}).encode(), "application/json")

    def handle_any(self):
        given = self.headers.get("Authorization")
        bearer = "none" if given is None else "ok" if given == "Bearer " + TOKEN else "wrong"
        with open(LOG, "a") as log:
            log.write("%s %s bearer=%s\n" % (self.command, self.path, bearer))
        url = urlsplit(self.path)
        if url.path not in ("/api/v1/backup", "/api/v1/backup/manifest"):
            return self.error(404, "not_found", "no such path")
        if self.command != "GET":
            return self.error(405, "method_not_allowed", "GET only")
        with open(SCENARIO) as handle:
            scenario = json.load(handle)
        fault = scenario.get("fault", "")
        assert fault in FAULTS, fault
        if fault == "misconfigured":
            return self.error(503, "misconfigured", "the Mini has no backup token")
        if bearer != "ok":
            return self.error(401, "unauthorized", "no bearer, or not the backup token")
        if fault == "volume_unavailable":
            return self.error(503, "volume_unavailable", "the backup volume is not mounted")
        if fault == "no_snapshot":
            return self.error(404, "no_snapshot", "nothing is published yet")
        body, manifest = snapshot(scenario["stamp"], scenario["episodes"], scenario.get("observations"))
        headers = {"X-Chronicle-Snapshot": manifest["name"], "X-Chronicle-Created": manifest["created"],
                   "X-Chronicle-Sha256": manifest["tarball_sha256"], "X-Chronicle-Bytes": str(len(body)),
                   "X-Chronicle-Episodes": str(manifest["episodes"]), "X-Chronicle-Schema": str(manifest["schema"])}
        if "observations" in manifest:
            headers["X-Chronicle-Observations"] = str(manifest["observations"])
        if fault == "bad_name":
            headers["X-Chronicle-Snapshot"] = "../../outside"
        if fault == "created_header":
            headers["X-Chronicle-Created"] = "2020-01-01T00:00:00+00:00"
        if url.path == "/api/v1/backup":
            send = None
            if fault == "corrupt_body":
                send = body[:-1] + bytes([body[-1] ^ 0xFF])
            if fault == "truncated":
                send = body[: len(body) // 2]
            return self.answer(200, body, "application/gzip", headers, send)
        asked = parse_qs(url.query).get("snapshot", [manifest["name"]])[0]
        if fault == "manifest_error":
            return self.error(500, "snapshot_inconsistent", "the tarball is not the size its manifest recorded")
        if asked != manifest["name"]:
            return self.error(404, "no_such_snapshot", "?snapshot= names nothing published")
        if fault == "wrong_manifest":
            _, manifest = snapshot("20200101T000000Z", scenario["episodes"], scenario.get("observations"))
        return self.answer(200, json.dumps(manifest, indent=2).encode(), "application/json", headers)

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = handle_any


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
