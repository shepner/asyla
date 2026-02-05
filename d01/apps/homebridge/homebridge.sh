#!/bin/bash
# Homebridge on d01. Usage: homebridge.sh up|down|logs|pull
# Run from anywhere; loads ~/scripts/docker/common.env for DOCKER_DL, etc.
# Homebridge uses host network (mDNS/HomeKit); homebridge-proxy exposes UI to tunnel.

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

# Standalone app: own project dir and project name
APP_ROOT="${DOCKER_DL}/homebridge"

run_compose() {
  docker compose -p homebridge -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

remove_stale_container() {
  docker rm -f homebridge 2>/dev/null || true
  docker rm -f homebridge-proxy 2>/dev/null || true
  docker rm -f cameraui-proxy 2>/dev/null || true
}

cmd="${1:-}"

case "$cmd" in
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
    run_compose logs -f "${@:2}"
    ;;
  pull)
    run_compose pull
    remove_stale_container
    run_compose up -d
    ;;
  *)
    echo "Usage: $0 up|down|logs|pull" >&2
    echo "  up   - start Homebridge (UI via cloudflared or internal proxy at :8581)" >&2
    echo "  down - stop and remove containers" >&2
    echo "  logs - follow logs" >&2
    echo "  pull - pull image and up" >&2
    exit 1
    ;;
esac
