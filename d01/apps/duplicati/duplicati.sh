#!/bin/bash
# Duplicati on d01. Usage: duplicati.sh [switch ...] e.g. backup|up|down|logs|refresh|update|restart
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env.
# Backups: daily-friendly rsync snapshots with hardlinks, under ${DOCKER_D1}/duplicati/<stamp>/.

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
DATA1="${DATA1:-/mnt/nas/data1}"
DOCKER_D1="${DOCKER_D1:-${DATA1}/docker}"

export DOCKER_DL
export DATA1
export DOCKER_D1
export LOCAL_TZ

APP_NAME="duplicati"
APP_ROOT="${DOCKER_DL}/${APP_NAME}"
BACKUP_ROOT="${DOCKER_D1}/${APP_NAME}"
BACKUP_KEEP="${BACKUP_KEEP:-14}"

run_compose() {
  docker compose -p "$APP_NAME" -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

remove_stale_container() {
  docker rm -f duplicati 2>/dev/null || true
}

do_backup() {
  do_rsync_snapshot_backup \
    "$APP_ROOT" \
    "$BACKUP_ROOT" \
    "$BACKUP_KEEP"
}

do_update() {
  echo "[INFO] Pulling latest images (not starting app; use up or restart to start)"
  run_compose pull
  remove_stale_container
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)  do_backup ;;
    update)  do_update ;;
    up)
      echo "[INFO] Creating app dir if needed"
      mkdir -p "${APP_ROOT}/config"
      docker network create duplicati_net 2>/dev/null || true
      remove_stale_container
      echo "[INFO] Starting Duplicati"
      run_compose up -d
      ;;
    down)
      run_compose down
      remove_stale_container
      ;;
    logs)
      run_compose logs -f
      ;;
    refresh)
      echo "[INFO] Pulling latest images and starting"
      run_compose pull
      remove_stale_container
      run_compose up -d
      ;;
    restart)
      run_compose down
      remove_stale_container
      mkdir -p "${APP_ROOT}/config"
      docker network create duplicati_net 2>/dev/null || true
      run_compose up -d
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
  echo "  backup   - rsync snapshot of $APP_ROOT to $BACKUP_ROOT/<stamp>/ (incremental; keeps $BACKUP_KEEP snapshots)" >&2
  echo "  update   - Pull latest images (no restart); use up/restart to start" >&2
  echo "  refresh  - Pull latest images + start (inline)" >&2
  echo "  up       - Start containers only" >&2
  echo "  down     - Stop and remove containers" >&2
  echo "  restart  - Down then up" >&2
  echo "  logs     - Follow logs" >&2
  echo "" >&2
  echo "Access: internal proxy at duplicati.asyla.org" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  case "$cmd" in
    backup|update|up|down|logs|refresh|restart) ;;
    *)
      echo "Usage: $0 backup|up|down|logs|refresh|update|restart [ ... ]" >&2
      exit 1
      ;;
  esac
done

for cmd in "$@"; do
  run_cmd "$cmd"
done
