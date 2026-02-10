#!/bin/bash
# TrueNAS MCP Server on d03 — [TrueNasCoreMCP](https://github.com/vespo92/TrueNasCoreMCP)
# Usage: truenas-mcp.sh up|down|restart|logs [service]|refresh|update|run
# Run from anywhere. .env (TRUENAS_URL, TRUENAS_API_KEY) in this directory.
# For Cursor/Claude stdio use: truenas-mcp.sh run (or docker compose run --rm truenas-mcp from app dir).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="compose.yml"

run_compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

cmd="${1:-}"

case "$cmd" in
  up)
    echo "[INFO] Starting TrueNAS MCP (image only; server is stdio-based, use 'run' for Cursor/Claude)"
    run_compose up -d --build
    ;;
  down)
    run_compose down
    ;;
  restart)
    run_compose down
    run_compose up -d --build
    echo "[INFO] Restarted TrueNAS MCP"
    ;;
  logs)
    run_compose logs -f "${@:2}"
    ;;
  refresh)
    echo "[INFO] Rebuild and start"
    run_compose build --no-cache
    run_compose up -d
    ;;
  update)
    echo "[INFO] Rebuild (pull base) and start"
    run_compose build --pull
    run_compose up -d
    ;;
  run)
    # For Cursor/Claude: run server with stdio (do not use -d)
    echo "[INFO] Running TrueNAS MCP server (stdio); use with Cursor/Claude MCP config"
    run_compose run --rm truenas-mcp
    ;;
  *)
    echo "Usage: $0 up|down|restart|logs [service]|refresh|update|run" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  update   - Rebuild (pull base image) + start container" >&2
    echo "  refresh  - Rebuild (no cache) + start container" >&2
    echo "  up       - Build (if needed) and start container" >&2
    echo "  run      - Run server with stdio (for Cursor/Claude MCP config; not detached)" >&2
    echo "  restart  - Down then up" >&2
    echo "" >&2
    echo "  down     - Stop and remove containers" >&2
    echo "  logs     - Follow logs (optionally for one service)" >&2
    echo "" >&2
    echo "When to use:" >&2
    echo "  run      - When configuring Cursor/Claude to use this server (stdio)" >&2
    echo "  update   - After base image updates" >&2
    echo "  refresh  - After Dockerfile or dependency changes" >&2
    echo "  up       - Start already-built container" >&2
    exit 1
    ;;
esac
