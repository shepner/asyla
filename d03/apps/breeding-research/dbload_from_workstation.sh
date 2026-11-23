#!/bin/bash
# Runs on the workstation, not on d03: loads one BigQuery export (breeding-research repo
# scripts/bq_export.py: an EXPORT_DIR of manifest.json and <table>.jsonl) into d03's
# breeding-research-postgres, as a committed script instead of improvised SSH (README.md, Data load).
# Usage: dbload_from_workstation.sh EXPORT_DIR
# How the bytes move: this host packs manifest.json and the *.jsonl files of EXPORT_DIR as a tar
# (members at the top level; COPYFILE_DISABLE and --no-xattrs: macOS tar adds no ._ AppleDouble
# members and no xattr headers) on its stdout, piped, in memory only, into one
# `ssh -o BatchMode=yes D03_SSH` (default docker@d03) that runs `breeding-research.sh dbmigrate
# dbload`: the pending migrations first (stdin untouched), then pg_load.py --tar - in the app
# container, which prints each table's export-vs-Postgres comparison and exits nonzero on any
# mismatch. Nothing is written to d03's disk but the database; no secret crosses this script (the
# app container has DATABASE_URL already). An app image without those scripts is refused on d03
# before anything runs.
set -euo pipefail

D03_SSH="${D03_SSH:-docker@d03}"
# Expanded by d03's shell, not here.
# shellcheck disable=SC2088
D03_SCRIPT="${D03_SCRIPT:-~/scripts/d03/apps/breeding-research/breeding-research.sh}"
SSH=(ssh -o BatchMode=yes)

if [ $# -ne 1 ]; then
  echo "Usage: $0 EXPORT_DIR   (a bq_export.py output directory: manifest.json and <table>.jsonl)" >&2
  exit 1
fi
dir="$1"
if [ ! -d "$dir" ] || [ ! -f "$dir/manifest.json" ] || [ -L "$dir/manifest.json" ]; then
  echo "[ERROR] $dir is not an export directory (no regular manifest.json in it)" >&2
  exit 1
fi
files=(manifest.json)
shopt -s nullglob
for f in "$dir"/*.jsonl; do
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    echo "[ERROR] $f is not a regular file; not sending it" >&2
    exit 1
  fi
  files+=("${f##*/}")
done
shopt -u nullglob
if [ "${#files[@]}" -lt 2 ]; then
  echo "[ERROR] $dir has no <table>.jsonl next to manifest.json" >&2
  exit 1
fi
if ! [[ "$D03_SSH" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]]; then
  echo "[ERROR] D03_SSH must be [user@]host of A-Z a-z 0-9 . _ @ -" >&2
  exit 1
fi

echo "[INFO] $dir (${#files[@]} files) -> $D03_SSH: breeding-research.sh dbmigrate dbload"
if ! COPYFILE_DISABLE=1 tar --no-xattrs -C "$dir" -cf - "${files[@]}" \
    | "${SSH[@]}" "$D03_SSH" "$D03_SCRIPT dbmigrate dbload"; then
  echo "[ERROR] the load failed or did not match (the lines above say which step and table); fix it and run this again: rows already loaded are skipped" >&2
  exit 1
fi
echo "[INFO] loaded: every table's count and checksums match the export (pg_load.py)"
