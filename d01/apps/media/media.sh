#!/bin/bash
# Media stack on d01: Sonarr, Radarr, Overseerr, Jackett, Transmission.
# Usage: media.sh [switch ...] e.g. backup|up|down|logs|refresh|update|restart
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env.
# Backups: per-service rsync snapshots with hardlinks, under ${DOCKER_D1}/media-<service>/<stamp>/.

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
DATA1="${DATA1:-/mnt/nas/data1}"

APP_NAME="media"
APP_ROOT="$DOCKER_DL"
BACKUP_KEEP="${BACKUP_KEEP:-14}"

export DOCKER_DL
export DOCKER_D1
export DATA1
export LOCAL_TZ

# Services in the media stack and the per-service config subdir under DOCKER_DL.
MEDIA_SERVICES=(sonarr radarr overseerr jackett transmission)

# Directories that need to exist for `up`/`refresh`/`restart`.
MEDIA_UP_DIRS=(
  sonarr/config radarr/config overseerr/config jackett/config jackett/downloads
  transmission/config transmission/watch transmission/downloads
  transmission/downloads/complete transmission/downloads/incomplete
)

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

ensure_dirs() {
  local dir
  for dir in "${MEDIA_UP_DIRS[@]}"; do
    mkdir -p "${DOCKER_DL}/${dir}"
  done
}

do_backup() {
  # One snapshot tree per service, all rooted under DOCKER_D1/media-<service>/.
  # We back up the service's `config` dir only — the actual media library lives
  # on NFS already, downloads are transient and don't need backup.
  local rc=0
  local service src dest
  for service in "${MEDIA_SERVICES[@]}"; do
    src="${DOCKER_DL}/${service}/config"
    dest="${DOCKER_D1}/media-${service}"
    if [ ! -d "$src" ]; then
      echo "[INFO] Skipping $service (no config dir: $src)"
      continue
    fi
    echo "[INFO] === $service ==="
    do_rsync_snapshot_backup \
      "$src" \
      "$dest" \
      "$BACKUP_KEEP" \
      -- \
      --exclude="logs/" \
      --exclude="Logs/" \
      --exclude="MediaCover/" \
      --exclude="cache/" \
      --exclude="Cache/" \
      --exclude="*.bak" \
      || rc=$?
  done
  return $rc
}

do_update() {
  echo "[INFO] Pulling latest images (not starting app; use up or restart to start)"
  run_compose pull
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)  do_backup ;;
    update)  do_update ;;
    up)
      echo "[INFO] Creating app dirs if needed"
      ensure_dirs
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
      ensure_dirs
      run_compose pull
      run_compose up -d
      ;;
    restart)
      run_compose down
      ensure_dirs
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
  echo "  backup   - Per-service rsync snapshots of config dirs under \$DOCKER_D1/media-<service>/<stamp>/" >&2
  echo "             (incremental; keeps $BACKUP_KEEP snapshots per service)" >&2
  echo "  update   - Pull latest images (no restart); use up/restart to start" >&2
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
