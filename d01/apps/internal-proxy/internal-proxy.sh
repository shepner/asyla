#!/bin/bash
# Internal Caddy proxy for d01 (split-DNS).
# Usage: internal-proxy.sh up|down|restart|logs [service]|refresh|update
# Use 'restart' after update_scripts.sh so Caddy reloads the Caddyfile.
# Run from anywhere.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.yml"

ensure_networks() {
  docker network create d01_internal 2>/dev/null || true
  docker network create media_net 2>/dev/null || true
  docker network create calibre_net 2>/dev/null || true
  docker network create homebridge_net 2>/dev/null || true
  docker network create duplicati_net 2>/dev/null || true
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
  restart)
    run_compose down
    ensure_networks
    run_compose up -d
    echo "[INFO] Restarted; Caddy loaded current Caddyfile"
    ;;
  logs)
    run_compose logs -f "${@:2}"
    ;;
  refresh)
    # Pull latest images + start
    echo "[INFO] Pulling latest images and starting"
    ensure_networks
    run_compose pull
    run_compose up -d
    ;;
  update)
    # Pull latest images + start (same as refresh)
    echo "[INFO] Pulling latest images and starting"
    ensure_networks
    run_compose pull
    run_compose up -d
    ;;
  *)
    echo "Usage: $0 up|down|restart|logs [service]|refresh|update" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  update   - Pull latest images + start" >&2
    echo "  refresh  - Pull latest images + start (same as update)" >&2
    echo "  up       - Start containers only (no pull; fails if images missing)" >&2
    echo "  restart  - Down then up; use after update_scripts to reload Caddyfile" >&2
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
