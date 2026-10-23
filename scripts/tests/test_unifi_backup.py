#!/usr/bin/env python3
"""Offline test of d03/apps/unifi-backup/unifi_backup.py: the decrypt, the check, the copy cycle (stdlib unittest).

    python3 scripts/tests/test_unifi_backup.py

The connector's answers are built here in the shapes read on 2026-10-23 (v1/hosts,
dl/autobackup/autobackup_meta.json); nothing reaches the network. The .unf stand-ins are small zips
encrypted with the system's openssl (its tests skip without one); they hold no real configuration.
"""
from __future__ import annotations

import datetime as dt
import gzip
import importlib.util
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import unittest.mock
import urllib.error
import zipfile
from pathlib import Path

APP = Path(__file__).resolve().parents[2] / "d03" / "apps" / "unifi-backup"
_spec = importlib.util.spec_from_file_location("unifi_backup", APP / "unifi_backup.py")
ub = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ub)
ub.urllib.request.urlopen = lambda *a, **kw: (_ for _ in ()).throw(AssertionError("network"))

OPENSSL = shutil.which("openssl")
API_VALUE = "stand-in-api-value"   # what the fake API checks the header against; not a real one


def unf(members: dict[str, bytes] | None = None, tail: bytes = b"") -> bytes:
    """A .unf as a console writes it: a zip, zero-filled to the block size, AES-128-CBC with the fixed setting."""
    if members is None:
        members = {"version": b"10.6.106\n", "format": b"bson\n", "db.gz": gzip.compress(b"\x00" * 5000)}
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for n, b in members.items():
            z.writestr(n, b)
    raw = buf.getvalue() + tail
    raw += b"\x00" * (-len(raw) % 16)
    k, iv = ub.UNF_AES
    return subprocess.run([OPENSSL, "enc", "-aes-128-cbc", "-nopad", "-K", k.hex(), "-iv", iv.hex()],
                          input=raw, capture_output=True, check=True).stdout


class Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


class FakeApi:
    """api.ui.com as the cycle sees it: v1/hosts and, per console, the autobackup folder."""

    def __init__(self, consoles: dict[str, dict[str, bytes]], times: dict[str, str] | None = None):
        self.consoles, self.times = consoles, times or {}
        self.sizes: dict[str, int] = {}   # a listed size that differs from the file
        self.down = False
        self.calls: list[str] = []

    def __call__(self, req, timeout=None):
        assert req.get_method() == "GET", req.get_method()
        assert req.get_header("X-api-key") == API_VALUE
        url = req.full_url
        self.calls.append(url)
        if self.down:
            raise urllib.error.URLError("unreachable")
        rel = url.removeprefix(ub.API)
        if rel.startswith("v1/hosts"):
            return Resp(json.dumps({"data": [{"id": f"id-{n}", "reportedState": {"name": n}}
                                             for n in self.consoles]}).encode())
        for n, files in self.consoles.items():
            base = ub.AUTOBACKUP.format(id=f"id-{n}")
            if not rel.startswith(base):
                continue
            fn = rel.removeprefix(base)
            if fn == "autobackup_meta.json":
                return Resp(json.dumps({f: {"filename": f, "datetime": self.times.get(f, "2026-10-01T05:30:00Z"),
                                            "version": "10.6.106", "format": "bson",
                                            "size": self.sizes.get(f, len(b))}
                                        for f, b in files.items()}).encode())
            if fn in files:
                return Resp(files[fn])
        raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)


@unittest.skipUnless(OPENSSL, "needs openssl to make .unf stand-ins")
class Check(unittest.TestCase):
    def test_fips197_vector(self):
        ct = bytes.fromhex("69c4e0d86a7b0430d8cdb78070b4c55a")
        self.assertEqual(ub.aes128_cbc_decrypt(ct, bytes(range(16)), bytes(16)).hex(),
                         "00112233445566778899aabbccddeeff")

    def test_cbc_equals_openssl(self):
        data, k, iv = os.urandom(4096), os.urandom(16), os.urandom(16)
        enc = subprocess.run([OPENSSL, "enc", "-aes-128-cbc", "-nopad", "-K", k.hex(), "-iv", iv.hex()],
                             input=data, capture_output=True, check=True).stdout
        self.assertEqual(ub.aes128_cbc_decrypt(enc, k, iv), data)

    def test_a_good_unf_opens(self):
        r = ub.check_unf(unf())
        self.assertEqual((r["version"], r["members"], r["db_bytes"]), ("10.6.106", 3, 5000))

    def test_trailing_bytes_after_the_zip_are_fine(self):
        self.assertEqual(ub.check_unf(unf(tail=b"\x00" * 40))["version"], "10.6.106")

    def test_refusals(self):
        cases = {
            "not a whole number of AES blocks": unf()[:-3],
            "does not decrypt to a zip": os.urandom(256),
            "zip has no db.gz": unf({"version": b"10.6.106"}),
            "db.gz does not decompress": unf({"version": b"1", "db.gz": b"not gzip at all"}),
        }
        for want, blob in cases.items():
            with self.subTest(want), self.assertRaises(ub.BadCopy) as e:
                ub.check_unf(blob)
            self.assertIn(want.split()[-1], str(e.exception))

    def test_a_flipped_byte_is_caught(self):
        blob = bytearray(unf({"version": b"1", "db.gz": gzip.compress(os.urandom(3000))}))
        blob[200] ^= 0xFF
        with self.assertRaises(ub.BadCopy):
            ub.check_unf(bytes(blob))


@unittest.skipUnless(OPENSSL, "needs openssl to make .unf stand-ins")
class Cycle(unittest.TestCase):
    MKE1, MKE2 = "autobackup_10.6.101_20260901_0530_1.unf", "autobackup_10.6.106_20261001_0530_2.unf"
    DAY1 = "autobackup_10.6.106_20261001_0400_3.unf"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        ub.DATA, ub.COPIES = root / "data", root / "copies"
        ub.DATA.mkdir()
        self.cfg = root / "unifi-backup.toml"
        shutil.copy(APP / "unifi-backup.toml", self.cfg)
        ub.CONFIG = self.cfg
        os.environ[ub.KEY_ENV] = API_VALUE
        self.api = FakeApi({"MKE": {self.MKE1: unf(), self.MKE2: unf()}, "DAY": {self.DAY1: unf()}},
                           {self.MKE1: "2026-09-01T05:30:00Z", self.MKE2: "2026-10-01T05:30:00Z",
                            self.DAY1: "2026-10-01T04:00:00Z"})
        ub.urllib.request.urlopen = self.api
        self.at(dt.datetime(2026, 10, 23, 16, 0, tzinfo=dt.timezone.utc))

    def tearDown(self):
        ub.urllib.request.urlopen = lambda *a, **kw: (_ for _ in ()).throw(AssertionError("network"))
        self.tmp.cleanup()

    def at(self, t):
        ub.now = lambda: t

    def run_cycle(self) -> dict:
        with open(os.devnull, "w") as null, unittest.mock.patch("sys.stdout", null):
            self.assertEqual(ub.cycle(), 0)
        return json.loads((ub.DATA / "status.json").read_text())

    def keys(self, s):
        return {p["key"]: p["severity"] for p in s["problems"]}

    def test_copies_each_file_once_and_checks_it(self):
        s = self.run_cycle()
        self.assertEqual(self.keys(s), {})
        self.assertTrue(s["ok"])
        self.assertEqual(sorted(p.name for p in (ub.COPIES / "MKE").iterdir()), [self.MKE1, self.MKE2])
        self.assertEqual((ub.COPIES / "MKE" / self.MKE2).stat().st_mode & 0o777, 0o600)
        self.assertEqual((ub.COPIES / "MKE").stat().st_mode & 0o777, 0o700)
        self.assertEqual(s["consoles"]["MKE"]["newest_copy"], self.MKE2)
        n = len(self.api.calls)
        s = self.run_cycle()   # second cycle: the list only, no file fetched again
        self.assertEqual(len(self.api.calls) - n, 3)
        self.assertEqual(s["consoles"]["DAY"]["copied_now"], [])

    def test_a_wrong_size_is_not_kept_and_then_missed(self):
        self.api.sizes[self.MKE2] = 99
        s = self.run_cycle()
        self.assertEqual(self.keys(s), {f"copy:MKE:{self.MKE2}": "warn", "missed:MKE": "urgent"})
        self.assertFalse((ub.COPIES / "MKE" / self.MKE2).exists())
        self.assertFalse(any(p.name.endswith(".part") for p in (ub.COPIES / "MKE").iterdir()))

    def test_a_new_backup_has_a_day_before_it_is_missed(self):
        self.api.sizes[self.MKE2] = 99
        self.at(dt.datetime(2026, 10, 1, 20, 0, tzinfo=dt.timezone.utc))   # 14.5 h after it was made
        self.assertNotIn("missed:MKE", self.keys(self.run_cycle()))

    def test_api_failures_turn_urgent_on_the_third_cycle(self):
        self.api.down = True
        for sev in ("warn", "warn", "urgent"):
            s = self.run_cycle()
            self.assertEqual(self.keys(s), {"api:MKE": sev, "api:DAY": sev})
            self.assertFalse(s["ok"])
        self.api.down = False
        self.assertEqual(self.keys(self.run_cycle()), {})

    def test_a_console_not_listed_is_an_api_problem(self):
        del self.api.consoles["DAY"]
        self.assertEqual(self.keys(self.run_cycle()), {"api:DAY": "warn"})

    def test_a_console_that_stops_backing_up_is_reported(self):
        self.at(dt.datetime(2026, 11, 3, 6, 0, tzinfo=dt.timezone.utc))
        self.assertEqual(self.keys(self.run_cycle()), {"stale:MKE": "warn", "stale:DAY": "warn"})

    def test_a_name_with_a_path_is_ignored(self):
        self.api.consoles["MKE"]["../../autobackup_x.unf"] = unf()
        self.run_cycle()
        self.assertFalse((ub.COPIES / "autobackup_x.unf").exists())
        self.assertFalse(any(Path(self.tmp.name).glob("autobackup_x.unf")))

    def test_staged_alert_and_no_key_in_status(self):
        (ub.DATA / "stage.json").write_text(json.dumps({"until": "2026-10-23T18:00:00Z", "note": "test"}))
        s = self.run_cycle()
        self.assertEqual(self.keys(s), {"staged": "urgent"})
        self.assertNotIn(API_VALUE, (ub.DATA / "status.json").read_text())

    def test_check_newest(self):
        self.run_cycle()
        with open(os.devnull, "w") as null, unittest.mock.patch("sys.stdout", null):
            self.assertEqual(ub.main(["--check-newest"]), 0)
            (ub.COPIES / "DAY" / self.DAY1).write_bytes(b"\x00" * 64)
            self.assertEqual(ub.main(["--check-newest"]), 1)


if __name__ == "__main__":
    unittest.main()
