#!/bin/bash
# TC_datalogger on d03. Usage: tc_datalogger.sh [switch ...] e.g. backup|update|refresh|rebuild|up|down|restart|logs
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env.
# Working files under /mnt/docker/TC_datalogger; backups to /mnt/nas/data1/docker (tgz).
# Builds use --parallel so all six microservices build concurrently (much faster than serial).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="tc_datalogger"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"

APP_NAME="TC_datalogger"
APP_ROOT="$DOCKER_DL/$APP_NAME"
REPO_DIR="$APP_ROOT/repo"
BACKUP_DIR="$DOCKER_D1"

export DOCKER_DL
export DOCKER_D1
export LOCAL_TZ

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

do_backup() {
  stamp=$(date +%Y%m%d-%H%M%S)
  archive="$BACKUP_DIR/${APP_NAME}-${stamp}.tgz"
  echo "[INFO] Backing up $APP_ROOT to $archive (excluding repo)"
  tar -czf "$archive" -C "${DOCKER_DL}" --exclude="$APP_NAME/repo" "$APP_NAME"
  echo "[INFO] Done. Size: $(du -h "$archive" | cut -f1)"
}

do_update() {
  echo "[INFO] Pulling latest from app repo and rebuilding (not starting app; use up or restart to start)"
  git -C "$REPO_DIR" pull
  run_compose build --pull --parallel
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)
      screen -S "backup-${SCREEN_APP}-$(date +%Y%m%d-%H%M%S)" -dm "$0" _backup
      echo "[INFO] Backup running in screen; attach with: screen -r"
      ;;
    _backup)
      do_backup
      ;;
    update)
      screen -S "update-${SCREEN_APP}-$(date +%Y%m%d-%H%M%S)" -dm "$0" _update
      echo "[INFO] Update running in screen; use 'up' or 'restart' to start when done. Attach: screen -r"
      ;;
    _update)
      do_update
      ;;
    refresh)
      echo "[INFO] Rebuilding (parallel) and starting"
      run_compose build --parallel
      run_compose up -d
      ;;
    rebuild)
      echo "[INFO] Full rebuild (no cache, parallel) and start"
      run_compose build --no-cache --parallel
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
  echo "  backup   - Create tgz backup of $APP_ROOT (excl. repo) to $BACKUP_DIR (runs in screen)" >&2
  echo "  update   - Git pull + rebuild in screen; use up/restart to start" >&2
  echo "  refresh  - Rebuild with cache + start (inline)" >&2
  echo "  rebuild  - Full rebuild without cache + start" >&2
  echo "  up       - Start containers only" >&2
  echo "  down     - Stop and remove containers" >&2
  echo "  restart  - Down then up" >&2
  echo "  logs     - Follow logs (optionally for one service)" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "Usage: $0 backup|update|refresh|rebuild|up|down|restart|logs [ ... ]" >&2
    exit 1
  fi
done
