#!/bin/bash
# Mozilla cq team store on d03 — team API + review UI.
# Usage: cq.sh [switch ...] e.g. up|down|restart|logs|pull|build
# Requires: ./upstream (clone of mozilla-ai/cq), .env with CQ_JWT_SECRET, DOCKER_DL in ~/scripts/docker/common.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="cq"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi

DOCKER_DL="${DOCKER_DL:-/mnt/docker}"

if [ ! -d "$SCRIPT_DIR/upstream/team-api" ] || [ ! -d "$SCRIPT_DIR/upstream/team-ui" ]; then
  echo "[ERROR] Missing cq upstream sources. Clone mozilla-ai/cq:" >&2
  echo "  git clone --depth 1 --branch 0.4.0 https://github.com/mozilla-ai/cq.git \"$SCRIPT_DIR/upstream\"" >&2
  echo "  (or omit --branch to track main; pin a release for reproducible builds)" >&2
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "[ERROR] Copy $SCRIPT_DIR/.env.example to .env and set CQ_JWT_SECRET." >&2
  exit 1
fi

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

do_pull_build() {
  echo "[INFO] Building cq images from ./upstream (no pre-published images on Docker Hub)."
  run_compose build --pull
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    pull)
      do_pull_build
      ;;
    build)
      do_pull_build
      ;;
    update)
      screen -S "update-${SCREEN_APP}-$(date +%Y%m%d-%H%M%S)" -dm "$0" _update
      echo "[INFO] Rebuild running in screen; attach: screen -r"
      ;;
    _update)
      do_pull_build
      ;;
    refresh)
      do_pull_build
      run_compose up -d
      ;;
    up)
      run_compose up -d
      ;;
    down)
      run_compose down
      ;;
    restart)
      run_compose down
      run_compose up -d
      ;;
    logs)
      run_compose logs -f
      ;;
    *)
      return 1
      ;;
  esac
}

if [ $# -eq 0 ]; then
  echo "Usage: $0 [switch ...]" >&2
  echo "  pull|build   - Build images from ./upstream" >&2
  echo "  update       - Build in screen" >&2
  echo "  refresh      - Build + up -d" >&2
  echo "  up|down|restart|logs" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "Usage: $0 pull|build|update|refresh|up|down|restart|logs" >&2
    exit 1
  fi
done
