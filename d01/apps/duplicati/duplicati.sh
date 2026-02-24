#!/bin/bash
# Duplicati on d01. Usage: duplicati.sh [switch ...] e.g. backup|up|down|logs|refresh|update|restart
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="duplicati"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DATA1="${DATA1:-/mnt/nas/data1}"
DOCKER_D1="${DOCKER_D1:-${DATA1}/docker}"

export DOCKER_DL
export DATA1
export DOCKER_D1
export LOCAL_TZ

# Standalone app: own project dir and project name
APP_ROOT="${DOCKER_DL}/duplicati"

run_compose() {
  docker compose -p duplicati -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

remove_stale_container() {
  docker rm -f duplicati 2>/dev/null || true
}

do_backup() {
  stamp=$(date +%Y%m%d-%H%M%S)
  archive="${DOCKER_D1}/duplicati-backup-${stamp}.tgz"
  echo "[INFO] Backing up Duplicati data to $archive"
  mkdir -p "$(dirname "$archive")"
  tar -czf "$archive" -C "${DOCKER_DL}" duplicati 2>/dev/null || true
  echo "[INFO] Done. Size: $(du -h "$archive" 2>/dev/null | cut -f1)"
}

do_update() {
  echo "[INFO] Pulling latest images (not starting app; use up or restart to start)"
  run_compose pull
  remove_stale_container
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
    update)
      screen -S "update-${SCREEN_APP}-$(date +%Y%m%d-%H%M%S)" -dm "$0" _update
      echo "[INFO] Update running in screen; use 'up' or 'restart' to start when done. Attach: screen -r"
      ;;
    _update)
      do_update
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

# No args: show usage
if [ $# -eq 0 ]; then
  echo "Usage: $0 [switch ...]" >&2
  echo "  Switches can be combined, e.g. down backup up" >&2
  echo "" >&2
  echo "  backup   - Create tgz of duplicati data to NFS (runs in screen)" >&2
  echo "  update   - Pull latest images in screen; use up/restart to start" >&2
  echo "  refresh  - Pull latest images + start (inline)" >&2
  echo "  up       - Start containers only" >&2
  echo "  down     - Stop and remove containers" >&2
  echo "  restart  - Down then up" >&2
  echo "  logs     - Follow logs" >&2
  echo "" >&2
  echo "Access: internal proxy at duplicati.asyla.org" >&2
  exit 1
fi

# logs as sole command: pass remaining args to logs
if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

# Run each switch in order
for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "Usage: $0 backup|up|down|logs|refresh|update|restart [ ... ]" >&2
    exit 1
  fi
done
