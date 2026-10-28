#!/bin/bash
# tc-datalogger on d03. Usage: tc-datalogger.sh [up|down|restart|verify|pull|backup|restore|logs|...]
# The store is Doltgres (tc-doltgres, database torn_data; tc-datalogger docs/d03-cutover.md).
# up, restart and refresh pass TC_API_KEY_FFSCOUTER (build_host.py start_env, over SSH stdin; in no
# file) to tc-user-events-pipeline for the Event Targets step; without it they warn and start anyway.
# targets-config show|on NAME|off reads or switches that step in TC_user_events' config.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="tc-datalogger"

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
APP_NAME="tc-datalogger"
APP_ROOT="$DOCKER_DL/$APP_NAME"
BACKUP_DIR="$DOCKER_D1/$APP_NAME/mirror"
# DOCKER_UID/DOCKER_GID (common.env): tc-log-rotate runs as the owner of the cron.log files.
export DOCKER_DL DOCKER_D1 TC_REGISTRY TC_IMAGE_TAG DASHBOARD_SECRET_KEY DASHBOARD_MODE LOCAL_TZ DOCKER_UID DOCKER_GID

# Doltgres. The password is a file next to this script (host.toml [[secret]]
# D03_TC_DATALOGGER_DB_PASSWORD; *secret* is gitignored, so update_scripts.sh keeps it), mounted
# into every container as /run/secrets/tc_db_password. Never on argv, never printed.
DB_SERVICE="tc-doltgres"
DB_NAME="torn_data"
DB_PASSWORD_FILE="$SCRIPT_DIR/tc_db_password.secret"
DB_NETWORK="tc_datalogger_net"
# Full-history Dolt backup (dolt_backup sync-url) at $APP_ROOT/doltgres-backup, which the NAS
# mirror carries; the live data dir ($APP_ROOT/doltgres) is never rsynced (not consistent while
# the server runs, and its files are root's, mode 600).
DB_BACKUP_URL="file:///backups/$DB_NAME"
DB_RESTORE_CHECK="${DB_NAME}_restore_check"
PIPELINES=(tc-faction-crimes tc-faction-members tc-items tc-user-events tc-faction-chains)
# A tc-datalogger checkout for backfill and parity (`src` puts one here).
TC_SRC="${TC_SRC:-$APP_ROOT/src}"
# The config targets-config edits (mounted read-only into tc-user-events-pipeline; it holds the
# Torn key in api_keys). TC_TARGETS_CONFIG overrides it, for tests.
TARGETS_CONFIG="${TC_TARGETS_CONFIG:-$APP_ROOT/TC_user_events/config/TC_API_config.json}"

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

# Every step below checks its own exit code: run_cmd runs under `||`, where bash ignores set -e.

# db_sql <database> <sql>: one statement through psql inside the Doltgres container (Doltgres
# has no CLI; the image has psql), tuples only. Dolt procedures are called with SELECT, never CALL.
db_sql() {
  docker exec "$DB_SERVICE" sh -c \
    'PGPASSWORD="$(cat /run/secrets/tc_db_password)" exec psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -d "$1" -tAc "$2"' \
    sh "$1" "$2"
}

db_wait_healthy() {
  local i state
  for i in $(seq 1 60); do
    state=$(docker inspect -f '{{.State.Health.Status}}' "$DB_SERVICE" 2>/dev/null || echo missing)
    [ "$state" = healthy ] && return 0
    sleep 2
  done
  echo "[ERROR] $DB_SERVICE is not healthy (state: $state)" >&2
  return 1
}

do_dbup() {
  [ -s "$DB_PASSWORD_FILE" ] || {
    echo "[ERROR] No password at $DB_PASSWORD_FILE (build_host.py d03 secrets install --apply D03_TC_DATALOGGER_DB_PASSWORD)" >&2
    return 1
  }
  mkdir -p "$APP_ROOT/doltgres" "$APP_ROOT/doltgres-backup" || return 1
  run_compose up -d "$DB_SERVICE" || return 1
  db_wait_healthy || return 1
  echo "[INFO] $DB_SERVICE healthy"
}

# Dolt GC. Measured on a 1.3.3 lab (tc-datalogger docs/d03-cutover.md, "GC while the pipelines
# write"): 39 GCs during 26,003 loads by five DoltgresLoader writers, no error, no lost row, and an
# idle connection survived each one, so by default it runs live. TC_GC_STOP_PIPELINES=1 (.env)
# stops the five pipelines around it instead (a load in flight is rolled back; the next run redoes it).
do_gc() {
  local before after rc=0 running stopped=()
  db_wait_healthy || return 1
  if [ "${TC_GC_STOP_PIPELINES:-0}" = 1 ]; then
    # Checked on its own: inside the process substitution a failed `compose ps` would leave the
    # list empty and the GC would run live without a word (found on the lab).
    running=$(run_compose ps --status running --services) || {
      echo "[ERROR] compose ps failed; GC not run" >&2; return 1; }
    mapfile -t stopped < <(printf '%s\n' "$running" | grep -Fx -f <(printf '%s\n' "${PIPELINES[@]}") || true)
    if [ ${#stopped[@]} -gt 0 ]; then
      echo "[INFO] Stopping ${stopped[*]} for GC"
      run_compose stop -t 60 "${stopped[@]}" || rc=1
    fi
  fi
  before=$(docker exec "$DB_SERVICE" du -sk /var/lib/doltgres | cut -f1)
  if [ "$rc" = 0 ] && db_sql "$DB_NAME" "SELECT dolt_gc()" >/dev/null; then
    after=$(docker exec "$DB_SERVICE" du -sk /var/lib/doltgres | cut -f1)
    echo "[INFO] dolt_gc: data ${before} KiB -> ${after} KiB"
  else
    rc=1
  fi
  if [ ${#stopped[@]} -gt 0 ]; then
    run_compose start "${stopped[@]}" || { echo "[ERROR] could not start ${stopped[*]} again" >&2; rc=1; }
  fi
  return "$rc"
}

# Sync the full-history backup, then prove it: restore it to a scratch database, require its head
# to be a commit on main with the same history length, drop it and purge it (Doltgres keeps a
# dropped database in .dolt_dropped_databases until dolt_purge_dropped_databases()). The pattern of
# theOrg's ms-continuity maintenance.py; pipelines may commit meanwhile, so the check is "a commit
# on main", not "main's head".
do_db_backup() {
  local head="" commits="" on_main="" want="" rc=0
  db_wait_healthy || return 1
  db_sql "$DB_NAME" "SELECT dolt_backup('sync-url', '$DB_BACKUP_URL')" >/dev/null || {
    echo "[ERROR] dolt_backup sync-url failed" >&2; return 1; }
  db_sql postgres "DROP DATABASE IF EXISTS $DB_RESTORE_CHECK" >/dev/null || return 1
  if db_sql postgres "SELECT dolt_backup('restore', '$DB_BACKUP_URL', '$DB_RESTORE_CHECK')" >/dev/null; then
    head=$(db_sql "$DB_RESTORE_CHECK" "SELECT hashof('main')") || rc=1
    commits=$(db_sql "$DB_RESTORE_CHECK" "SELECT count(*) FROM dolt_log") || rc=1
  else
    echo "[ERROR] the backup does not restore" >&2; rc=1
  fi
  db_sql postgres "DROP DATABASE IF EXISTS $DB_RESTORE_CHECK" >/dev/null || rc=1
  db_sql postgres "SELECT dolt_purge_dropped_databases()" >/dev/null || rc=1
  [ "$rc" = 0 ] || return 1
  [[ "$head" =~ ^[0-9a-v]{32}$ ]] || { echo "[ERROR] restored head is not a commit hash: $head" >&2; return 1; }
  on_main=$(db_sql "$DB_NAME" "SELECT count(*) FROM dolt_log WHERE commit_hash = '$head'") || return 1
  want=$(db_sql "$DB_NAME" "SELECT count(*) FROM dolt_log('$head')") || return 1
  if [ "$on_main" != 1 ] || [ "$commits" != "$want" ]; then
    echo "[ERROR] backup restored to $head with $commits commits; on main: $on_main, main has $want up to it" >&2
    return 1
  fi
  # The server writes the backup as root, mode 600; the mirror's rsync runs as this user.
  docker exec "$DB_SERVICE" chown -R "$(id -u):$(id -g)" /backups || return 1
  echo "[INFO] Dolt backup verified: head $head, $commits commits ($APP_ROOT/doltgres-backup)"
}

do_backup() {
  # repo/ is in the mirror too: the dashboard mounts it, and the audit of 2026-10-12 found it
  # in no backup (gap G3), so a rebuilt host would start without it.
  # doltgres/ (the live data dir) never is: doltgres-backup/ is its consistent copy. When the Dolt
  # backup fails, the mirror keeps the last verified copy (excluded paths are not deleted).
  local rc=0 db_ok=1
  do_db_backup || { db_ok=0; rc=1; echo "[ERROR] Dolt backup failed; the mirror keeps the last verified one" >&2; }
  if [ "$db_ok" = 1 ] && [ "${TC_GC:-1}" = 1 ]; then
    do_gc || { rc=1; echo "[ERROR] dolt_gc failed" >&2; }
  fi
  local excl=(--exclude=/doltgres/ --exclude=/src/ --exclude=/src.bundle)
  [ "$db_ok" = 1 ] || excl+=(--exclude=/doltgres-backup/)
  do_rsync_mirror_backup "$APP_ROOT" "$BACKUP_DIR" -- "${excl[@]}" || rc=$?
  return "$rc"
}

# Rebuilt host only: the mirror, then torn_data from its Dolt backup into a fresh server (whose
# password is the provisioned one: the image takes it only when it initialises an empty data dir).
do_restore() {
  do_rsync_mirror_restore "$BACKUP_DIR" "$APP_ROOT" || return 1
  if [ ! -d "$APP_ROOT/doltgres-backup/$DB_NAME" ]; then
    echo "[WARN] No Dolt backup in $APP_ROOT/doltgres-backup; tc-doltgres starts empty" >&2
    return 0
  fi
  do_dbup || return 1
  db_sql postgres "SELECT dolt_backup('restore', '$DB_BACKUP_URL', '$DB_NAME')" >/dev/null || {
    echo "[ERROR] restore of $DB_NAME from $APP_ROOT/doltgres-backup failed" >&2; return 1; }
  echo "[INFO] $DB_NAME restored: head $(db_sql "$DB_NAME" "SELECT hashof('main')"), $(db_sql "$DB_NAME" "SELECT count(*) FROM dolt_log") commits"
}

# src <rev>: a tc-datalogger checkout at <rev> in $TC_SRC, from a git bundle on stdin (d03 has no
# login to the personal repo): git -C <checkout> bundle create - main | ssh d03 '<this> src <rev>'
do_src() {
  local rev="${1:?src needs a revision}"
  local bundle="$APP_ROOT/src.bundle"
  cat > "$bundle.tmp" && mv "$bundle.tmp" "$bundle" || return 1
  # No `git bundle verify`: it needs a repository to run in (found on the lab); the clone checks
  # the bundle instead.
  rm -rf "$TC_SRC" && git clone -q --no-checkout "$bundle" "$TC_SRC" && git -C "$TC_SRC" checkout -q --detach "$rev" || return 1
  echo "[INFO] $TC_SRC at $(git -C "$TC_SRC" rev-parse HEAD)"
}

# backfill|parity [args]: tc-datalogger's scripts/backfill_from_bigquery.sh or sql_parity.sh from
# $TC_SRC against tc-doltgres on the stack network. BigQuery is read-only to both; the GCP key is
# the one the BigQuery-era compose mounted (kept on d03 for the fallback).
run_tc_script() {
  local script="$1"; shift
  [ -x "$TC_SRC/scripts/$script" ] || { echo "[ERROR] No $TC_SRC/scripts/$script (run src first)" >&2; return 1; }
  db_wait_healthy || return 1
  DOCKER_NETWORK="$DB_NETWORK" TC_DB_HOST="$DB_SERVICE" TC_DB_PORT=5432 TC_DB_NAME="$DB_NAME" \
    TC_DB_PASSWORD_FILE="$DB_PASSWORD_FILE" \
    GCP_CREDENTIALS="${GCP_CREDENTIALS:-$APP_ROOT/TC_faction_crimes/config/credentials.json}" \
    "$TC_SRC/scripts/$script" "$@" 2>&1 | sed -E 's/key=[^&" ]+/key=REDACTED/g'
}

do_verify() {
  curl -sf -o /dev/null http://127.0.0.1:8081/login || {
    echo "[ERROR] Local dashboard :8081 failed" >&2
    return 1
  }
  echo "[INFO] Local http://127.0.0.1:8081/login OK"
  if curl -sfk -o /dev/null --max-time 25 https://tc-datalogger.asyla.org/login; then
    echo "[INFO] https://tc-datalogger.asyla.org/login OK"
  else
    echo "[ERROR] Public URL failed" >&2
    return 1
  fi
  db_wait_healthy || return 1
  echo "[INFO] $DB_SERVICE: $DB_NAME head $(db_sql "$DB_NAME" "SELECT hashof('main')"), $(db_sql "$DB_NAME" "SELECT count(*) FROM dolt_log") commits"
}

# A warning, not a refusal: the key is optional, and update_all.sh's refresh fallback must still
# start the stack. Without it the Event Targets step runs and skips FFScouter.
warn_ffscouter() {
  if [ -z "${TC_API_KEY_FFSCOUTER:-}" ]; then
    echo "[WARN] $1 without TC_API_KEY_FFSCOUTER: Event Targets runs without FFScouter estimates. With the key:" >&2
    echo "       cd ~/local/asyla && python3 core/tools/credentials.py exec TC_API_KEY_FFSCOUTER -- python3 projects/asyla-hosts/scripts/build_host.py d03 build --only apps --app tc-datalogger --apply" >&2
  fi
}

# targets-config show|on NAME|off: the "targets" block of $TARGETS_CONFIG. show prints the api_keys
# names and the block; on NAME sets the block (NAME must be an api_keys name); off sets enabled to
# false. Values are never printed: a block field that names a key is shown only when it is a known
# name. A write goes through the existing file (same inode, owner and mode) and only when the
# content changes; no backup copy is made, as the file holds the Torn key. The pipeline reads the
# file when it starts, so recreate the stack (build_host.py, warn_ffscouter) to apply a change.
do_targets_config() {
  local action="${1:-}"
  case "$action" in
    show) [ $# -eq 1 ] || { echo "[ERROR] targets-config show takes no argument" >&2; return 1; } ;;
    off) [ $# -eq 1 ] || { echo "[ERROR] targets-config off takes no argument" >&2; return 1; } ;;
    on) [ $# -eq 2 ] && [ -n "$2" ] || { echo "[ERROR] targets-config on needs one api_keys NAME (targets-config show lists them)" >&2; return 1; } ;;
    *) echo "[ERROR] targets-config show|on NAME|off" >&2; return 1 ;;
  esac
  [ -f "$TARGETS_CONFIG" ] || { echo "[ERROR] No config at $TARGETS_CONFIG" >&2; return 1; }
  python3 - "$TARGETS_CONFIG" "$@" <<'PY'
import json, os, re, sys

path, action, args = sys.argv[1], sys.argv[2], sys.argv[3:]
FFSCOUTER = "ffscouter"   # targets.ffscouter_api_key: the step reads env TC_API_KEY_FFSCOUTER
ON = {"enabled": True, "api_key": None, "ffscouter_api_key": FFSCOUTER, "frequency": "PT1H"}


def fail(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(1)


try:
    with open(path, encoding="utf-8") as f:
        text = f.read()
    cfg = json.loads(text)
except (OSError, ValueError) as e:   # neither message quotes the file's content
    fail(f"cannot read {path} as JSON: {type(e).__name__}")
if not isinstance(cfg, dict):
    fail(f"{path}: not a JSON object")
keys = cfg.get("api_keys")
names = sorted(keys) if isinstance(keys, dict) else []


def shown(block):
    """The block with every field that could hold a value reduced to what is safe to print."""
    if not isinstance(block, dict):
        return f"<not an object: {type(block).__name__}>"
    out = {}
    for k, v in block.items():
        if k == "enabled" and isinstance(v, bool):
            out[k] = v
        elif k == "frequency" and isinstance(v, str) and re.fullmatch(r"P[0-9A-Z]{1,15}", v):
            out[k] = v
        elif k in ("api_key", "ffscouter_api_key") and isinstance(v, str) and (v in names or v == FFSCOUTER):
            out[k] = v
        else:
            out[k] = f"<{type(v).__name__}, not shown>"
    return out


def report(block, verb):
    print(f"api_keys names: {names}")
    print(f"targets ({verb}): " + ("absent (the step is off)" if block is None else json.dumps(shown(block))))


block = cfg.get("targets")
if action == "show":
    report(block, "current")
    sys.exit(0)
if action == "on":
    # The name is checked, never echoed: a key pasted by mistake must not reach the output.
    if args[0] not in names:
        fail(f"that NAME is not an api_keys name in {path}; names: {names}")
    new = dict(block) if isinstance(block, dict) else {}
    new.update(ON, api_key=args[0])
elif action == "off":
    if block is None:
        report(block, "unchanged")
        sys.exit(0)
    if not isinstance(block, dict):
        fail(f"{path}: targets is not an object; not changed")
    new = dict(block, enabled=False)
if new == block:   # already so: no write, so the file's own formatting stays as it is
    report(new, "unchanged")
    sys.exit(0)
cfg["targets"] = new

# Keep the file's indent (its first indented line; 2 if none) and its final newline.
m = re.search(r"^([ \t]+)\S", text, re.M)
indent = (m.group(1) if m and "\t" in m.group(1) else len(m.group(1))) if m else 2
out = json.dumps(cfg, indent=indent, ensure_ascii=False) + ("\n" if text.endswith("\n") else "")
if out == text:
    report(new, "unchanged")
    sys.exit(0)
# In place: r+ keeps the inode, owner and mode; one write, then truncate and fsync.
with open(path, "r+", encoding="utf-8") as f:
    f.write(out)
    f.truncate()
    f.flush()
    os.fsync(f.fileno())
report(new, "written")
PY
}

run_cmd() {
  case "$1" in
    pull) run_compose pull ;;
    up) [ -s "$DB_PASSWORD_FILE" ] || { echo "[ERROR] No password at $DB_PASSWORD_FILE" >&2; return 1; }
        mkdir -p "$APP_ROOT/doltgres" "$APP_ROOT/doltgres-backup" || return 1
        warn_ffscouter up
        run_compose pull; run_compose up -d ;;
    down) run_compose down ;;
    restart) warn_ffscouter restart; run_compose down; run_compose up -d ;;
    refresh) warn_ffscouter refresh; run_compose pull; run_compose up -d ;;
    # Pull only, like the other d03 apps; use up or restart to apply the new image.
    update) echo "[INFO] Pulling latest images (not starting app; use up or restart to start)"; run_compose pull ;;
    verify) do_verify ;;
    # tc-doltgres alone (the cutover's backfill and parity run before the pipelines move to it).
    dbup) do_dbup ;;
    gc) do_gc ;;
    dbbackup) do_db_backup ;;
    # Nightly from host-maintenance (TASK=backup HOSTS=d03): Dolt backup + check, GC, NAS mirror.
    backup) run_detached_if_interactive backup do_backup ;;
    _backup) do_backup ;;
    # Rebuilt host only: refuses unless APP_ROOT is empty and the mirror's last backup is OK.
    restore) do_restore ;;
    logs) run_compose logs -f ;;
    *) return 1 ;;
  esac
}

if [ $# -eq 0 ]; then
  echo "Usage: $0 pull|up|down|restart|refresh|update|verify|dbup|gc|dbbackup|backup|restore|logs" >&2
  echo "       $0 src <rev> < bundle | backfill [backfill_from_bigquery.sh args] | parity [sql_parity.sh args]" >&2
  echo "       $0 targets-config show | on NAME | off   (Event Targets in TC_user_events' config; NAME: an api_keys name)" >&2
  exit 1
fi
[ "$1" = "logs" ] && { run_compose logs -f "${@:2}"; exit 0; }
# These take arguments, so they are not in the command loop; each exits with its own code.
case "$1" in
  targets-config) do_targets_config "${@:2}"; exit $? ;;
  src) do_src "${@:2}"; exit $? ;;
  backfill) run_tc_script backfill_from_bigquery.sh "${@:2}"; exit $? ;;
  parity) run_tc_script sql_parity.sh "${@:2}"; exit $? ;;
esac
for c in "$@"; do run_cmd "$c" || { echo "Unknown: $c" >&2; exit 1; }; done
