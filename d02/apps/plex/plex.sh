#!/bin/bash
# Plex on d02: backup, up, down, pull, update, logs.
# Config lives under ${DOCKER_DL}/plex/plexmediaserver; backups go to ${DOCKER_D1} (tgz).
# Usage: plex.sh backup|up|down|pull|update|logs
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
    run_compose up -d
    ;;
  down)
    run_compose down
    ;;
  pull)
    run_compose pull
    run_compose up -d
    ;;
  update)
    echo "[INFO] Pulling latest image and starting"
    run_compose pull
    run_compose up -d
    ;;
  logs)
    run_compose logs -f "${@:2}"
    ;;
  *)
    echo "Usage: $0 backup|up|down|pull|update|logs" >&2
    echo "  backup - tgz of $APP_ROOT to $BACKUP_DIR" >&2
    echo "  up     - start (default)" >&2
    echo "  down   - stop and remove container" >&2
    echo "  pull   - pull latest image and up" >&2
    echo "  update - pull latest image and start (same as pull)" >&2
    echo "  logs   - follow logs" >&2
    exit 1
    ;;
esac
