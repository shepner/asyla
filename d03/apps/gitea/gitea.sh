#!/bin/bash
# Gitea on d03. Usage: gitea.sh [switch ...] e.g. backup|update|refresh|up|down|restart|logs
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env.
# Data under /mnt/docker/Gitea; backup mirrors it to /mnt/nas/data1/docker/Gitea/mirror (Gitea briefly stopped).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="gitea"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
# shellcheck source=/dev/null
. "$HOME/scripts/docker/backup_lib.sh"
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"

APP_NAME="Gitea"
APP_ROOT="$DOCKER_DL/Gitea"
BACKUP_DIR="$DOCKER_D1/Gitea/mirror"

export DOCKER_DL
export DOCKER_D1
export LOCAL_TZ

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

# Not backed up:
# - data/ssh/: host keys for Gitea's built-in sshd, root:root 0600 (unreadable here). Nothing
#   reaches that sshd (only :3000 is published; clients use HTTPS), and the container
#   regenerates missing keys at start.
# - gitea.db-journal: exists only mid-transaction. Next to a good gitea.db, SQLite would treat
#   it as a hot journal and roll it into the DB on open.
BACKUP_EXCLUDES=(--exclude=/data/ssh/ --exclude=/data/gitea/gitea.db-journal)
# Longest wait for running Gitea Actions jobs before stopping Gitea. theOrg's nightly
# deploy-all (01:00 CDT) polls Gitea for up to ~80 min; it must not lose Gitea mid-run.
BACKUP_QUIET_WAIT_MIN="${BACKUP_QUIET_WAIT_MIN:-60}"

gitea_sql() {
  docker exec -u git gitea sqlite3 /data/gitea/gitea.db "$1"
}

# Returns 0 once no Gitea Actions task is running (action_task.status 6), 1 on timeout.
wait_actions_idle() {
  local deadline n
  deadline=$(( $(date +%s) + BACKUP_QUIET_WAIT_MIN * 60 ))
  while :; do
    n=$(gitea_sql "select count(*) from action_task where status = 6;") || return 1
    [ "$n" = "0" ] && return 0
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "[WARN] $n Gitea Actions job(s) still running after ${BACKUP_QUIET_WAIT_MIN} min" >&2
      return 1
    fi
    echo "[INFO] Waiting for $n running Gitea Actions job(s) before stopping Gitea"
    sleep 30
  done
}

check_mirror_db() {
  python3 - "$BACKUP_DIR/data/gitea/gitea.db" <<'PY'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro&immutable=1", uri=True)
res = db.execute("PRAGMA integrity_check").fetchone()[0]
repos = db.execute("select count(*) from repository").fetchone()[0]
print(f"[INFO] Backed-up gitea.db integrity_check: {res}; {repos} repositories")
sys.exit(0 if res == "ok" else 1)
PY
}

start_gitea() {
  run_compose start
  local i
  for i in $(seq 1 24); do
    curl -sf -o /dev/null --max-time 5 http://127.0.0.1:3000/ && { echo "[INFO] Gitea is back up"; return 0; }
    sleep 5
  done
  echo "[ERROR] Gitea not answering on :3000 two minutes after start" >&2
  return 1
}

# Gitea's docs say to stop it for a consistent backup. Pass 1 mirrors while it runs; pass 2
# copies only what changed since, with Gitea stopped, so it is down for seconds, not the
# whole copy. Every step checks its exit code: the dispatcher calls this under `if !`, where
# set -e does not apply.
do_backup() {
  local rc=0 t0
  rm -f "$APP_ROOT/data/gitea/gitea.db.snapshot"
  echo "[INFO] Pass 1 of 2: mirror while Gitea runs"
  do_rsync_mirror_backup "$APP_ROOT" "$BACKUP_DIR" -- "${BACKUP_EXCLUDES[@]}" || return
  if [ "$(docker inspect -f '{{.State.Running}}' gitea 2>/dev/null)" != "true" ]; then
    echo "[INFO] Gitea is not running, so pass 1 is already consistent"
  elif wait_actions_idle; then
    trap 'start_gitea' EXIT          # never leave Gitea stopped
    trap 'exit 143' TERM INT HUP     # turn signals into exit so the EXIT trap runs
    echo "[INFO] Pass 2 of 2: stopping Gitea"
    t0=$SECONDS
    run_compose stop || rc=$?
    [ "$rc" -eq 0 ] && { do_rsync_mirror_backup "$APP_ROOT" "$BACKUP_DIR" -- "${BACKUP_EXCLUDES[@]}" || rc=$?; }
    trap - EXIT TERM INT HUP
    start_gitea || { [ "$rc" -eq 0 ] && rc=1; }
    echo "[INFO] Gitea was stopped for $((SECONDS - t0))s"
    [ "$rc" -eq 0 ] || return "$rc"
  else
    # Busy: leave Gitea up. The DB comes from an online snapshot so it is still consistent,
    # but the repos were copied live, so report a failure for the digest to show.
    echo "[WARN] Not stopping Gitea; backing up an online DB snapshot instead" >&2
    gitea_sql ".backup /data/gitea/gitea.db.snapshot" || return
    rsync -a "$APP_ROOT/data/gitea/gitea.db.snapshot" "$BACKUP_DIR/data/gitea/gitea.db" || return
    rm -f "$APP_ROOT/data/gitea/gitea.db.snapshot"
    check_mirror_db || return
    return 3
  fi
  check_mirror_db
}

do_update() {
  echo "[INFO] Pulling latest images (not starting app; use up or restart to start)"
  run_compose pull
}

do_verify() {
  echo "[INFO] Health check https://gitea.asyla.org/ (via proxy) and local :3000"
  if curl -sf -o /dev/null -w "%{http_code}" --max-time 15 http://127.0.0.1:3000/ | grep -qE '^(200|302)$'; then
    echo "[INFO] Local :3000 OK"
  else
    echo "[WARN] Local :3000 check failed (container may still be starting)" >&2
  fi
  if curl -sfk -o /dev/null -w "%{http_code}" --max-time 20 https://gitea.asyla.org/ | grep -qE '^(200|302)$'; then
    echo "[INFO] https://gitea.asyla.org OK"
  else
    echo "[ERROR] https://gitea.asyla.org check failed" >&2
    return 1
  fi
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)
      run_detached_if_interactive backup do_backup
      ;;
    _backup)
      do_backup
      ;;
    update)
      run_detached_if_interactive update do_update
      ;;
    _update)
      do_update
      ;;
    refresh)
      echo "[INFO] Pulling latest images and starting"
      run_compose pull
      run_compose up -d
      ;;
    up)
      run_compose up -d
      ;;
    down)
      run_compose down
      ;;
    restart)
      run_compose down
      run_compose up -d
      ;;
    verify)
      do_verify
      ;;
    logs)
      run_compose logs -f
      ;;
    *)
      return 1
      ;;
  esac
}

if [ $# -eq 0 ]; then
  echo "Usage: $0 [switch ...]" >&2
  echo "  Switches can be combined, e.g. down backup up" >&2
  echo "" >&2
  echo "  backup   - rsync mirror of $APP_ROOT to $BACKUP_DIR; history: nas01 ZFS snapshots (screen if interactive)" >&2
  echo "  update   - Pull latest images (screen if interactive); use up/restart to start" >&2
  echo "  refresh  - Pull latest images + start (inline)" >&2
  echo "  up       - Start containers only" >&2
  echo "  down     - Stop and remove containers" >&2
  echo "  restart  - Down then up" >&2
  echo "  verify   - curl local :3000 and https://gitea.asyla.org" >&2
  echo "  logs     - Follow logs (optionally for one service)" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "Usage: $0 backup|update|refresh|up|down|restart|verify|logs [ ... ]" >&2
    exit 1
  fi
done
