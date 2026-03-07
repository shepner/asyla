#!/bin/bash
# Dispatcher (knowledge-hub dispatch agent) on d03.
# Usage: dispatcher.sh [ up | down | one-cycle | logs ]
#
# one-cycle: run a single poll cycle and exit (testable; no daemon).
# Build context: knowledge-hub checkout at ~/scripts/knowledge-hub (see README).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    up)
      run_compose up -d
      ;;
    down)
      run_compose down
      ;;
    one-cycle)
      # Single poll cycle then exit — acceptance test: container starts and runs one cycle.
      run_compose run --rm dispatcher python3 .cursor/helpers/dispatch_agent.py \
        --poll --poll-interval 0 --project /app
      ;;
    logs)
      run_compose logs -f "${@:2}"
      ;;
    *)
      return 1
      ;;
  esac
}

if [ $# -eq 0 ]; then
  echo "Usage: $0 up | down | one-cycle | logs [ ... ]" >&2
  echo "" >&2
  echo "  up         - Start dispatcher container (daemon)" >&2
  echo "  down       - Stop and remove container" >&2
  echo "  one-cycle  - Run one poll cycle and exit (testable)" >&2
  echo "  logs       - Follow container logs" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "Usage: $0 up | down | one-cycle | logs [ ... ]" >&2
    exit 1
  fi
done
