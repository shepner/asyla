#!/usr/bin/env python3
"""d01 media: radarr_reconcile.py against a stand-in Radarr API and a temporary library.

    python3 scripts/tests/test_radarr_reconcile.py

Matching by .nfo id and by name, ambiguous and claimed folders skipped, an .nfo naming another
movie refused, a dry run changes nothing, --apply repoints (moveFiles=false) and rescans, an HTTP
error is counted without its body, and the credential never reaches the output. Nothing reaches a
host or a real Radarr.
"""
from __future__ import annotations

import contextlib
import io
import json
import secrets
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "d01" / "apps" / "media"))
import radarr_reconcile as rr  # noqa: E402


class FakeRadarr:
    """Just the endpoints the script uses. Records every call; checks the credential header."""

    def __init__(self, movies, credential):
        self.movies = {m["id"]: m for m in movies}
        self.credential = credential
        self.calls = []
        self.fail_put = False
        self.library = None  # set by the test: path -> has video (RescanMovie finds the file)
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, obj=None):
                body = b"" if obj is None else json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _body(self):
                n = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(n)) if n else None

            def _handle(self, method):
                body = self._body()
                fake.calls.append((method, self.path, body))
                if self.headers.get("X-Api-Key") != fake.credential:
                    return self._send(401, {"echo": "bad key"})
                path = self.path.split("?")[0]
                if method == "GET" and path == "/api/v3/movie":
                    return self._send(200, list(fake.movies.values()))
                if path.startswith("/api/v3/movie/"):
                    mid = int(path.rsplit("/", 1)[1])
                    if method == "GET":
                        return self._send(200, fake.movies[mid])
                    if method == "PUT":
                        if fake.fail_put:
                            return self._send(500, {"echo": body})
                        fake.movies[mid] = body
                        return self._send(202, body)
                if method == "POST" and path == "/api/v3/command":
                    m = fake.movies[body["movieId"]]
                    if fake.library and fake.library(m["path"]):
                        m["hasFile"] = True
                    return self._send(201, {"id": 7, "status": "queued"})
                if method == "GET" and path == "/api/v3/command/7":
                    return self._send(200, {"id": 7, "status": "completed"})
                return self._send(404)

            def do_GET(self):
                self._handle("GET")

            def do_PUT(self):
                self._handle("PUT")

            def do_POST(self):
                self._handle("POST")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def writes(self):
        return [c for c in self.calls if c[0] in ("PUT", "POST")]


def movie(mid, title, year, tmdb, path, imdb="", has_file=False, monitored=True):
    return {"id": mid, "title": title, "year": year, "tmdbId": tmdb, "imdbId": imdb,
            "path": path, "hasFile": has_file, "monitored": monitored}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.lib = self.root / "Movies"
        self.credential = secrets.token_hex(16)
        cfg = self.root / "config.xml"
        cfg.write_text("<Config><Port>7878</Port><" + "ApiKey>" + self.credential
                       + "</" + "ApiKey></Config>")
        self.cfg = str(cfg)

    def tearDown(self):
        self.tmp.cleanup()

    def folder(self, rel, nfo=None, video=True):
        d = self.lib / rel
        d.mkdir(parents=True, exist_ok=True)
        if video:
            (d / (d.name + ".mp4")).write_bytes(b"")
        if nfo is not None:
            (d / (d.name + ".nfo")).write_text(nfo)
        return str(d)

    def run_once(self, movies, apply=False, fail_put=False):
        fake = FakeRadarr(movies, self.credential)
        fake.fail_put = fail_put
        fake.library = lambda p: any(Path(p).glob("*.mp4"))
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out):
                radarr = rr.Radarr(fake.url, rr.read_credential(self.cfg))
                ok = rr.run(radarr, [str(self.lib)], apply)
        finally:
            fake.close()
        self.assertNotIn(self.credential, out.getvalue())
        return ok, out.getvalue(), fake


class Matching(Base):
    def test_nfo_id_beats_a_different_folder_name(self):
        real = self.folder("HD/H/Hit Man (2024)",
                           '<movie><uniqueid type="tmdb">974635</uniqueid></movie>')
        ok, out, fake = self.run_once(
            [movie(1, "Hit Man", 2024, 974635, "/x/AnyStream/Totally Other (2024)")])
        self.assertTrue(ok)
        self.assertIn(f"would repoint Hit Man (2024) [radarr 1] by nfo id: "
                      f"/x/AnyStream/Totally Other (2024) -> {real}", out)

    def test_name_match_with_punctuation_and_year(self):
        real = self.folder("HD/A/Avatar - Fire and Ash (2025)", "<movie><title>x</title></movie>")
        ok, out, _ = self.run_once(
            [movie(1, "Avatar: Fire and Ash", 2025, 83533, "/x/AnyStream/Avatar - Fire and Ash (2025)")])
        self.assertIn(f"by name: /x/AnyStream/Avatar - Fire and Ash (2025) -> {real}", out)

    def test_nfo_naming_another_movie_refuses_a_name_match(self):
        self.folder("HD/H/Hit Man (2024)", "<movie><tmdbid>1388637</tmdbid></movie>")
        ok, out, _ = self.run_once([movie(1, "Hit Man", 2024, 974635, "/x/AnyStream/Hit Man (2024)")])
        self.assertTrue(ok)
        self.assertNotIn("would repoint", out)
        self.assertIn("0 matched", out)

    def test_title_prefix_and_other_year_do_not_match(self):
        self.folder("SD/I/I Am Legend (2007)")
        self.folder("HD/S/Sisu (2022)")
        ok, out, _ = self.run_once([
            movie(1, "I Am Legend 2", 0, 1, "/x/AnyStream/I Am Legend 2 ()"),
            movie(2, "Sisu: Road to Revenge", 2025, 2, "/x/radarr/Sisu - Road to Revenge (2025)"),
            movie(3, "Sisu", 2023, 3, "/x/radarr/Sisu (2023)"),
        ])
        self.assertIn("0 matched", out)

    def test_two_candidates_are_ambiguous(self):
        self.folder("HD/E/E.T. the Extra-Terrestrial (1982)")
        self.folder("SD/E/E.T. the Extra-Terrestrial (1982)")
        ok, out, fake = self.run_once(
            [movie(1, "E.T. the Extra-Terrestrial", 1982, 601, "/x/AnyStream/E.T. the Extra-Terrestrial (1982)")],
            apply=True)
        self.assertTrue(ok)
        self.assertIn("skip E.T. the Extra-Terrestrial (1982) [radarr 1]: ambiguous", out)
        self.assertEqual(fake.writes(), [])

    def test_folder_of_another_movie_is_not_taken(self):
        real = self.folder("HD/F/Fast X (2023)")
        ok, out, fake = self.run_once([
            movie(1, "Fast X", 2023, 385687, real, has_file=True),
            movie(2, "Fast X", 2023, 999, "/x/AnyStream/Fast X (2023)"),
        ], apply=True)
        self.assertIn("is already 'Fast X''s path", out)
        self.assertEqual(fake.writes(), [])

    def test_unmonitored_and_has_file_are_left_alone(self):
        self.folder("HD/G/Good Boy (2025)")
        ok, out, fake = self.run_once([
            movie(1, "Good Boy", 2025, 5, "/x/AnyStream/Good Boy (2025)", monitored=False)], apply=True)
        self.assertIn("0 wanted", out)
        self.assertEqual(fake.writes(), [])

    def test_folder_without_a_video_is_not_a_candidate(self):
        self.folder("HD/G/Good Boy (2025)", "<movie><tmdbid>5</tmdbid></movie>", video=False)
        ok, out, _ = self.run_once([movie(1, "Good Boy", 2025, 5, "/x/AnyStream/Good Boy (2025)")])
        self.assertIn("0 matched", out)


class Applying(Base):
    def test_dry_run_writes_nothing(self):
        self.folder("HD/G/Good Boy (2025)")
        ok, out, fake = self.run_once([movie(1, "Good Boy", 2025, 5, "/x/AnyStream/Good Boy (2025)")])
        self.assertTrue(ok)
        self.assertIn("dry run:", out)
        self.assertEqual(fake.writes(), [])

    def test_apply_repoints_without_moving_files_and_rescans(self):
        real = self.folder("HD/G/Good Boy (2025)")
        ok, out, fake = self.run_once(
            [movie(1, "Good Boy", 2025, 5, "/x/AnyStream/Good Boy (2025)")], apply=True)
        self.assertTrue(ok)
        puts = [c for c in fake.calls if c[0] == "PUT"]
        self.assertEqual(len(puts), 1)
        self.assertEqual(puts[0][1], "/api/v3/movie/1?moveFiles=false")
        self.assertEqual(puts[0][2]["path"], real)
        self.assertEqual(puts[0][2]["tmdbId"], 5)  # the whole movie goes back, not just the path
        posts = [c for c in fake.calls if c[0] == "POST"]
        self.assertEqual(posts[0][2], {"name": "RescanMovie", "movieId": 1})
        self.assertIn("repointed Good Boy (2025) [radarr 1] by name", out)
        self.assertIn("rescan completed; has file", out)
        self.assertIn("1 repointed, 1 now have a file", out)

    def test_own_path_with_a_video_is_rescanned_not_repointed(self):
        real = self.folder("HD/P/Project Hail Mary (2026)")
        ok, out, fake = self.run_once(
            [movie(1, "Project Hail Mary", 2026, 687163, real)], apply=True)
        self.assertEqual([c for c in fake.calls if c[0] == "PUT"], [])
        self.assertIn("rescanned Project Hail Mary (2026) [radarr 1]", out)

    def test_http_error_is_counted_without_the_body(self):
        self.folder("HD/G/Good Boy (2025)")
        ok, out, _ = self.run_once(
            [movie(1, "Good Boy", 2025, 5, "/x/AnyStream/Good Boy (2025)")], apply=True, fail_put=True)
        self.assertFalse(ok)
        self.assertIn("error on Good Boy (2025) [radarr 1]: HTTP 500 on PUT /api/v3/movie/1", out)
        self.assertNotIn("echo", out)
        self.assertIn("1 errors", out)


class Credential(Base):
    def test_missing_key_element_stops_without_a_value(self):
        Path(self.cfg).write_text("<Config><Port>7878</Port></Config>")
        with self.assertRaises(SystemExit) as e:
            rr.read_credential(self.cfg)
        self.assertIn("has no API key element", str(e.exception))

    def test_repr_hides_the_credential(self):
        self.assertNotIn(self.credential, repr(rr.Radarr("http://r", self.credential)))

    def test_main_once_sets_and_clears_the_status_file(self):
        self.folder("HD/G/Good Boy (2025)")
        fake = FakeRadarr([movie(1, "Good Boy", 2025, 5, "/x/AnyStream/Good Boy (2025)")],
                          self.credential)
        status = self.root / "ok"
        env = {"RADARR_URL": fake.url, "RADARR_CONFIG": self.cfg,
               "RECONCILE_SEARCH": str(self.lib), "RECONCILE_STATUS": str(status)}
        out = io.StringIO()
        try:
            with unittest.mock.patch.dict("os.environ", env), contextlib.redirect_stdout(out):
                self.assertEqual(rr.main(["--once"]), 0)
                self.assertTrue(status.exists())
                env["RADARR_URL"] = "http://127.0.0.1:9"  # nothing listens: the run fails
                with unittest.mock.patch.dict("os.environ", env):
                    self.assertEqual(rr.main(["--once"]), 1)
                self.assertFalse(status.exists())
        finally:
            fake.close()
        self.assertIn("run failed: GET /api/v3/movie failed", out.getvalue())
        self.assertNotIn(self.credential, out.getvalue())


import unittest.mock  # noqa: E402

if __name__ == "__main__":
    unittest.main(verbosity=2)
