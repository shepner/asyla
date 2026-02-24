#!/bin/bash
# Homebridge on d01. Usage: homebridge.sh [switch ...] e.g. backup|up|down|logs|refresh|update|restart
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env.
# Homebridge uses host network (mDNS/HomeKit); homebridge-proxy exposes UI to tunnel.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="homebridge"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"

export DOCKER_DL
export DOCKER_D1
export LOCAL_TZ

APP_ROOT="${DOCKER_DL}/homebridge"

run_compose() {
  docker compose -p homebridge -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

remove_stale_container() {
  docker rm -f homebridge 2>/dev/null || true
  docker rm -f homebridge-proxy 2>/dev/null || true
  docker rm -f cameraui-proxy 2>/dev/null || true
}

do_backup() {
  stamp=$(date +%Y%m%d-%H%M%S)
  archive="${DOCKER_D1}/homebridge-backup-${stamp}.tgz"
  echo "[INFO] Backing up Homebridge data to $archive"
  mkdir -p "$(dirname "$archive")"
  tar -czf "$archive" -C "${DOCKER_DL}" homebridge 2>/dev/null || true
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
      mkdir -p "${APP_ROOT}"
      docker network create homebridge_net 2>/dev/null || true
      remove_stale_container
      echo "[INFO] Starting Homebridge and proxy"
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
      mkdir -p "${APP_ROOT}"
      docker network create homebridge_net 2>/dev/null || true
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
  echo "  backup   - Create tgz of homebridge data to NFS (runs in screen)" >&2
  echo "  update   - Pull latest images in screen; use up/restart to start" >&2
  echo "  refresh  - Pull latest images + start (inline)" >&2
  echo "  up       - Start containers only" >&2
  echo "  down     - Stop and remove containers" >&2
  echo "  restart  - Down then up" >&2
  echo "  logs     - Follow logs" >&2
  echo "" >&2
  echo "Access: UI via cloudflared or internal proxy at :8581" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "Usage: $0 backup|up|down|logs|refresh|update|restart [ ... ]" >&2
    exit 1
  fi
done
