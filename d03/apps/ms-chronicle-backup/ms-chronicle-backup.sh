#!/bin/bash
# ms-chronicle backup on d03: pull the newest verified snapshot of ms-chronicle's archive from the
# Mac Mini into the NAS mirror. Usage: ms-chronicle-backup.sh [backup|verify ...]
#
# ms-chronicle (theOrg's episodic memory) runs on the Mac Mini, whose own backup volume is on the
# same disk as the archive. d03 pulls a copy off it nightly (operator, 2026-10-10: "a nightly d03
# pull of the verified backup into /mnt/nas/data1/docker/ms-chronicle/mirror, same mechanism and
# backup-only token class as d03/apps/ms-procedural-backup, writing only inside that directory").
# Written against theOrg memory-system ms-chronicle-mcp/README.md, "Off-host copy: the pull
# contract" (origin/main 705a1d8). host-maintenance's nightly d03 backup task runs `backup` here
# once config/maintenance.toml lists the app.
#
#   1. GET /api/v1/backup          -> $MIRROR/.download.partial, headers -> $MIRROR/.headers.partial
#   2. GET /api/v1/backup/manifest?snapshot=<X-Chronicle-Snapshot> -> $MIRROR/.manifest.partial
#   3. verify-pull.py (the contract's check: sha256, size, counts, every file in the tarball), then
#      chronicle_mirror.py guard (not older than two days, not older or smaller than the held copy)
#   4. rename into place, the manifest last; then prune older pairs by their exact names.
# Any failure removes the three .partial files, leaves every published pair in place and exits
# non-zero (the monitor reports it). Unlike ms-procedural-backup there is no staging directory on
# d03 and no rsync: every file this script creates, renames or deletes is directly inside $MIRROR.
# It does not create $MIRROR: a missing directory (NAS not mounted, or the first run not yet
# approved) is an error, never a write to another disk.
#
# Token: MS_CHRONICLE_BACKUP_TOKEN in this directory's .env (mode 600), delivered from WS01 by
# memory-system ms-chronicle-mcp/scripts/deliver-backup-token.sh. It reaches curl on stdin, never argv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCREEN_APP="ms-chronicle-backup"

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
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"

MIRROR="$DOCKER_D1/ms-chronicle/mirror"
SOURCE_URL="${MS_CHRONICLE_BACKUP_URL:-https://ms-chronicle-backup.asyla.org}"
MIRROR_PY="$SCRIPT_DIR/chronicle_mirror.py"
# .partial files untouched for this long were left by a pull that died (one download is capped at
# 1800 s below, and the check of it reads the tarball twice).
STALE_PARTIAL_S="${MS_CHRONICLE_STALE_PARTIAL_S:-7200}"

err() { echo "[ERROR] $*" >&2; }

# The bearer is never sent in the clear (RFC 6750 section 5.3); loopback is for the tests' stub.
check_settings() {
  if [ -z "${MS_CHRONICLE_BACKUP_TOKEN:-}" ]; then
    err "MS_CHRONICLE_BACKUP_TOKEN is not set in $SCRIPT_DIR/.env (memory-system deliver-backup-token.sh)"
    return 1
  fi
  case "$MS_CHRONICLE_BACKUP_TOKEN" in
    *[!A-Za-z0-9._~+/=-]*) err "MS_CHRONICLE_BACKUP_TOKEN holds a character no bearer token has; deliver it again"; return 1 ;;
  esac
  case "$SOURCE_URL" in
    https://*|http://127.0.0.1:*|http://localhost:*) ;;
    *) err "MS_CHRONICLE_BACKUP_URL must be https (got $SOURCE_URL): the token is not sent in the clear"; return 1 ;;
  esac
}

# fetch <max seconds> <url> <body file> <headers file|""> -> the HTTP status on stdout.
# The token goes to curl on stdin (--config -); printf is a builtin, so it is never in argv.
fetch() {
  local max="$1" url="$2" body="$3" hdr="$4"
  if [ -n "$hdr" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$MS_CHRONICLE_BACKUP_TOKEN" \
      | curl --config - -fsS --connect-timeout 20 --max-time "$max" -w '%{http_code}' -D "$hdr" -o "$body" "$url"
  else
    printf 'header = "Authorization: Bearer %s"\n' "$MS_CHRONICLE_BACKUP_TOKEN" \
      | curl --config - -fsS --connect-timeout 20 --max-time "$max" -w '%{http_code}' -o "$body" "$url"
  fi
}

pull() {
  check_settings || return 1
  if [ ! -d "$MIRROR" ]; then
    err "the mirror directory $MIRROR does not exist (NAS not mounted, or the first run not set up); nothing written"
    return 1
  fi
  local dl="$MIRROR/.download.partial" hdr="$MIRROR/.headers.partial" man="$MIRROR/.manifest.partial"
  local t0=$SECONDS code name checked state
  # Not cleaned up on failure: fresh .partial files belong to the pull that is running.
  python3 "$MIRROR_PY" claim "$MIRROR" "$STALE_PARTIAL_S" || { err "pull not started; the mirror is as it was"; return 1; }

  # Explicit cleanup on each failure, no `trap ... RETURN`: that trap is global in bash and fires
  # again on later function returns (ms-procedural-backup.sh, 2026-10-08).
  if ! code="$(fetch 1800 "$SOURCE_URL/api/v1/backup" "$dl" "$hdr")"; then
    rm -f "$dl" "$hdr" "$man"
    err "download from $SOURCE_URL/api/v1/backup failed (HTTP ${code:-none}); the copies in the mirror are kept"
    return 1
  fi
  if ! name="$(python3 "$MIRROR_PY" name "$hdr")"; then
    rm -f "$dl" "$hdr" "$man"
    err "the download carried no usable snapshot name; the copies in the mirror are kept"
    return 1
  fi
  # Asked for by the name the tarball carried: a newer snapshot may be published between the two.
  if ! code="$(fetch 300 "$SOURCE_URL/api/v1/backup/manifest?snapshot=$name" "$man" "")"; then
    rm -f "$dl" "$hdr" "$man"
    err "manifest of $name from $SOURCE_URL failed (HTTP ${code:-none}); the copies in the mirror are kept"
    return 1
  fi
  if ! checked="$(python3 "$SCRIPT_DIR/verify-pull.py" "$dl" "$man" "$hdr")" \
      || ! state="$(python3 "$MIRROR_PY" guard "$man" "$hdr" "$MIRROR")"; then
    rm -f "$dl" "$hdr" "$man"
    err "$name failed its check; the copies in the mirror are kept"
    return 1
  fi
  # The manifest last: a tarball with its manifest beside it is a verified copy.
  mv -f "$dl" "$MIRROR/$name.tar.gz"
  mv -f "$man" "$MIRROR/$name.manifest.json"
  rm -f "$hdr"
  python3 "$MIRROR_PY" prune "$MIRROR" "$name"
  printf 'pulled %s from %s: %s (%s, %ss)\n' "$(date -u +%FT%TZ)" "$SOURCE_URL" "$checked" "${state%% *}" "$((SECONDS - t0))"
}

do_backup() {
  pull
}

# verify: the token is set, the route refuses no token and takes this one, the mirror is there and
# its newest pair is what its manifest recorded. Downloads no tarball and writes nothing.
do_verify() {
  check_settings || return 1
  local code rc=0 held
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$SOURCE_URL/api/v1/backup" || true)"
  if [ "$code" = 401 ]; then
    echo "[OK] $SOURCE_URL/api/v1/backup refuses no token (401)"
  else
    err "backup route without a token answered $code, expected 401"
    rc=1
  fi
  if code="$(fetch 60 "$SOURCE_URL/api/v1/backup/manifest" /dev/null "" 2>/dev/null)"; then
    echo "[OK] the route takes this token (manifest of the newest snapshot: $code)"
  elif [ "$code" = 404 ]; then
    echo "[WARN] the route takes this token, but the Mini has published no snapshot yet (404)"
  else
    err "the manifest request with this token answered ${code:-nothing} (401: not the backup token; 503: the route is off on the Mini)"
    rc=1
  fi
  if [ ! -d "$MIRROR" ]; then
    err "the mirror directory $MIRROR does not exist (NAS not mounted, or the first run not set up)"
    return 1
  fi
  if held="$(python3 "$MIRROR_PY" held "$MIRROR")"; then
    if [ "$held" = none ]; then
      echo "[INFO] no copy yet in $MIRROR (run backup)"
    else
      echo "[OK] newest copy: $held"
    fi
  else
    err "the newest copy in $MIRROR does not check out"
    rc=1
  fi
  return "$rc"
}

usage() {
  echo "Usage: $0 [backup|verify ...]" >&2
  echo "  backup  - pull the newest published snapshot from $SOURCE_URL into $MIRROR, checked before it is renamed into place (screen if interactive)" >&2
  echo "  verify  - token set, route refuses no token and takes this one, newest copy equals its manifest (downloads no tarball)" >&2
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
