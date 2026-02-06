#!/bin/bash
# Cloudflare Tunnel (cloudflared) for d03.
# Usage: cloudflared.sh up|down|restart|logs [service]|pull
# Run from anywhere. .env (TUNNEL_TOKEN) in this directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.yml"

ensure_networks() {
  docker network create tc_datalogger_net 2>/dev/null || true
}

run_compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

cmd="${1:-}"

case "$cmd" in
  up)
    echo "[INFO] Ensuring networks exist..."
    ensure_networks
    echo "[INFO] Using token mode (.env TUNNEL_TOKEN)"
    run_compose up -d
    ;;
  down)
    run_compose down
    ;;
  restart)
    run_compose down
    ensure_networks
    run_compose up -d
    echo "[INFO] Restarted cloudflared"
    ;;
  logs)
    run_compose logs -f "${@:2}"
    ;;
  pull)
    run_compose pull
    run_compose up -d
    ;;
  *)
    echo "Usage: $0 up|down|restart|logs [service]|pull" >&2
    echo "  up      - ensure networks and start cloudflared" >&2
    echo "  down    - stop and remove container" >&2
    echo "  restart - down then up" >&2
    echo "  logs - follow logs" >&2
    echo "  pull - pull image and up" >&2
    exit 1
    ;;
esac
