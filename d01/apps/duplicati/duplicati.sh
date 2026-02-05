#!/bin/bash
# Duplicati on d01. Usage: duplicati.sh up|down|logs|pull
# Run from anywhere; loads ~/scripts/docker/common.env for DOCKER_DL, DATA1, etc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DATA1="${DATA1:-/mnt/nas/data1}"

export DOCKER_DL
export DATA1
export LOCAL_TZ

# Standalone app: own project dir and project name
APP_ROOT="${DOCKER_DL}/duplicati"

run_compose() {
  docker compose -p duplicati -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

remove_stale_container() {
  docker rm -f duplicati 2>/dev/null || true
}

cmd="${1:-}"

case "$cmd" in
  up)
    echo "[INFO] Creating app dirs if needed"
    mkdir -p "${APP_ROOT}/config" "${APP_ROOT}/backups"
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
    run_compose logs -f "${@:2}"
    ;;
  pull)
    run_compose pull
    remove_stale_container
    run_compose up -d
    ;;
  *)
    echo "Usage: $0 up|down|logs|pull" >&2
    echo "  up   - start Duplicati (access via internal proxy at duplicati.asyla.org)" >&2
    echo "  down - stop and remove container" >&2
    echo "  logs - follow logs" >&2
    echo "  pull - pull image and up" >&2
    exit 1
    ;;
esac
