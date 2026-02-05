#!/bin/bash
# Cloudflare Tunnel (cloudflared) for d01.
# Usage: cloudflared.sh up|down|logs [service]|pull
# Run from anywhere. .env (TUNNEL_TOKEN) must be in this directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.yml"
COMPOSE_EXTRA=""
if [ -f "config.yml" ] && [ -f "credentials.json" ]; then
  COMPOSE_EXTRA="-f docker-compose.config.yml"
fi

ensure_networks() {
  docker network create d01_internal 2>/dev/null || true
  docker network create media_net 2>/dev/null || true
  docker network create calibre_net 2>/dev/null || true
  docker network create homebridge_net 2>/dev/null || true
}

run_compose() {
  docker compose -f "$COMPOSE_FILE" $COMPOSE_EXTRA "$@"
}

cmd="${1:-}"

case "$cmd" in
  up)
    echo "[INFO] Ensuring networks exist..."
    ensure_networks
    if [ -n "$COMPOSE_EXTRA" ]; then
      echo "[INFO] Using config file mode (config.yml + credentials.json)"
    else
      echo "[INFO] Using token mode (.env TUNNEL_TOKEN)"
    fi
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
    echo "  up   - ensure networks and start cloudflared" >&2
    echo "  down - stop and remove container" >&2
    echo "  logs - follow logs" >&2
    echo "  pull - pull image and up" >&2
    exit 1
    ;;
esac
