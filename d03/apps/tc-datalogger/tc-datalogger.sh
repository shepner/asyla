#!/bin/bash
# tc-datalogger on d03. Usage: tc-datalogger.sh [up|down|restart|verify|pull|backup|restore|logs|...]
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
export DOCKER_DL DOCKER_D1 TC_REGISTRY TC_IMAGE_TAG DASHBOARD_SECRET_KEY DASHBOARD_MODE LOCAL_TZ

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

do_backup() {
  # repo/ is a source checkout, not app state.
  do_rsync_mirror_backup "$APP_ROOT" "$BACKUP_DIR" -- --exclude=/repo/
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
}

run_cmd() {
  case "$1" in
    pull) run_compose pull ;;
    up) run_compose pull; run_compose up -d ;;
    down) run_compose down ;;
    restart) run_compose down; run_compose up -d ;;
    refresh) run_compose pull; run_compose up -d ;;
    # Pull only, like the other d03 apps; use up or restart to apply the new image.
    update) echo "[INFO] Pulling latest images (not starting app; use up or restart to start)"; run_compose pull ;;
    verify) do_verify ;;
    backup) run_detached_if_interactive backup do_backup ;;
    _backup) do_backup ;;
    # Rebuilt host only: refuses unless APP_ROOT is empty and the mirror's last backup is OK.
    # repo/ is not in the mirror (see do_backup): clone it again before `up`.
    restore) do_rsync_mirror_restore "$BACKUP_DIR" "$APP_ROOT" ;;
    logs) run_compose logs -f ;;
    *) return 1 ;;
  esac
}

if [ $# -eq 0 ]; then
  echo "Usage: $0 pull|up|down|restart|refresh|update|verify|backup|restore|logs" >&2
  exit 1
fi
[ "$1" = "logs" ] && { run_compose logs -f "${@:2}"; exit 0; }
for c in "$@"; do run_cmd "$c" || { echo "Unknown: $c" >&2; exit 1; }; done
