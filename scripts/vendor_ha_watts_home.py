#!/usr/bin/env python3
"""Vendor one reviewed commit of ha-watts-home into d01/apps/home-assistant/custom_components/.

Run on WS01 to bump the pin, after reading the new commit's custom_components/watts_home in full
(d01/apps/home-assistant/README.md, "Watts Home"). Then review `git diff` and commit.

    python3 -I scripts/vendor_ha_watts_home.py SHA --curl-cffi VERSION

- Downloads https://codeload.github.com/bhamiltoncx/ha-watts-home/tar.gz/SHA and refuses unless
  the archive says it is that commit (GitHub's pax header) and holds only files and folders.
- Replaces custom_components/watts_home with the archive's copy, plus the upstream LICENSE.
- The one local change (recorded in PIN.txt, Apache-2.0 section 4(b)): manifest.json's
  requirements become exactly curl_cffi==VERSION, so Home Assistant installs that release and no
  later one. Refuses if upstream lists any other requirement: review it first.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import io
import json
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

REPO = "https://github.com/bhamiltoncx/ha-watts-home"
TARBALL = "https://codeload.github.com/bhamiltoncx/ha-watts-home/tar.gz/{sha}"
DOMAIN = "watts_home"
DEST = Path(__file__).resolve().parent.parent / "d01/apps/home-assistant/custom_components" / DOMAIN


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sha", help="full 40-character commit SHA, reviewed")
    ap.add_argument("--curl-cffi", required=True, help="curl_cffi release to pin, e.g. 0.16.3")
    args = ap.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.sha):
        sys.exit("[ERROR] give the full 40-character commit SHA")
    if not re.fullmatch(r"\d+(\.\d+)+", args.curl_cffi):
        sys.exit("[ERROR] --curl-cffi takes a release number such as 0.16.3")

    with urllib.request.urlopen(TARBALL.format(sha=args.sha), timeout=60) as resp:
        blob = resp.read()
    digest = hashlib.sha256(blob).hexdigest()
    tar = tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz")
    if tar.pax_headers.get("comment") != args.sha:
        sys.exit(f"[ERROR] archive is not commit {args.sha} (pax comment {tar.pax_headers.get('comment')!r})")

    prefix = f"ha-watts-home-{args.sha}/"
    comp = prefix + f"custom_components/{DOMAIN}/"
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / DOMAIN
        out.mkdir()
        stamp = None
        for m in tar.getmembers():
            if m.name.rstrip("/") == prefix.rstrip("/"):
                stamp = m.mtime
                continue
            if not m.name.startswith(prefix):
                sys.exit(f"[ERROR] unexpected path in archive: {m.name}")
            if m.name == prefix + "LICENSE":
                rel = "LICENSE"
            elif m.name.startswith(comp):
                rel = m.name[len(comp):]
            else:
                continue
            if not (m.isfile() or m.isdir()):
                sys.exit(f"[ERROR] not a plain file or folder: {m.name}")
            if not rel:
                continue
            target = out / rel
            if ".." in Path(rel).parts:
                sys.exit(f"[ERROR] unsafe path: {m.name}")
            if m.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(tar.extractfile(m).read())
        manifest_path = out / "manifest.json"
        if not manifest_path.is_file() or not (out / "LICENSE").is_file():
            sys.exit("[ERROR] archive lacks custom_components/watts_home/manifest.json or LICENSE")
        manifest = json.loads(manifest_path.read_text())
        upstream_reqs = manifest.get("requirements", [])
        if len(upstream_reqs) != 1 or not re.match(r"curl_cffi\b", upstream_reqs[0]):
            sys.exit(f"[ERROR] upstream requirements are {upstream_reqs}, not one curl_cffi entry: review them")
        manifest["requirements"] = [f"curl_cffi=={args.curl_cffi}"]
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

        when = datetime.datetime.fromtimestamp(stamp or 0, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        (out / "PIN.txt").write_text(
            f"Vendored by asyla-hosts scripts/vendor_ha_watts_home.py. Do not edit by hand.\n"
            f"\n"
            f"upstream:  {REPO}\n"
            f"commit:    {args.sha}\n"
            f"date:      {when} (commit time, from the archive)\n"
            f"version:   {manifest.get('version')}\n"
            f"archive:   {TARBALL.format(sha=args.sha)}\n"
            f"sha256:    {digest} (archive as downloaded when vendored)\n"
            f"license:   Apache-2.0 (LICENSE, upstream's)\n"
            f"\n"
            f"Changed from upstream: manifest.json requirements {upstream_reqs} -> {manifest['requirements']}\n"
            f"(pins the one PyPI package Home Assistant installs for this integration).\n"
            f"Every other file is upstream's at the commit above.\n"
        )

        if DEST.exists():
            shutil.rmtree(DEST)
        DEST.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(out, DEST)

    print(f"[INFO] {DOMAIN} {manifest.get('version')} at {args.sha} ({when}) -> {DEST}")
    print(f"[INFO] archive sha256 {digest}; requirements {upstream_reqs} -> {manifest['requirements']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
