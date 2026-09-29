#!/bin/bash
# agent-commons on d03. Usage: agent-commons.sh [switch ...] e.g. backup|update|refresh|up|down|restart|logs
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env when present.
# Data: /mnt/docker/agent-commons (SQLite agent_commons.db). Backups: /mnt/nas/data1/docker/*.tgz

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="agent-commons"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
# shellcheck source=/dev/null
. "$HOME/scripts/docker/backup_lib.sh"
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"

APP_NAME="agent-commons"
APP_ROOT="$DOCKER_DL/$APP_NAME"
BACKUP_DIR="$DOCKER_D1/$APP_NAME/mirror"

export DOCKER_DL
export DOCKER_D1

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

do_backup() {
  do_rsync_mirror_backup "$APP_ROOT" "$BACKUP_DIR"
}

do_update() {
  echo "[INFO] Pulling latest images (not starting app; use up or restart to start)"
  run_compose pull
}

do_verify() {
  echo "[INFO] Health check http://127.0.0.1:8765/api/v1/health (requires published port or docker exec)"
  if run_compose exec -T agent-commons curl -sf http://127.0.0.1:8765/api/v1/health; then
    echo "[INFO] OK"
  else
    echo "[ERROR] Health check failed" >&2
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
  echo "  update   - Pull images (screen if interactive); use up/restart to start" >&2
  echo "  refresh  - Pull + start (inline)" >&2
  echo "  up       - Start containers" >&2
  echo "  down     - Stop containers" >&2
  echo "  restart  - Down then up" >&2
  echo "  verify   - curl health inside container" >&2
  echo "  logs     - Follow logs" >&2
  echo "" >&2
  echo "  APP_ROOT: $APP_ROOT" >&2
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
