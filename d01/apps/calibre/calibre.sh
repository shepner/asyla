#!/bin/bash
# Calibre on d01. Usage: calibre.sh up|down|logs|pull
# Run from anywhere; loads ~/scripts/docker/common.env for DOCKER_DL, etc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"

export DOCKER_DL
export LOCAL_TZ

APP_ROOT="${DOCKER_DL}"

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

cmd="${1:-}"

case "$cmd" in
  up)
    echo "[INFO] Creating app dir if needed"
    mkdir -p "${DOCKER_DL}/calibre/config"
    echo "[INFO] Starting Calibre"
    run_compose up -d
    ;;
  down)
    run_compose down
    ;;
  logs)
    run_compose logs -f "${@:2}"
    ;;
  pull)
    run_compose pull
    run_compose up -d
    ;;
  *)
    echo "Usage: $0 up|down|logs|pull" >&2
    echo "  up   - start Calibre (access via cloudflared or internal proxy)" >&2
    echo "  down - stop and remove container" >&2
    echo "  logs - follow logs" >&2
    echo "  pull - pull image and up" >&2
    exit 1
    ;;
esac
