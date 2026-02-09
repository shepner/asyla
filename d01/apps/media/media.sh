#!/bin/bash
# Media stack on d01: Sonarr, Radarr, Overseerr, Jackett, Transmission.
# Working dirs under /mnt/docker (sonarr, radarr, overseerr, jackett, transmission).
# Usage: media.sh backup|up|down|logs [service...]|refresh|update
# Run from anywhere; loads ~/scripts/docker/common.env for DOCKER_DL, DOCKER_UID, etc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"
DATA1="${DATA1:-/mnt/nas/data1}"

APP_NAME="media"
# Project dir for compose; bind mounts use DOCKER_DL paths
APP_ROOT="$DOCKER_DL"
BACKUP_DIR="$DOCKER_D1"

export DOCKER_DL
export DOCKER_D1
export DATA1
export LOCAL_TZ

cmd="${1:-}"

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

case "$cmd" in
  backup)
    stamp=$(date +%Y%m%d-%H%M%S)
    archive="$BACKUP_DIR/media-stack-${stamp}.tgz"
    echo "[INFO] Backing up media app dirs to $archive"
    tar -czf "$archive" -C "${DOCKER_DL}" \
      sonarr radarr overseerr jackett transmission 2>/dev/null || true
    echo "[INFO] Done. Size: $(du -h "$archive" | cut -f1)"
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
    run_compose logs -f "${@:2}"
    ;;
  refresh)
    # Pull latest images + start
    echo "[INFO] Pulling latest images and starting"
    echo "[INFO] Creating app dirs if needed"
    for dir in sonarr/config radarr/config overseerr/config jackett/config jackett/downloads transmission/config transmission/watch transmission/downloads; do
      mkdir -p "${DOCKER_DL}/${dir}"
    done
    run_compose pull
    run_compose up -d
    ;;
  update)
    # Pull latest images + start (same as refresh)
    echo "[INFO] Pulling latest images and starting"
    echo "[INFO] Creating app dirs if needed"
    for dir in sonarr/config radarr/config overseerr/config jackett/config jackett/downloads transmission/config transmission/watch transmission/downloads; do
      mkdir -p "${DOCKER_DL}/${dir}"
    done
    run_compose pull
    run_compose up -d
    ;;
  *)
    echo "Usage: $0 backup|up|down|logs [service...]|refresh|update" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  backup   - Create tgz backup of sonarr,radarr,overseerr,jackett,transmission to $BACKUP_DIR" >&2
    echo "" >&2
    echo "  update   - Pull latest images + start" >&2
    echo "  refresh  - Pull latest images + start (same as update)" >&2
    echo "  up       - Start containers only (no pull; fails if images missing)" >&2
    echo "" >&2
    echo "  down     - Stop and remove containers" >&2
    echo "  logs     - Follow logs (optionally for one service)" >&2
    echo "" >&2
    echo "When to use:" >&2
    echo "  update   - After image updates or when you need latest images" >&2
    echo "  refresh  - Same as update" >&2
    echo "  up       - Just start already-pulled containers" >&2
    exit 1
    ;;
esac
