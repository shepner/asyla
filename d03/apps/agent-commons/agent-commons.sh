#!/bin/bash
# agent-commons on d03. Usage: agent-commons.sh [switch ...] e.g. build|backup|update|refresh|up|down|restart|logs
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env when present.
# Data: /mnt/docker/agent-commons (SQLite agent_commons.db). Backups: /mnt/nas/data1/docker/*.tgz
# Image: built for this host's CPU (linux/amd64 on d03, linux/arm64 on Apple Silicon) unless AGENT_COMMONS_PULL=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="agent-commons"
# shellcheck source=lib/docker-native-build.sh
. "$SCRIPT_DIR/lib/docker-native-build.sh"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/.env"
  set +a
fi

DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"

APP_NAME="agent-commons"
APP_ROOT="$DOCKER_DL/$APP_NAME"
BACKUP_DIR="$DOCKER_D1"
DEFAULT_IMAGE="agent-commons:local"
AGENT_COMMONS_IMAGE="${AGENT_COMMONS_IMAGE:-$DEFAULT_IMAGE}"

export DOCKER_DL
export DOCKER_D1
export AGENT_COMMONS_IMAGE

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

resolve_source_dir() {
  local d
  if [ -n "${AGENT_COMMONS_SRC:-}" ] && [ -f "${AGENT_COMMONS_SRC}/Dockerfile" ]; then
    printf '%s' "$AGENT_COMMONS_SRC"
    return 0
  fi
  for d in \
    "$HOME/local/asyla/projects/agent-commons" \
    "$HOME/asyla/projects/agent-commons" \
    "$SCRIPT_DIR/.src/agent-commons"; do
    if [ -f "$d/Dockerfile" ]; then
      printf '%s' "$d"
      return 0
    fi
  done
  echo "[ERROR] agent-commons source not found (need Dockerfile)." >&2
  echo "  Set AGENT_COMMONS_SRC in $SCRIPT_DIR/.env or clone:" >&2
  echo "  git clone https://gitea.asyla.org/asyla/agent-commons.git $SCRIPT_DIR/.src/agent-commons" >&2
  return 1
}

image_exists_locally() {
  docker image inspect "$AGENT_COMMONS_IMAGE" &>/dev/null
}

use_registry_pull() {
  [ "${AGENT_COMMONS_PULL:-0}" = "1" ] && [[ "$AGENT_COMMONS_IMAGE" == */*:* ]]
}

do_build() {
  local src_dir
  src_dir="$(resolve_source_dir)"
  docker_native_build "$AGENT_COMMONS_IMAGE" "$src_dir" "$@"
}

ensure_image() {
  if use_registry_pull; then
    echo "[INFO] Pulling registry image $AGENT_COMMONS_IMAGE"
    run_compose pull
    return 0
  fi
  if image_exists_locally; then
    echo "[INFO] Using local image $AGENT_COMMONS_IMAGE"
    return 0
  fi
  echo "[INFO] Image $AGENT_COMMONS_IMAGE not found; building for this host"
  do_build
}

do_backup() {
  stamp=$(date +%Y%m%d-%H%M%S)
  archive="$BACKUP_DIR/${APP_NAME}-${stamp}.tgz"
  echo "[INFO] Backing up $APP_ROOT to $archive"
  tar -czf "$archive" -C "${DOCKER_DL}" "$APP_NAME"
  echo "[INFO] Done. Size: $(du -h "$archive" | cut -f1)"
}

do_update() {
  if use_registry_pull; then
    echo "[INFO] Pulling latest images (not starting app; use up or restart to start)"
    run_compose pull
    return 0
  fi
  local src_dir
  src_dir="$(resolve_source_dir)"
  if [ -d "$src_dir/.git" ]; then
    echo "[INFO] git pull in $src_dir"
    git -C "$src_dir" pull --ff-only
  fi
  echo "[INFO] Rebuilding $AGENT_COMMONS_IMAGE for $(docker_native_platform)"
  do_build
}

do_verify() {
  echo "[INFO] Health check http://127.0.0.1:8765/api/v1/health (requires published port or docker exec)"
  if run_compose exec -T agent-commons curl -sf http://127.0.0.1:8765/api/v1/health; then
    echo "[INFO] OK"
  else
    echo "[ERROR] Health check failed" >&2
    return 1
  fi
}

do_up() {
  ensure_image
  run_compose up -d
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    build)
      do_build
      ;;
    rebuild)
      do_build --no-cache
      run_compose up -d --force-recreate
      ;;
    backup)
      screen -S "backup-${SCREEN_APP}-$(date +%Y%m%d-%H%M%S)" -dm "$0" _backup
      echo "[INFO] Backup running in screen; attach with: screen -r"
      ;;
    _backup)
      do_backup
      ;;
    update)
      screen -S "update-${SCREEN_APP}-$(date +%Y%m%d-%H%M%S)" -dm "$0" _update
      echo "[INFO] Update running in screen; use up/restart when done. Attach: screen -r"
      ;;
    _update)
      do_update
      ;;
    refresh)
      echo "[INFO] Update sources/images and start"
      do_update
      do_up
      ;;
    up)
      do_up
      ;;
    down)
      run_compose down
      ;;
    restart)
      run_compose down
      do_up
      ;;
    verify)
      do_verify
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
  echo "  Switches can be combined, e.g. down backup up" >&2
  echo "" >&2
  echo "  build    - Build image for this host CPU ($(docker_native_platform 2>/dev/null || echo '?'))" >&2
  echo "  rebuild  - build --no-cache + force-recreate containers" >&2
  echo "  backup   - Create tgz of $APP_ROOT under $BACKUP_DIR (screen)" >&2
  echo "  update   - git pull (if src repo) + rebuild, or registry pull if AGENT_COMMONS_PULL=1" >&2
  echo "  refresh  - update + up" >&2
  echo "  up       - ensure image + start containers" >&2
  echo "  down     - Stop containers" >&2
  echo "  restart  - Down then up (rebuild image if missing)" >&2
  echo "  verify   - curl health inside container" >&2
  echo "  logs     - Follow logs" >&2
  echo "" >&2
  echo "  IMAGE: $AGENT_COMMONS_IMAGE  APP_ROOT: $APP_ROOT" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "Usage: $0 build|rebuild|backup|update|refresh|up|down|restart|verify|logs [ ... ]" >&2
    exit 1
  fi
done
