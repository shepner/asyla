#!/bin/bash
# Plex on d02: backup, up, down, refresh, update, logs.
# Config lives under ${DOCKER_DL}/plex/plexmediaserver; backups go to ${DOCKER_D1} (tgz).
# Usage: plex.sh backup|up|down|refresh|update|logs
# Run from anywhere; loads ~/scripts/docker/common.env for DOCKER_DL, DATA1, etc.

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

APP_NAME="plex"
APP_ROOT="$DOCKER_DL/$APP_NAME"
BACKUP_DIR="$DOCKER_D1"

export DOCKER_DL
export DOCKER_D1
export DATA1
export LOCAL_TZ
export DOCKER_UID
export DOCKER_GID
export MY_DOMAIN

cmd="${1:-up}"

# Ensure app root exists (config dir created by Plex on first run)
mkdir -p "$APP_ROOT"

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

case "$cmd" in
  backup)
    stamp=$(date +%Y%m%d-%H%M%S)
    archive="$BACKUP_DIR/${APP_NAME}-${stamp}.tgz"
    echo "[INFO] Backing up $APP_ROOT to $archive"
    tar -czf "$archive" -C "${DOCKER_DL}" "$APP_NAME"
    echo "[INFO] Done. Size: $(du -h "$archive" | cut -f1)"
    ;;
  up)
    # Start containers only (no pull)
    run_compose up -d
    ;;
  down)
    run_compose down
    ;;
  refresh)
    # Pull latest images + start
    echo "[INFO] Pulling latest images and starting"
    run_compose pull
    run_compose up -d
    ;;
  update)
    # Pull latest images + start (same as refresh)
    echo "[INFO] Pulling latest images and starting"
    run_compose pull
    run_compose up -d
    ;;
  logs)
    run_compose logs -f "${@:2}"
    ;;
  *)
    echo "Usage: $0 backup|up|down|refresh|update|logs [service...]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  backup   - Create tgz backup of $APP_ROOT to $BACKUP_DIR" >&2
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
