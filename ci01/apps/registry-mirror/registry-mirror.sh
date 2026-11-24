#!/bin/bash
# registry-mirror on ci01 (README.md). Usage: registry-mirror.sh [up|down|restart|refresh|pull|update|verify|status|backup|restore|logs]
# A Docker Hub pull-through cache for ci01's own daemon. No secret (anonymous), so the apps task can
# refresh it. No stage/unstage: it writes no status.json for host-maintenance.
# backup and restore keep nothing: it is a cache, rebuilt by pulls (restore = false in ci01/host.toml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi

DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
APP_NAME="registry-mirror"
MIRROR_ROOT="$DOCKER_DL/$APP_NAME"
MIRROR_URL="http://127.0.0.1:5000"
export DOCKER_DL   # compose.yml names its data path from it

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

do_up() {
  mkdir -p "$MIRROR_ROOT"
  run_compose pull
  run_compose up -d
}

# The container running (healthy or starting), the registry's API answering 200 on loopback, and
# the daemon using it as its mirror (daemon.json registry-mirrors, from [docker] in ci01/host.toml).
do_verify() {
  local state code mirrors bad=0
  state="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$APP_NAME" 2>/dev/null || true)"
  case "$state" in
    "running healthy"|"running starting"|"running ") echo "[INFO] container $APP_NAME: $state" ;;
    *) echo "[ERROR] container $APP_NAME: ${state:-absent}" >&2; bad=1 ;;
  esac
  code="$(curl -fsS -o /dev/null -w '%{http_code}' "$MIRROR_URL/v2/" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then
    echo "[INFO] $MIRROR_URL/v2/: HTTP 200"
  else
    echo "[ERROR] $MIRROR_URL/v2/: HTTP ${code:-none} (want 200)" >&2
    bad=1
  fi
  mirrors="$(docker info --format '{{json .RegistryConfig.Mirrors}}' 2>/dev/null || true)"
  if [[ "$mirrors" == *"\"$MIRROR_URL/\""* ]]; then
    echo "[INFO] dockerd's registry mirrors: $mirrors"
  else
    echo "[ERROR] dockerd's registry mirrors are ${mirrors:-unreadable}, not $MIRROR_URL/ (daemon.json, build/setup/docker.sh)" >&2
    bad=1
  fi
  return "$bad"
}

# What the cache holds (the registry's catalog: one line per repository) and its size on disk.
do_status() {
  docker inspect -f '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$APP_NAME" 2>/dev/null \
    || echo "[WARN] container $APP_NAME absent"
  curl -fsS "$MIRROR_URL/v2/_catalog" | python3 -c 'import json, sys; [print(" ", r) for r in json.load(sys.stdin).get("repositories", [])]' \
    || echo "[WARN] $MIRROR_URL/v2/_catalog did not answer"
  du -sh "$MIRROR_ROOT" 2>/dev/null || true
}

run_cmd() {
  case "$1" in
    pull) run_compose pull ;;
    up) do_up ;;
    down) run_compose down ;;
    restart) run_compose down; do_up ;;
    refresh) do_up ;;
    # Pull only, like the d07 apps; the apps task decides when to apply (refresh). The image is
    # pinned by digest, so a pull changes nothing until compose.yml names a new one.
    update) echo "[INFO] Pulling images (not starting app; use up to start)"; run_compose pull ;;
    verify) do_verify ;;
    status) do_status ;;
    backup) echo "[INFO] $APP_NAME: nothing to back up (a cache, rebuilt by pulls)" ;;
    restore) echo "[INFO] $APP_NAME: nothing to restore (a cache, rebuilt by pulls)" ;;
    logs) run_compose logs -f ;;
    *) return 1 ;;
  esac
}

if [ $# -eq 0 ]; then
  echo "Usage: $0 up|down|restart|refresh|pull|update|verify|status|backup|restore|logs" >&2
  exit 1
fi
[ "$1" = "logs" ] && { run_compose logs -f "${@:2}"; exit 0; }
for c in "$@"; do run_cmd "$c" || { echo "Unknown or failed: $c" >&2; exit 1; }; done
