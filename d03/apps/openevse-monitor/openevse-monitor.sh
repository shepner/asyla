#!/bin/bash
# openevse-monitor on d03 (README.md). Usage: openevse-monitor.sh [up|down|restart|refresh|pull|update|verify|status|stage|unstage|backup|restore|logs]
# up, restart and refresh need OPENEVSE_WWW_USER and OPENEVSE_WWW_PASSWORD in the environment
# (build_host.py start_env sends them over SSH stdin); the login is in no file. stage [MINUTES] [NOTE]:
# one urgent test problem in status.json until it expires (default 75 minutes, so an hourly monitor
# run sees it); unstage ends it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
# shellcheck source=/dev/null
. "$HOME/scripts/docker/backup_lib.sh"

DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"
APP_NAME="openevse-monitor"
OPENEVSE_ROOT="$DOCKER_DL/$APP_NAME"
BACKUP_DIR="$DOCKER_D1/$APP_NAME/mirror"
OPENEVSE_UID="$(id -u)"
OPENEVSE_GID="$(id -g)"
export OPENEVSE_ROOT OPENEVSE_UID OPENEVSE_GID

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

need_login() {
  if [ -z "${OPENEVSE_WWW_USER:-}" ] || [ -z "${OPENEVSE_WWW_PASSWORD:-}" ]; then
    echo "[ERROR] $1 needs OPENEVSE_WWW_USER and OPENEVSE_WWW_PASSWORD in the environment: from the workstation," >&2
    echo "        credentials.py exec OPENEVSE_WWW_USER OPENEVSE_WWW_PASSWORD -- build_host.py d03 build --only apps --app openevse-monitor --apply" >&2
    exit 1
  fi
}

do_up() {
  need_login up
  mkdir -p "$OPENEVSE_ROOT"
  run_compose pull
  run_compose up -d
}

# Running, healthy or starting, and status.json written in the last 15 minutes.
do_verify() {
  local state
  state="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$APP_NAME" 2>/dev/null || true)"
  case "$state" in
    "running healthy"|"running starting") echo "[INFO] container $APP_NAME: $state" ;;
    *) echo "[ERROR] container $APP_NAME: ${state:-absent}" >&2; return 1 ;;
  esac
  python3 - "$OPENEVSE_ROOT/status.json" <<'EOF'
import datetime as dt, json, sys
try:
    s = json.load(open(sys.argv[1]))
except (OSError, ValueError) as e:
    sys.exit(f"[ERROR] {sys.argv[1]}: {type(e).__name__}")
age = dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(s["time"].replace("Z", "+00:00"))
c = s["charger"]
urgent = sum(p["severity"] == "urgent" for p in s["problems"])
print(f"[INFO] status.json {s['time']} ({int(age.total_seconds())} s old): charger reachable={c['reachable']}, "
      f"{urgent} urgent, {len(s['problems']) - urgent} warn"
      + (f"; state {c.get('state')} ({c.get('state_name')}), RSSI {c.get('rssi_dbm')} dBm, poll {c.get('poll_seconds')} s"
         if c["reachable"] else ""))
if age > dt.timedelta(minutes=15):
    sys.exit("[ERROR] status.json is older than 15 minutes")
EOF
}

do_status() {
  python3 - "$OPENEVSE_ROOT/status.json" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
c = s["charger"]
print(s["time"], f"charger state {c.get('state')} ({c.get('state_name')})" if s["ok"] else "charger not answering")
for p in s["problems"]:
    print(f"  [{p['severity']}] {p['message']}")
for e in c.get("events", []):
    print(f"  event {e['at']}: {e['message']}")
EOF
}

do_stage() {
  local minutes="${1:-75}" note="${2:-}"
  [[ "$minutes" =~ ^[0-9]+$ ]] || { echo "[ERROR] stage MINUTES must be a number" >&2; return 1; }
  python3 - "$OPENEVSE_ROOT/stage.json" "$minutes" "$note" <<'EOF'
import datetime as dt, json, sys
until = dt.datetime.now(dt.timezone.utc).replace(microsecond=0) + dt.timedelta(minutes=int(sys.argv[2]))
json.dump({"until": until.strftime("%Y-%m-%dT%H:%M:%SZ"), "note": sys.argv[3]}, open(sys.argv[1], "w"))
print(f"[INFO] staged test alert until {until:%Y-%m-%dT%H:%M:%SZ}; status.json carries it from the next check")
EOF
}

do_backup() {
  do_rsync_mirror_backup "$OPENEVSE_ROOT" "$BACKUP_DIR"
}

run_cmd() {
  case "$1" in
    pull) run_compose pull ;;
    up) do_up ;;
    down) run_compose down ;;
    restart) need_login restart; run_compose down; do_up ;;
    refresh) do_up ;;
    # Pull only, like the other d03 apps; up applies the new image (and needs the login).
    update) echo "[INFO] Pulling latest images (not starting app; use up to start)"; run_compose pull ;;
    verify) do_verify ;;
    status) do_status ;;
    unstage) rm -f "$OPENEVSE_ROOT/stage.json"; echo "[INFO] staged test alert removed" ;;
    backup) run_detached_if_interactive backup do_backup ;;
    _backup) do_backup ;;
    restore) do_rsync_mirror_restore "$BACKUP_DIR" "$OPENEVSE_ROOT" ;;
    logs) run_compose logs -f ;;
    *) return 1 ;;
  esac
}

if [ $# -eq 0 ]; then
  echo "Usage: $0 up|down|restart|refresh|pull|update|verify|status|stage [MINUTES] [NOTE]|unstage|backup|restore|logs" >&2
  exit 1
fi
[ "$1" = "logs" ] && { run_compose logs -f "${@:2}"; exit 0; }
[ "$1" = "stage" ] && { do_stage "${@:2}"; exit $?; }
for c in "$@"; do run_cmd "$c" || { echo "Unknown: $c" >&2; exit 1; }; done
