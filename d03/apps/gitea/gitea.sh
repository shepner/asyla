#!/bin/bash
# Gitea on d03: backup, update, refresh, up.
# Data under /mnt/docker/Gitea; backups go to /mnt/nas/data1/docker (tgz).
# Usage: gitea.sh backup|update|refresh|up|down|logs [service]
# Run from anywhere; loads ~/scripts/docker/common.env for DOCKER_DL and DOCKER_D1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"

APP_NAME="Gitea"
APP_ROOT="$DOCKER_DL/Gitea"
BACKUP_DIR="$DOCKER_D1"

export DOCKER_DL
export DOCKER_D1
export LOCAL_TZ

cmd="${1:-}"

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

case "$cmd" in
  backup)
    stamp=$(date +%Y%m%d-%H%M%S)
    archive="$BACKUP_DIR/${APP_NAME}-${stamp}.tgz"
    echo "[INFO] Backing up $APP_ROOT to $archive"
    tar -czf "$archive" -C "${DOCKER_DL}" Gitea
    echo "[INFO] Done. Size: $(du -h "$archive" | cut -f1)"
    ;;
  update)
    echo "[INFO] Pulling latest images and starting"
    run_compose pull
    run_compose up -d
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
  logs)
    run_compose logs -f "${@:2}"
    ;;
  *)
    echo "Usage: $0 backup|update|refresh|up|down|logs [service...]" >&2
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
