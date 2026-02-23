#!/bin/bash
# Calibre on d01. Usage: calibre.sh backup|up|down|logs|refresh|update
# Run from anywhere; loads ~/scripts/docker/common.env for DOCKER_DL, etc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

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

# Standalone app: own project dir and project name (not part of media stack)
APP_ROOT="${DOCKER_DL}/calibre"

run_compose() {
  docker compose -p calibre -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

# Remove any existing container named "calibre" (e.g. orphan from another project)
# so our project can create one. Safe to run before up/pull.
remove_stale_calibre_container() {
  docker rm -f calibre 2>/dev/null || true
}

cmd="${1:-}"

case "$cmd" in
  backup)
    stamp=$(date +%Y%m%d-%H%M%S)
    archive="${DOCKER_D1}/calibre-backup-${stamp}.tgz"
    echo "[INFO] Backing up Calibre data to $archive"
    mkdir -p "$(dirname "$archive")"
    tar -czf "$archive" -C "${DOCKER_DL}" calibre 2>/dev/null || true
    echo "[INFO] Done. Size: $(du -h "$archive" 2>/dev/null | cut -f1)"
    ;;
  up)
    echo "[INFO] Creating app dir if needed"
    mkdir -p "${DOCKER_DL}/calibre/config"
    docker network create calibre_net 2>/dev/null || true
    remove_stale_calibre_container
    echo "[INFO] Starting Calibre"
    run_compose up -d
    ;;
  down)
    run_compose down
    remove_stale_calibre_container
    ;;
  logs)
    run_compose logs -f "${@:2}"
    ;;
  refresh)
    # Pull latest images + start
    echo "[INFO] Pulling latest images and starting"
    run_compose pull
    remove_stale_calibre_container
    run_compose up -d
    ;;
  update)
    # Pull latest images + start (same as refresh)
    echo "[INFO] Pulling latest images and starting"
    run_compose pull
    remove_stale_calibre_container
    run_compose up -d
    ;;
  *)
    echo "Usage: $0 backup|up|down|logs|refresh|update" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  backup   - Create tgz of calibre data to NFS (DOCKER_D1)" >&2
    echo "  update   - Pull latest images + start" >&2
    echo "  refresh  - Pull latest images + start (same as update)" >&2
    echo "  up       - Start containers only (no pull; fails if images missing)" >&2
    echo "" >&2
    echo "  down     - Stop and remove containers" >&2
    echo "  logs     - Follow logs" >&2
    echo "" >&2
    echo "When to use:" >&2
    echo "  update   - After image updates or when you need latest images" >&2
    echo "  refresh  - Same as update" >&2
    echo "  up       - Just start already-pulled containers" >&2
    echo "" >&2
    echo "Access: via cloudflared or internal proxy" >&2
    exit 1
    ;;
esac
