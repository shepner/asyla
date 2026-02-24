#!/bin/bash
# Media stack on d01: Sonarr, Radarr, Overseerr, Jackett, Transmission.
# Usage: media.sh [switch ...] e.g. backup|up|down|logs|refresh|update|restart
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="media"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"
DATA1="${DATA1:-/mnt/nas/data1}"

APP_NAME="media"
APP_ROOT="$DOCKER_DL"
BACKUP_DIR="$DOCKER_D1"

export DOCKER_DL
export DOCKER_D1
export DATA1
export LOCAL_TZ

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

do_backup() {
  stamp=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_DIR"
  for service in sonarr radarr overseerr jackett transmission; do
    config_dir="${DOCKER_DL}/${service}/config"
    archive="$BACKUP_DIR/media-${service}-${stamp}.tgz"
    if [ -d "$config_dir" ]; then
      echo "[INFO] Backing up $service config to $archive"
      tar -czf "$archive" -C "${DOCKER_DL}" "${service}/config" 2>/dev/null || true
      echo "[INFO] Done. Size: $(du -h "$archive" | cut -f1)"
    else
      echo "[INFO] Skipping $service (no config dir: $config_dir)"
    fi
  done
}

do_update() {
  echo "[INFO] Pulling latest images (not starting app; use up or restart to start)"
  run_compose pull
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
      echo "[INFO] Creating app dirs if needed"
      for dir in sonarr/config radarr/config overseerr/config jackett/config jackett/downloads transmission/config transmission/watch transmission/downloads; do
        mkdir -p "${DOCKER_DL}/${dir}"
      done
      echo "[INFO] Starting media stack"
      run_compose up -d
      ;;
    down)
      run_compose down
      ;;
    logs)
      run_compose logs -f
      ;;
    refresh)
      echo "[INFO] Pulling latest images and starting"
      for dir in sonarr/config radarr/config overseerr/config jackett/config jackett/downloads transmission/config transmission/watch transmission/downloads; do
        mkdir -p "${DOCKER_DL}/${dir}"
      done
      run_compose pull
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
      for dir in sonarr/config radarr/config overseerr/config jackett/config jackett/downloads transmission/config transmission/watch transmission/downloads; do
        mkdir -p "${DOCKER_DL}/${dir}"
      done
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
  echo "  backup   - Create one tgz per service (config only) in $BACKUP_DIR (runs in screen)" >&2
  echo "  update   - Pull latest images in screen; use up/restart to start" >&2
  echo "  refresh  - Pull latest images + start (inline)" >&2
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
    echo "Usage: $0 backup|up|down|logs|refresh|update|restart [ ... ]" >&2
    exit 1
  fi
done
