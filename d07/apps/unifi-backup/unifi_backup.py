#!/usr/bin/env python3
"""Copy the UniFi Network autobackups of each console to the NAS, and check each copy opens. GET only.

    unifi_backup.py                 # one cycle (the unifi-backup container runs it every hour)
    unifi_backup.py --check FILE    # does this .unf open: decrypt, zip CRCs, db.gz; no key, no network
    unifi_backup.py --check-newest  # the same for each console's newest copy

The unifi-backup container (compose.yml) runs one cycle every UNIFI_INTERVAL seconds, a fresh process
each time, so a script update from the nightly scripts task applies at the next cycle. Per cycle, to
https://api.ui.com/ with the Site Manager key: GET v1/hosts (each console's id), then per console
through the connector GET .../proxy/network/dl/autobackup/autobackup_meta.json (the console's list
of autobackups: filename, datetime, version, size) and GET .../dl/autobackup/FILE for each file not
yet copied. The connector passes /proxy/network/ only (UniFi OS paths answer 403, 2026-10-23), so the
weekly UniFi OS console backups are out of reach; these are the Network application's own (Settings >
Control Plane > Backups; monthly on both consoles, operator 2026-10-23: kept).

A file is copied to COPIES/<console>/FILE.part, checked, then renamed to FILE (mode 600): a FILE that
exists was checked, so the cycle skips it. Nothing is ever deleted here; history is nas01's daily
ZFS snapshots of data1/docker. The check: the size the console reported; AES-128-CBC decrypt with
the fixed key and IV every UniFi .unf uses (github.com/zhangyoufu/unifi-backup-decrypt decrypt.sh:
openssl enc -d -aes-128-cbc -nopad, then zip -FF); the zip inside opens and every member's CRC
holds; it has `version` and `db.gz`, and db.gz decompresses whole. A .unf holds WLAN passphrases and
admin password hashes (the fixed key is public): nothing of its content is printed or kept outside
COPIES.

Writes, in UNIFI_DATA (/data, the host's /mnt/docker/unifi-backup):
  status.json  {"time", "checker", "ok", "problems": [{"key", "severity", "message"}], "consoles"}:
               read by the host-maintenance monitor on each run ([[status]] in its
               config/maintenance.toml); "urgent" mails at once, "warn" goes to the 07:00 digest
  state.json   API failures in a row, per console
stage.json, written by `unifi-backup.sh stage`, adds one urgent problem until it expires: the
end-to-end test of the alert path.

Key: UNIFI_SITE_MANAGER_API_KEY from the environment, sent as a header, never printed.
Config: unifi-backup.toml beside this file.
"""
from __future__ import annotations

import argparse
import datetime as dt
import gzip
import io
import json
import os
import re
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

API = "https://api.ui.com/"
KEY_ENV = "UNIFI_SITE_MANAGER_API_KEY"
DATA = Path(os.environ.get("UNIFI_DATA", "/data"))
COPIES = Path(os.environ.get("UNIFI_COPIES", "/copies"))
CONFIG = Path(os.environ.get("UNIFI_CONFIG", Path(__file__).with_name("unifi-backup.toml")))
AUTOBACKUP = "v1/connector/consoles/{id}/proxy/network/dl/autobackup/"
NAME = re.compile(r"autobackup_[0-9A-Za-z._-]+\.unf")   # a name from the console: no path in it
# Every UniFi .unf is encrypted with this one public cipher setting (decrypt.sh, cited above).
UNF_AES = (b"bcyangkmluohmars", b"ubntenterpriseap")


class ApiError(Exception):
    pass


class BadCopy(Exception):
    pass


def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(t: dt.datetime) -> str:
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse(s: str | None) -> dt.datetime | None:
    if not s:
        return None
    try:
        t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


# --- AES-128 decryption (FIPS-197), stdlib only: the container image has no openssl. ---------------

def _xt(a: int) -> int:
    a <<= 1
    return a ^ 0x11B if a & 0x100 else a


def _mul(a: int, b: int) -> int:
    r = 0
    while b:
        if b & 1:
            r ^= a
        a, b = _xt(a), b >> 1
    return r


def _rotl8(x: int, n: int) -> int:
    return (x << n | x >> (8 - n)) & 0xFF


def _tables():
    sbox = [0] * 256
    p = q = 1
    while True:   # p walks GF(2^8) by 3, q by 1/3 (its inverse): S(p) = affine(q)
        p = _xt(p) ^ p
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        sbox[p] = q ^ _rotl8(q, 1) ^ _rotl8(q, 2) ^ _rotl8(q, 3) ^ _rotl8(q, 4) ^ 0x63
        if p == 1:
            break
    sbox[0] = 0x63
    inv = [0] * 256
    for i, s in enumerate(sbox):
        inv[s] = i
    td = [[0] * 256 for _ in range(4)]
    for i in range(256):
        s = inv[i]
        w = _mul(s, 14) << 24 | _mul(s, 9) << 16 | _mul(s, 13) << 8 | _mul(s, 11)
        for r in range(4):
            td[r][i] = (w >> (8 * r) | w << (32 - 8 * r)) & 0xFFFFFFFF
    return sbox, inv, td


SBOX = INV = TD = None


def _init():
    global SBOX, INV, TD
    if SBOX is None:
        SBOX, INV, TD = _tables()


def _expand(key: bytes) -> list[list[int]]:
    """Round keys as 4 words each; then turned into the decryption schedule (equivalent inverse)."""
    w = [int.from_bytes(key[i:i + 4], "big") for i in range(0, 16, 4)]
    rcon = 1
    for i in range(4, 44):
        t = w[i - 1]
        if i % 4 == 0:
            t = (t << 8 | t >> 24) & 0xFFFFFFFF
            t = SBOX[t >> 24] << 24 | SBOX[t >> 16 & 255] << 16 | SBOX[t >> 8 & 255] << 8 | SBOX[t & 255]
            t ^= rcon << 24
            rcon = _xt(rcon) & 0xFF
        w.append(w[i - 4] ^ t)
    rk = [w[4 * r:4 * r + 4] for r in range(11)][::-1]
    for r in range(1, 10):   # InvMixColumns on the middle round keys
        rk[r] = [TD[0][SBOX[x >> 24]] ^ TD[1][SBOX[x >> 16 & 255]] ^ TD[2][SBOX[x >> 8 & 255]] ^ TD[3][SBOX[x & 255]]
                 for x in rk[r]]
    return rk


def aes128_cbc_decrypt(data: bytes, key: bytes, iv: bytes) -> bytes:
    """AES-128-CBC without padding removal (openssl enc -d -nopad). len(data) % 16 == 0."""
    if len(data) % 16:
        raise BadCopy(f"size {len(data)} is not a whole number of AES blocks")
    _init()
    rk = _expand(key)
    t0, t1, t2, t3 = TD
    inv = INV
    out = bytearray(len(data))
    prev = [int.from_bytes(iv[i:i + 4], "big") for i in range(0, 16, 4)]
    mv = memoryview(data)
    for off in range(0, len(data), 16):
        c = [int.from_bytes(mv[off + i:off + i + 4], "big") for i in range(0, 16, 4)]
        k = rk[0]
        s0, s1, s2, s3 = c[0] ^ k[0], c[1] ^ k[1], c[2] ^ k[2], c[3] ^ k[3]
        for r in range(1, 10):
            k = rk[r]
            s0, s1, s2, s3 = (
                t0[s0 >> 24] ^ t1[s3 >> 16 & 255] ^ t2[s2 >> 8 & 255] ^ t3[s1 & 255] ^ k[0],
                t0[s1 >> 24] ^ t1[s0 >> 16 & 255] ^ t2[s3 >> 8 & 255] ^ t3[s2 & 255] ^ k[1],
                t0[s2 >> 24] ^ t1[s1 >> 16 & 255] ^ t2[s0 >> 8 & 255] ^ t3[s3 & 255] ^ k[2],
                t0[s3 >> 24] ^ t1[s2 >> 16 & 255] ^ t2[s1 >> 8 & 255] ^ t3[s0 & 255] ^ k[3])
        k = rk[10]
        p = (
            (inv[s0 >> 24] << 24 | inv[s3 >> 16 & 255] << 16 | inv[s2 >> 8 & 255] << 8 | inv[s1 & 255]) ^ k[0],
            (inv[s1 >> 24] << 24 | inv[s0 >> 16 & 255] << 16 | inv[s3 >> 8 & 255] << 8 | inv[s2 & 255]) ^ k[1],
            (inv[s2 >> 24] << 24 | inv[s1 >> 16 & 255] << 16 | inv[s0 >> 8 & 255] << 8 | inv[s3 & 255]) ^ k[2],
            (inv[s3 >> 24] << 24 | inv[s2 >> 16 & 255] << 16 | inv[s1 >> 8 & 255] << 8 | inv[s0 & 255]) ^ k[3])
        out[off:off + 16] = b"".join((p[i] ^ prev[i]).to_bytes(4, "big") for i in range(4))
        prev = c
    return bytes(out)


# --- the check of one .unf -------------------------------------------------------------------------

def check_unf(blob: bytes) -> dict:
    """Decrypt and open a .unf in memory; raise BadCopy, else {version, members, db_bytes}."""
    raw = aes128_cbc_decrypt(blob, *UNF_AES)
    if not raw.startswith(b"PK\x03\x04"):
        raise BadCopy("does not decrypt to a zip archive")
    try:
        z = zipfile.ZipFile(io.BytesIO(raw))   # trailing cipher padding after the end record is fine
        names = z.namelist()
        bad = z.testzip()
    except (zipfile.BadZipFile, OSError, EOFError, ValueError) as e:
        raise BadCopy(f"zip does not open: {type(e).__name__}") from None
    if bad:
        raise BadCopy(f"zip member {bad} fails its CRC")
    for need in ("version", "db.gz"):
        if need not in names:
            raise BadCopy(f"zip has no {need}")
    try:
        with gzip.GzipFile(fileobj=z.open("db.gz")) as g:
            db = sum(len(b) for b in iter(lambda: g.read(1 << 20), b""))
    except (OSError, EOFError) as e:
        raise BadCopy(f"db.gz does not decompress: {type(e).__name__}") from None
    version = z.read("version").decode("ascii", "replace").strip()
    return {"version": version, "members": len(names), "db_bytes": db}


# --- the cycle -------------------------------------------------------------------------------------

def request(rel: str, key: str, timeout: int = 60):
    req = urllib.request.Request(API + rel, headers={"X-API-KEY": key}, method="GET")
    try:
        return urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.HTTPError as e:   # the code only: a body is not ours to print
        raise ApiError(f"GET {rel.split('?')[0]}: HTTP {e.code}") from None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise ApiError(f"GET {rel.split('?')[0]}: {type(e).__name__}: {getattr(e, 'reason', e)}") from None


def get_json(rel: str, key: str):
    try:
        with request(rel, key) as r:
            return json.load(r)
    except (ValueError, OSError) as e:
        raise ApiError(f"GET {rel.split('?')[0]}: {type(e).__name__}") from None


def download(rel: str, key: str, dest: Path) -> int:
    n = 0
    try:
        with request(rel, key, timeout=600) as r, open(dest, "wb") as f:
            for chunk in iter(lambda: r.read(1 << 20), b""):
                f.write(chunk)
                n += len(chunk)
    except OSError as e:
        raise ApiError(f"GET {rel}: {type(e).__name__}") from None
    return n


def console_ids(hosts: list) -> dict:
    out = {}
    for h in hosts:
        rs = h.get("reportedState") or {}
        for n in (rs.get("name"), rs.get("hostname")):
            if n:
                out.setdefault(str(n).lower(), h.get("id"))
    return out


def load_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)


def copy_console(name: str, cid: str, key: str, ccfg: dict, cfg: dict, t: dt.datetime) -> tuple[list, dict]:
    """Copy what is missing for one console; (findings, summary). Raises ApiError on a failed read."""
    found = []
    base = AUTOBACKUP.format(id=urllib.parse.quote(cid, safe=""))
    meta = get_json(base + "autobackup_meta.json", key)
    files = [m for m in (meta.values() if isinstance(meta, dict) else [])
             if isinstance(m, dict) and NAME.fullmatch(str(m.get("filename", "")))]
    folder = COPIES / name
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    copied = []
    for m in sorted(files, key=lambda m: m.get("datetime") or ""):
        fn = m["filename"]
        final = folder / fn
        if final.exists():
            continue
        part = folder / (fn + ".part")
        try:
            got = download(base + urllib.parse.quote(fn), key, part)
            if isinstance(m.get("size"), int) and got != m["size"]:
                raise BadCopy(f"{got} bytes, the console lists {m['size']}")
            check_unf(part.read_bytes())
            part.chmod(0o600)
            part.replace(final)
            copied.append(fn)
        except BadCopy as e:
            found.append((f"copy:{name}:{fn}", "warn", f"UniFi backup {name}: {fn} copied but does not check: {e}"))
        finally:
            part.unlink(missing_ok=True)
    have = sorted(p.name for p in folder.glob("autobackup_*.unf"))
    newest = max(files, key=lambda m: m.get("datetime") or "", default=None)
    newest_t = parse(newest.get("datetime")) if newest else None
    if newest is None:
        found.append((f"none:{name}", "warn", f"UniFi backup {name}: the console lists no autobackup"))
    else:
        if newest["filename"] not in have and newest_t and t - newest_t > dt.timedelta(hours=cfg["copy_grace_hours"]):
            found.append((f"missed:{name}", "urgent",
                          f"UniFi backup {name}: the console's newest autobackup {newest['filename']} "
                          f"({iso(newest_t)}) is not on the NAS after {cfg['copy_grace_hours']} h"))
        if newest_t and t - newest_t > dt.timedelta(days=ccfg["max_age_days"]):
            found.append((f"stale:{name}", "warn",
                          f"UniFi backup {name}: the console's newest autobackup is from {iso(newest_t)}, "
                          f"older than {ccfg['max_age_days']} days (autobackup off or failing?)"))
    summary = {"console_files": len(files), "copies": len(have), "copied_now": copied,
               "newest": newest["filename"] if newest else None, "newest_copy": have[-1] if have else None}
    return found, summary


def staged(t: dt.datetime) -> list:
    st = load_json(DATA / "stage.json", None)
    until = parse((st or {}).get("until"))
    if not until or until <= t:
        return []
    return [("staged", "urgent", f"UniFi backup: staged test alert, {st.get('note') or 'no note'} "
                                 f"(until {iso(until)}; not a real failure)")]


def cycle() -> int:
    key = os.environ.get(KEY_ENV, "")
    if not key:
        print(f"{KEY_ENV} is not set: the container starts only through unifi-backup.sh up", file=sys.stderr)
        return 2
    os.umask(0o077)
    with open(CONFIG, "rb") as f:
        cfg = tomllib.load(f)
    t = now()
    state = load_json(DATA / "state.json", {})
    fails = state.setdefault("api_fails", {})
    found, summary = [], {}
    try:
        ids = console_ids(get_json("v1/hosts?pageSize=100", key).get("data") or [])
        hosts_err = None
    except ApiError as e:
        ids, hosts_err = {}, e
    for name, ccfg in cfg.get("consoles", {}).items():
        try:
            if hosts_err:
                raise hosts_err
            cid = ids.get(name.lower())
            if not cid:
                raise ApiError(f"console {name} not listed in Site Manager v1/hosts")
            f, summary[name] = copy_console(name, cid, key, ccfg, cfg, t)
            found += f
            fails[name] = 0
        except ApiError as e:
            fails[name] = fails.get(name, 0) + 1
            sev = "urgent" if fails[name] >= cfg["api_fails_urgent"] else "warn"
            found.append((f"api:{name}", sev, f"UniFi backup {name}: cannot read or copy ({fails[name]} cycles "
                                              f"in a row): {e}"))
    found += staged(t)
    problems = [{"key": k, "severity": s, "message": m.replace(key, "<redacted>")} for k, s, m in found]
    ok = not any(p["key"].startswith("api:") for p in problems)
    write_atomic(DATA / "state.json", json.dumps(state, indent=1, sort_keys=True))
    write_atomic(DATA / "status.json", json.dumps(
        {"time": iso(t), "checker": "unifi-backup", "ok": ok, "problems": problems, "consoles": summary},
        indent=1, sort_keys=True))
    print(f"{iso(t)} ok={ok} " + " ".join(f"{n}:{s['copies']}/{s['console_files']}"
                                         + (f"+{len(s['copied_now'])}" if s["copied_now"] else "")
                                         for n, s in summary.items())
          + "".join(f"\n  [{p['severity']}] {p['message']}" for p in problems), flush=True)
    return 0


def check_files(paths: list[Path]) -> int:
    rc = 0
    for p in paths:
        try:
            r = check_unf(p.read_bytes())
            print(f"OK {p}: opens; Network {r['version']}, {r['members']} members, db {r['db_bytes']} bytes")
        except (BadCopy, OSError) as e:
            print(f"FAIL {p}: {e}")
            rc = 1
    return rc


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", nargs="+", type=Path, metavar="FILE", help="check that each .unf opens")
    g.add_argument("--check-newest", action="store_true", help="check each console's newest copy")
    a = ap.parse_args(argv)
    if a.check:
        return check_files(a.check)
    if a.check_newest:
        newest = [max(d.glob("autobackup_*.unf"), key=lambda p: p.name)
                  for d in sorted(COPIES.iterdir()) if d.is_dir() and any(d.glob("autobackup_*.unf"))]
        if not newest:
            print(f"FAIL no copies under {COPIES}")
            return 1
        return check_files(newest)
    return cycle()


if __name__ == "__main__":
    sys.exit(main())
