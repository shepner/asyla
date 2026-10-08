#!/bin/bash
# ms-procedural backup on d03: pull a consistent copy of ms-procedural's corpus from the Mac Mini
# and keep it in the NAS mirror. Usage: ms-procedural-backup.sh [backup|verify ...]
#
# ms-procedural (theOrg's procedural memory, formerly agent-commons) runs on the Mac Mini, which has
# no off-host path for Docker volumes. d03 pulls instead (theOrg plan ms-procedural-rename.plan.md,
# D8; EA 2026-10-08): GET https://ms-procedural.asyla.org/api/v1/backup with the backup token, which
# opens that route only (read, never write) — no ssh from d03 to the Mini. host-maintenance's nightly
# d03 backup task (03:00) runs `backup` here like every other app.
#
#   1. download to $APP_ROOT/procedural.db.partial, with the sender's counts and quick_check headers;
#   2. integrity_check and row counts on the copy must equal what the sender reported;
#   3. move it over procedural.db, write procedural.meta, then rsync-mirror $APP_ROOT to the NAS
#      (history: nas01 ZFS snapshots of data1/docker, as for every app).
# A failed check leaves the previous copy in place and exits non-zero (the monitor reports it).
#
# Token: MS_PROCEDURAL_BACKUP_TOKEN in this directory's .env (mode 600), delivered from WS01 by
# memory-system ms-procedural/scripts/deliver-backup-token.sh. It reaches curl on stdin, never argv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCREEN_APP="ms-procedural-backup"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
# shellcheck source=/dev/null
. "$HOME/scripts/docker/backup_lib.sh"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/.env"
  set +a
fi
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"

APP_NAME="ms-procedural-backup"
APP_ROOT="$DOCKER_DL/$APP_NAME"
BACKUP_DIR="$DOCKER_D1/ms-procedural/mirror"
SOURCE_URL="${MS_PROCEDURAL_URL:-https://ms-procedural.asyla.org}"

# Prints "ok <situations> <answers>" for a SQLite file, or the failing check.
check_copy() {
  python3 - "$1" <<'PY'
import sqlite3, sys
c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
ic = c.execute("PRAGMA integrity_check").fetchone()[0]
print(ic, *(c.execute(f"SELECT count(*) FROM {t}").fetchone()[0] for t in ("situations", "answers")))
PY
}

header() {  # header <file> <name> → value, case-insensitive
  awk -v n="$(echo "$2" | tr 'A-Z' 'a-z')" -F': ' 'tolower($1)==n {sub(/\r$/, "", $2); print $2}' "$1" | tail -1
}

pull() {
  : "${MS_PROCEDURAL_BACKUP_TOKEN:?MS_PROCEDURAL_BACKUP_TOKEN is not set in $SCRIPT_DIR/.env (deliver-backup-token.sh)}"
  mkdir -p "$APP_ROOT"
  local part="$APP_ROOT/procedural.db.partial" hdr="$APP_ROOT/.headers.$$" t0=$SECONDS
  trap 'rm -f "$part" "$hdr"' RETURN
  # The token goes to curl on stdin (--config -); printf is a builtin, so it is never in argv.
  printf 'header = "Authorization: Bearer %s"\n' "$MS_PROCEDURAL_BACKUP_TOKEN" \
    | curl --config - -fsS --max-time 1800 -D "$hdr" -o "$part" "$SOURCE_URL/api/v1/backup"
  local sent got
  sent="$(header "$hdr" X-Procedural-Check) $(header "$hdr" X-Procedural-Situations) $(header "$hdr" X-Procedural-Answers)"
  got="$(check_copy "$part")"
  if [ "${got%% *}" != ok ] || [ "$got" != "$sent" ]; then
    echo "[ERROR] copy failed its check: got '$got', sender said '$sent'; previous copy kept" >&2
    return 1
  fi
  mv -f "$part" "$APP_ROOT/procedural.db"
  printf 'pulled %s from %s: %s (%s bytes, %ss)\n' "$(date -u +%FT%TZ)" "$SOURCE_URL" "$got" \
    "$(stat -c %s "$APP_ROOT/procedural.db")" "$((SECONDS - t0))" | tee "$APP_ROOT/procedural.meta"
}

do_backup() {
  pull
  do_rsync_mirror_backup "$APP_ROOT" "$BACKUP_DIR"
}

# verify: the token is set, the route answers with it, and the last copy checks out. Downloads nothing.
do_verify() {
  : "${MS_PROCEDURAL_BACKUP_TOKEN:?MS_PROCEDURAL_BACKUP_TOKEN is not set in $SCRIPT_DIR/.env}"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$SOURCE_URL/api/v1/backup")"
  [ "$code" = 401 ] || { echo "[ERROR] backup route without a token answered $code, expected 401" >&2; return 1; }
  echo "[OK] $SOURCE_URL/api/v1/backup refuses no token (401)"
  if [ -f "$APP_ROOT/procedural.db" ]; then
    echo "[OK] last copy: $(check_copy "$APP_ROOT/procedural.db") — $(cat "$APP_ROOT/procedural.meta" 2>/dev/null)"
  else
    echo "[INFO] no copy yet in $APP_ROOT (run backup)"
  fi
}

usage() {
  echo "Usage: $0 [backup|verify ...]" >&2
  echo "  backup  - pull a consistent copy from $SOURCE_URL, check it, rsync-mirror $APP_ROOT to $BACKUP_DIR (screen if interactive)" >&2
  echo "  verify  - token set, route refuses no token, last copy checks out (downloads nothing)" >&2
}

[ $# -eq 0 ] && { usage; exit 1; }
for cmd in "$@"; do
  case "$cmd" in
    backup) run_detached_if_interactive backup do_backup ;;
    _backup) do_backup ;;
    verify) do_verify ;;
    *) usage; exit 1 ;;
  esac
done
