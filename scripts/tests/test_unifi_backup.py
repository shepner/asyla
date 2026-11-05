#!/usr/bin/env python3
"""Offline test of d07/apps/unifi-backup/unifi_backup.py: the decrypt, the check, the copy cycle (stdlib unittest).

    python3 scripts/tests/test_unifi_backup.py

The connector's answers are built here in the shapes read on 2026-10-23 (v1/hosts,
dl/autobackup/autobackup_meta.json) and 2026-11-02 (HTTP 408 DeviceTimeout on a large file); nothing
reaches the network. The .unf stand-ins are small zips encrypted with the system's openssl (its tests
skip without one), built in the shapes of the consoles' files read on 2026-11-02 (member names, data
descriptors, the end record cut short by 10.x, zero padding by 11.0); they hold no real configuration.
"""
from __future__ import annotations

import datetime as dt
import gzip
import importlib.util
import io
import json
import os
import random
import shutil
import subprocess
import tempfile
import unittest
import unittest.mock
import urllib.error
import zipfile
from pathlib import Path

APP = Path(__file__).resolve().parents[2] / "d07" / "apps" / "unifi-backup"
_spec = importlib.util.spec_from_file_location("unifi_backup", APP / "unifi_backup.py")
ub = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ub)
ub.urllib.request.urlopen = lambda *a, **kw: (_ for _ in ()).throw(AssertionError("network"))

OPENSSL = shutil.which("openssl")
API_VALUE = "stand-in-api-value"   # what the fake API checks the header against; not a real one


def bson(**extra) -> dict[str, bytes]:
    """The members of a Network 10.x (format bson) autobackup, in its order; made-up content."""
    return {"version": b"10.6.106", "timestamp": b"1790832600037", "backup.json": b'{"type":"autobackup"}',
            "format": b"bson", "db_stat.gz": gzip.compress(b"\x00" * 900), "sites/": b"",
            "system.properties": b"# stand-in\n", "db.gz": gzip.compress(b"\x00" * 5000), **extra}


def postgres_v1(**extra) -> dict[str, bytes]:
    """The members of a Network 11.0 (format postgres_v1) autobackup (some of its 19); made-up content."""
    m = {"backup.json": b'{"type":"autobackup"}', "format": b"postgres_v1",
         "system.properties": b"# stand-in\n", "timestamp": b"1793511000025", "version": b"11.0.97"}
    for db in ("audit", "config", "logs", "stats"):
        m[f"db-{db}.schema.pre.sql.gz"] = gzip.compress(b"-- stand-in schema\n")
    m["db-config.jsonl.gz"] = gzip.compress(b'{"stand":"in"}\n' * 300)
    return {**m, **extra}


class Unseekable(io.RawIOBase):
    """A stream zipfile cannot seek back in, so it writes data descriptors as the consoles do (flag 0x08)."""

    def __init__(self):
        self.buf = bytearray()

    def writable(self):
        return True

    def write(self, b):
        self.buf += b
        return len(b)


def zip_bytes(members: dict[str, bytes], filler: int = 0) -> bytes:
    out = Unseekable()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for n, b in members.items():
            z.writestr(n, b)
        if filler:   # incompressible: the zip grows by one byte per byte
            z.writestr("filler", random.Random(1).randbytes(filler))
    return bytes(out.buf)


def unf(members: dict[str, bytes] | None = None, end_left: int | None = 9, tail: bytes = b"") -> bytes:
    """A .unf as a console writes it, AES-128-CBC with the fixed setting.

    end_left: like 10.x, the zip's last part block is dropped, leaving this many of the end record's
    22 bytes (7-21; the consoles' files left 8-19). None: like 11.0, zero-filled to the block size.
    """
    members = bson() if members is None else members
    if end_left is None:
        raw = zip_bytes(members) + tail
        raw += b"\x00" * (-len(raw) % 16)
    else:
        want = 22 - end_left
        raw = next(r for r in (zip_bytes(members, n) for n in range(0, 64)) if len(r) % 16 == want)
        raw = raw[:len(raw) - want]
    return seal(raw)


def seal(raw: bytes) -> bytes:
    k, iv = ub.UNF_AES
    return subprocess.run([OPENSSL, "enc", "-aes-128-cbc", "-nopad", "-K", k.hex(), "-iv", iv.hex()],
                          input=raw, capture_output=True, check=True).stdout


class TimeoutBody(io.BytesIO):
    def close(self):   # what the connector sends with its 408
        pass


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
        self.slow: set[str] = set()       # files the connector gives up on (HTTP 408 DeviceTimeout)
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
            if fn in self.slow:
                raise urllib.error.HTTPError(url, 408, "Request Timeout", {}, TimeoutBody(b'{"code":"DeviceTimeout"}'))
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

    def test_a_10x_file_with_its_end_record_cut_opens(self):
        for left in (7, 8, 9, 14, 15, 18, 19, 21):
            with self.subTest(left=left):
                blob = unf(end_left=left)
                raw = ub.aes128_cbc_decrypt(blob, *ub.UNF_AES)
                self.assertEqual(len(raw) - raw.rfind(ub.EOCD), left)
                with self.assertRaises(zipfile.BadZipFile):   # what failed on d07, 2026-11-02
                    zipfile.ZipFile(io.BytesIO(raw))
                r = ub.check_unf(blob)
                self.assertEqual((r["version"], r["format"], r["known"], r["members"]), ("10.6.106", "bson", True, 9))
                self.assertEqual(r["db_bytes"], 5900)

    def test_a_11x_postgres_file_opens(self):
        r = ub.check_unf(unf(postgres_v1(), end_left=None))
        self.assertEqual((r["version"], r["format"], r["known"], r["members"]), ("11.0.97", "postgres_v1", True, 10))

    def test_zero_padding_after_the_zip_is_fine(self):
        self.assertEqual(ub.check_unf(unf(end_left=None, tail=b"\x00" * 40))["version"], "10.6.106")

    def test_a_central_header_inside_a_member_is_not_taken_for_the_directory(self):
        m = bson(**{"sites/default/x": b"PK\x01\x02" + bytes(60)})
        out = Unseekable()
        with zipfile.ZipFile(out, "w") as z:   # stored, so the signature stays in the file as written
            for n, b in m.items():
                z.writestr(n, b)
        raw = bytes(out.buf)
        self.assertGreater(raw.count(ub.CDH), len(m))
        cut = len(raw) % 16 or 16
        mended = ub.mend_end(raw[:-cut])
        self.assertEqual(zipfile.ZipFile(io.BytesIO(mended)).namelist(), list(m))

    def test_an_unknown_format_is_kept_and_named(self):
        r = ub.check_unf(unf({"version": b"12.0.1", "format": b"sqlite_v2", "db.sqlite.gz": gzip.compress(b"x")}))
        self.assertEqual((r["format"], r["known"]), ("sqlite_v2", False))

    def test_refusals(self):
        cut = unf()
        cases = {
            "not a whole number of AES blocks": cut[:-3],
            "does not decrypt to a zip": os.urandom(256),
            "zip does not open": cut[:-64],   # the central directory itself is gone
            "zip has no format": unf({"version": b"10.6.106", "db.gz": gzip.compress(b"x")}),
            "zip has no db.gz (format bson)": unf({k: v for k, v in bson().items() if k != "db.gz"}),
            "zip has no db-config.jsonl.gz (format postgres_v1)":
                unf({k: v for k, v in postgres_v1().items() if k != "db-config.jsonl.gz"}, end_left=None),
            "db.gz does not decompress": unf(bson(**{"db.gz": b"not gzip at all"})),
            "db_stat.gz does not decompress": unf(bson(**{"db_stat.gz": b"not gzip either"})),
        }
        for want, blob in cases.items():
            with self.subTest(want), self.assertRaises(ub.BadCopy) as e:
                ub.check_unf(blob)
            self.assertIn(want, str(e.exception))

    def test_broken_deflate_data_is_a_bad_copy_not_a_crash(self):
        raw = bytearray(zip_bytes(bson()))
        at = raw.find(b"db.gz") + len(b"db.gz")   # its local header's name; the deflate data follows
        raw[at] = 0xFF   # block type 3 does not exist: zlib.error, not BadZipFile
        raw += b"\x00" * (-len(raw) % 16)
        with self.assertRaises(ub.BadCopy) as e:
            ub.check_unf(seal(bytes(raw)))
        self.assertIn("zip does not open: error", str(e.exception))

    def test_a_flipped_byte_is_caught(self):
        blob = bytearray(unf(bson(**{"db.gz": gzip.compress(os.urandom(3000))})))
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
        self.assertEqual(self.keys(s), {f"copy:MKE:{self.MKE2}": "warn", "missed:MKE": "warn"})
        self.assertFalse((ub.COPIES / "MKE" / self.MKE2).exists())
        self.assertFalse(any(p.name.endswith(".part") for p in (ub.COPIES / "MKE").iterdir()))

    def test_a_new_backup_has_a_day_before_it_is_missed(self):
        self.api.sizes[self.MKE2] = 99
        self.at(dt.datetime(2026, 10, 1, 20, 0, tzinfo=dt.timezone.utc))   # 14.5 h after it was made
        self.assertNotIn("missed:MKE", self.keys(self.run_cycle()))

    def test_api_failures_stay_warnings_and_count_the_cycles(self):
        self.api.down = True
        for n in range(1, 7):
            s = self.run_cycle()
            self.assertEqual(self.keys(s), {"api:MKE": "warn", "api:DAY": "warn"})
            self.assertIn(f"({n} cycles in a row)", s["problems"][0]["message"])
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

    def test_newest_first_and_an_older_file_that_times_out_is_listed_not_alerted(self):
        self.api.slow.add(self.MKE1)
        s = self.run_cycle()
        self.assertEqual(self.keys(s), {})
        self.assertTrue(s["ok"])
        self.assertEqual(s["consoles"]["MKE"]["copied_now"], [self.MKE2])
        self.assertIn("HTTP 408", s["consoles"]["MKE"]["not_fetched"][self.MKE1])
        fetched = [u.rsplit("/", 1)[-1] for u in self.api.calls if u.endswith(".unf")]
        self.assertEqual(fetched[:2], [self.MKE2, self.MKE1])
        self.api.slow.clear()   # tried again next cycle
        s = self.run_cycle()
        self.assertEqual((s["consoles"]["MKE"]["copied_now"], s["consoles"]["MKE"]["not_fetched"]), ([self.MKE1], {}))

    def test_the_newest_timing_out_is_an_api_problem_but_older_files_are_copied(self):
        self.api.slow.add(self.MKE2)
        self.at(dt.datetime(2026, 10, 1, 12, 0, tzinfo=dt.timezone.utc))   # 6.5 h after it was made
        for _ in range(3):
            s = self.run_cycle()
            self.assertEqual(self.keys(s), {"api:MKE": "warn"})
            self.assertFalse(s["ok"])
        self.assertIn("HTTP 408", s["problems"][0]["message"])
        self.assertEqual(s["consoles"]["MKE"]["newest_copy"], self.MKE1)
        self.at(dt.datetime(2026, 10, 2, 6, 0, tzinfo=dt.timezone.utc))   # 24.5 h after it was made
        self.assertEqual(self.keys(self.run_cycle()), {"api:MKE": "warn", "missed:MKE": "warn"})

    def test_both_formats_are_copied_and_an_unknown_one_is_kept_with_a_warning(self):
        self.api.consoles["DAY"][self.DAY1] = unf(postgres_v1(), end_left=None)
        self.api.consoles["MKE"][self.MKE2] = unf({"version": b"12.0.1", "format": b"sqlite_v2"})
        s = self.run_cycle()
        self.assertEqual(self.keys(s), {"format:MKE": "warn"})
        self.assertTrue((ub.COPIES / "DAY" / self.DAY1).exists())
        self.assertTrue((ub.COPIES / "MKE" / self.MKE2).exists())

    def test_check_newest(self):
        self.run_cycle()
        with open(os.devnull, "w") as null, unittest.mock.patch("sys.stdout", null):
            self.assertEqual(ub.main(["--check-newest"]), 0)
            (ub.COPIES / "DAY" / self.DAY1).write_bytes(b"\x00" * 64)
            self.assertEqual(ub.main(["--check-newest"]), 1)


class AppScript(unittest.TestCase):
    def test_backup_is_seen_by_host_maintenance(self):
        # host-maintenance remote/maint_host.py script_supports: a `backup` it cannot see is never
        # run nor recorded, and the monitor then warns "no successful backup recorded yet".
        import re
        text = (APP / "unifi-backup.sh").read_text()
        self.assertRegex(text, re.compile(r"^\s*backup\)", re.M))


if __name__ == "__main__":
    unittest.main()
