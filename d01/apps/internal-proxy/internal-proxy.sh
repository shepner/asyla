#!/bin/bash
# Internal Caddy proxy for d01 (split-DNS).
# Usage: internal-proxy.sh up|down|logs [service]|pull
# Run from anywhere.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.yml"

ensure_networks() {
  docker network create d01_internal 2>/dev/null || true
  docker network create media_net 2>/dev/null || true
}

run_compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

cmd="${1:-}"

case "$cmd" in
  up)
    echo "[INFO] Ensuring networks exist..."
    ensure_networks
    echo "[INFO] Starting internal proxy"
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
    echo "Usage: $0 up|down|logs [service]|pull" >&2
    echo "  up   - ensure networks and start Caddy" >&2
    echo "  down - stop and remove container" >&2
    echo "  logs - follow logs" >&2
    echo "  pull - pull image and up" >&2
    exit 1
    ;;
esac
