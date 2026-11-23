#!/usr/bin/env python3
"""Point Radarr at movies that are already in the library but filed where Radarr does not look.

Movies reach the library outside Radarr (AnyStream, then filed by hand into
`Movies/HD|SD/<Letter>/Title (Year)/`), while Radarr keeps each wanted movie's path at an empty
folder (`AnyStream/...`, `radarr/...`). Radarr's own rescan only looks in that folder, so it never
finds the file. This finds the real folder for each monitored movie with no file, sets the movie's
path to it (files are not moved), and asks Radarr to rescan that movie.

A folder is a candidate when it directly holds a video file. A movie matches:

1. by id: the folder's .nfo names the movie's TMDB or IMDb id. Exactly one such folder, or skip.
2. else by name: the folder name equals the movie's own folder name or "Title (Year)", ignoring
   case and punctuation, and the folder's .nfo names no other TMDB/IMDb id. Exactly one, or skip.

A folder that is already another Radarr movie's path is never taken. Ambiguous matches are
reported, not guessed.

Dry run unless --apply. --every HOURS runs it in a loop (the container), --once runs it once.
The Radarr API key is read from Radarr's own config.xml at use and is never printed (asyla
decision: decisions/radarr-reconcile-reads-radarrs-own-key.md). Stdlib only; Python 3.11+.

    python3 radarr_reconcile.py [--apply] [--once | --every HOURS]

Settings (environment): RADARR_URL (http://radarr:7878), RADARR_CONFIG (/radarr-config/config.xml),
RECONCILE_SEARCH (/movies/Movies: walked for movie folders), RECONCILE_APPLY (1 = --apply),
RECONCILE_STATUS (/tmp/radarr-reconcile.ok: written after a run that worked, removed after one
that failed; the container's healthcheck reads it), RECONCILE_START_MINUTES (0: with --every, wait
this long before the first pass, so Radarr is up). With --every, a failed pass is retried after an
hour (or HOURS, if shorter) instead of a full interval.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime

VIDEO = (".mkv", ".mp4", ".m4v", ".avi", ".mov", ".ts", ".wmv", ".mpg", ".mpeg")
TIMEOUT = 30


def log(msg: str) -> None:
    print(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} radarr-reconcile: {msg}", flush=True)


def norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


class HttpError(Exception):
    """An HTTP failure, described without the response body (it may echo request data)."""


class Radarr:
    def __init__(self, url: str, credential: str):
        self.url = url.rstrip("/")
        self._credential = credential

    def __repr__(self) -> str:  # never show the credential
        return f"Radarr({self.url})"

    def call(self, method: str, path: str, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.url + path, data=data, method=method)
        req.add_header("X-Api-Key", self._credential)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            e.close()
            raise HttpError(f"HTTP {e.code} on {method} {path.split('?')[0]}") from None
        except (urllib.error.URLError, OSError) as e:
            reason = getattr(e, "reason", e)
            raise HttpError(f"{method} {path.split('?')[0]} failed: {type(reason).__name__}") from None
        return json.loads(raw) if raw else None


def read_credential(config_path: str) -> str:
    """Radarr's API key from its config.xml. The value is returned, never printed."""
    try:
        root = ET.parse(config_path).getroot()
    except (OSError, ET.ParseError) as e:
        raise SystemExit(f"cannot read Radarr's config ({config_path}): {type(e).__name__}") from None
    node = root.find("ApiKey")
    value = (node.text or "").strip() if node is not None else ""
    if not value:
        raise SystemExit(f"Radarr's config ({config_path}) has no API key element")
    return value


NFO_IDS = [
    ("tmdb", re.compile(r"<tmdbid>\s*(\d+)\s*</tmdbid>", re.I)),
    ("tmdb", re.compile(r"<uniqueid[^>]*type=\"tmdb\"[^>]*>\s*(\d+)\s*<", re.I)),
    ("imdb", re.compile(r"<imdbid>\s*(tt\d+)\s*</imdbid>", re.I)),
    ("imdb", re.compile(r"<uniqueid[^>]*type=\"imdb\"[^>]*>\s*(tt\d+)\s*<", re.I)),
    ("imdb", re.compile(r"<id>\s*(tt\d+)\s*</id>", re.I)),
]


def nfo_ids(folder: str, files: list[str]) -> dict[str, set[str]]:
    ids: dict[str, set[str]] = {"tmdb": set(), "imdb": set()}
    for f in files:
        if not f.lower().endswith(".nfo"):
            continue
        try:
            with open(os.path.join(folder, f), encoding="utf-8", errors="replace") as fh:
                text = fh.read(200_000)
        except OSError:
            continue
        for kind, rx in NFO_IDS:
            ids[kind].update(m.lower() for m in rx.findall(text))
    return ids


def scan_library(roots: list[str]) -> list[dict]:
    """Every folder under the roots that directly holds a video file, with its .nfo ids."""
    out = []
    for root in roots:
        for dirpath, dirnames, files in os.walk(root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            if any(f.lower().endswith(VIDEO) for f in files):
                out.append({"path": dirpath.rstrip("/"), "name": os.path.basename(dirpath),
                            "ids": nfo_ids(dirpath, files)})
    return out


def find_match(movie: dict, folders: list[dict], claimed: dict[str, tuple]):
    """(folder path, how) or (None, reason) or (None, None) when nothing is on disk.

    claimed maps each Radarr movie's path to (id, title); a movie's own path is not claimed."""
    tmdb = str(movie.get("tmdbId") or "")
    imdb = (movie.get("imdbId") or "").lower()
    claimed = {p: who[1] for p, who in claimed.items() if who[0] != movie.get("id")}

    def free(fs):
        return [f for f in fs if f["path"] not in claimed]

    by_id = [f for f in folders
             if (tmdb and tmdb in f["ids"]["tmdb"]) or (imdb and imdb in f["ids"]["imdb"])]
    if by_id:
        taken = [f for f in by_id if f["path"] in claimed]
        by_id = free(by_id)
        if len(by_id) == 1:
            return by_id[0]["path"], "nfo id"
        if not by_id:
            return None, f"its folder is already {claimed[taken[0]['path']]!r}'s path"
        return None, "ambiguous: " + ", ".join(f["path"] for f in by_id)

    names = {norm(os.path.basename((movie.get("path") or "").rstrip("/")))}
    if movie.get("year"):
        names.add(norm(f"{movie.get('title', '')} ({movie['year']})"))
    names.discard("")

    def other_ids(f):  # the .nfo names a different movie
        t, i = f["ids"]["tmdb"], f["ids"]["imdb"]
        return bool((t and tmdb not in t) or (i and imdb not in i))

    by_name = [f for f in folders if norm(f["name"]) in names and not other_ids(f)]
    if not by_name:
        return None, None
    taken = [f for f in by_name if f["path"] in claimed]
    by_name = free(by_name)
    if len(by_name) == 1:
        return by_name[0]["path"], "name"
    if not by_name:
        return None, f"its folder is already {claimed[taken[0]['path']]!r}'s path"
    return None, "ambiguous: " + ", ".join(f["path"] for f in by_name)


def wait_for(radarr: Radarr, command_id, seconds: int = 120) -> str:
    deadline = time.monotonic() + seconds
    status = "queued"
    while time.monotonic() < deadline:
        status = (radarr.call("GET", f"/api/v3/command/{command_id}") or {}).get("status", "")
        if status in ("completed", "failed", "aborted", "cancelled", "orphaned"):
            return status
        time.sleep(2)
    return status or "unknown"


def run(radarr: Radarr, roots: list[str], apply: bool) -> bool:
    """One pass. True when it worked (matches found or not); False on any error."""
    movies = radarr.call("GET", "/api/v3/movie") or []
    wanted = [m for m in movies if m.get("monitored") and not m.get("hasFile")]
    claimed = {(m.get("path") or "").rstrip("/"): (m.get("id"), m.get("title", "?")) for m in movies}
    folders = scan_library(roots)
    matched = applied = found = skipped = errors = 0
    for m in sorted(wanted, key=lambda x: x.get("title", "")):
        label = f"{m.get('title')} ({m.get('year') or '?'}) [radarr {m.get('id')}]"
        target, how = find_match(m, folders, claimed)
        if target is None:
            if how:
                skipped += 1
                log(f"skip {label}: {how}")
            continue
        matched += 1
        old = (m.get("path") or "").rstrip("/")
        verb = "rescan" if target == old else "repoint"
        if not apply:
            log(f"would {verb} {label} by {how}: {old} -> {target}")
            continue
        try:
            if target != old:
                full = radarr.call("GET", f"/api/v3/movie/{m['id']}")
                full["path"] = target
                radarr.call("PUT", f"/api/v3/movie/{m['id']}?moveFiles=false", full)
                claimed.pop(old, None)
                claimed[target] = (m.get("id"), m.get("title", "?"))
                applied += 1
            cmd = radarr.call("POST", "/api/v3/command", {"name": "RescanMovie", "movieId": m["id"]})
            status = wait_for(radarr, cmd.get("id"))
            has = (radarr.call("GET", f"/api/v3/movie/{m['id']}") or {}).get("hasFile")
            found += 1 if has else 0
            log(f"{'rescanned' if verb == 'rescan' else 'repointed'} {label} by {how}: {old} -> {target}; rescan {status}; "
                f"{'has file' if has else 'still no file'}")
        except HttpError as e:
            errors += 1
            log(f"error on {label}: {e}")
    mode = "apply" if apply else "dry run"
    log(f"{mode}: {len(movies)} movies, {len(wanted)} wanted, {len(folders)} folders on disk; "
        f"{matched} matched, {applied} repointed, {found} now have a file, {skipped} skipped, "
        f"{errors} errors")
    return errors == 0


def set_status(path: str, ok: bool) -> None:
    try:
        if ok:
            with open(path, "w") as fh:
                fh.write(datetime.now().isoformat() + "\n")
        elif os.path.exists(path):
            os.remove(path)
    except OSError:
        pass


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--apply", action="store_true", help="change Radarr (default: dry run)")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--once", action="store_true", help="one pass, then exit (the default)")
    g.add_argument("--every", type=float, metavar="HOURS", help="a pass now, then every HOURS")
    a = p.parse_args(argv)
    apply = a.apply or os.environ.get("RECONCILE_APPLY", "") == "1"
    url = os.environ.get("RADARR_URL", "http://radarr:7878")
    config = os.environ.get("RADARR_CONFIG", "/radarr-config/config.xml")
    roots = [r for r in os.environ.get("RECONCILE_SEARCH", "/movies/Movies").split(",") if r]
    status = os.environ.get("RECONCILE_STATUS", "/tmp/radarr-reconcile.ok")
    if a.every:
        log(f"every {a.every:g} h, {'apply' if apply else 'dry run'}, search {','.join(roots)}")
        time.sleep(float(os.environ.get("RECONCILE_START_MINUTES") or 0) * 60)
    while True:
        try:
            ok = run(Radarr(url, read_credential(config)), roots, apply)
        except (HttpError, SystemExit, OSError, ValueError) as e:
            ok = False
            log(f"run failed: {e}")
        set_status(status, ok)
        if not a.every:
            return 0 if ok else 1
        time.sleep((a.every if ok else min(a.every, 1.0)) * 3600)


if __name__ == "__main__":
    sys.exit(main())
