#!/bin/bash
# breeding-research on d03. Usage: breeding-research.sh [build|backup|update|refresh|up|down|restart|verify|logs]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="breeding-research"
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
APP_NAME="breeding-research"
APP_ROOT="$DOCKER_DL/$APP_NAME"
BACKUP_DIR="$DOCKER_D1"
DEFAULT_IMAGE="breeding-research:local"
BREEDING_RESEARCH_IMAGE="${BREEDING_RESEARCH_IMAGE:-$DEFAULT_IMAGE}"

export DOCKER_DL DOCKER_D1 BREEDING_RESEARCH_IMAGE

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

resolve_source_dir() {
  local d
  if [ -n "${BREEDING_RESEARCH_SRC:-}" ] && [ -f "${BREEDING_RESEARCH_SRC}/Dockerfile" ]; then
    printf '%s' "$BREEDING_RESEARCH_SRC"
    return 0
  fi
  for d in \
    "$HOME/local/asyla/projects/breeding-research" \
    "$HOME/asyla/projects/breeding-research" \
    "$SCRIPT_DIR/.src/breeding-research"; do
    if [ -f "$d/Dockerfile" ]; then
      printf '%s' "$d"
      return 0
    fi
  done
  echo "[ERROR] breeding-research source not found. Set BREEDING_RESEARCH_SRC or clone to $SCRIPT_DIR/.src/breeding-research" >&2
  return 1
}

image_exists_locally() {
  docker image inspect "$BREEDING_RESEARCH_IMAGE" &>/dev/null
}

use_registry_pull() {
  [ "${BREEDING_RESEARCH_PULL:-0}" = "1" ] && [[ "$BREEDING_RESEARCH_IMAGE" == */*:* ]]
}

do_build() {
  local src
  src="$(resolve_source_dir)"
  docker_native_build "$BREEDING_RESEARCH_IMAGE" "$src" "$@"
}

ensure_image() {
  if use_registry_pull; then
    echo "[INFO] Pulling $BREEDING_RESEARCH_IMAGE"
    run_compose pull
    return 0
  fi
  if image_exists_locally; then
    echo "[INFO] Using local image $BREEDING_RESEARCH_IMAGE"
    return 0
  fi
  echo "[INFO] Building $BREEDING_RESEARCH_IMAGE for this host"
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
    run_compose pull
    return 0
  fi
  local src
  src="$(resolve_source_dir)"
  if [ -d "$src/.git" ]; then
    git -C "$src" pull --ff-only
  fi
  do_build
}

do_verify() {
  if curl -sf http://127.0.0.1:8080/healthz >/dev/null; then
    echo "[INFO] Local /healthz OK"
  else
    echo "[ERROR] Local /healthz failed" >&2
    return 1
  fi
  if curl -sfk -o /dev/null --max-time 20 https://breeding-research.asyla.org/healthz; then
    echo "[INFO] https://breeding-research.asyla.org/healthz OK"
  else
    echo "[ERROR] Public healthz failed" >&2
    return 1
  fi
}

do_up() {
  ensure_image
  run_compose up -d
}

run_cmd() {
  case "$1" in
    build) do_build ;;
    rebuild) do_build --no-cache; run_compose up -d --force-recreate ;;
    backup)
      screen -S "backup-${SCREEN_APP}-$(date +%Y%m%d-%H%M%S)" -dm "$0" _backup
      echo "[INFO] Backup in screen; attach: screen -r"
      ;;
    _backup) do_backup ;;
    update)
      screen -S "update-${SCREEN_APP}-$(date +%Y%m%d-%H%M%S)" -dm "$0" _update
      echo "[INFO] Update in screen"
      ;;
    _update) do_update ;;
    refresh) do_update; do_up ;;
    up) do_up ;;
    down) run_compose down ;;
    restart) run_compose down; do_up ;;
    verify) do_verify ;;
    logs) run_compose logs -f ;;
    *) return 1 ;;
  esac
}

if [ $# -eq 0 ]; then
  echo "Usage: $0 build|backup|update|refresh|up|down|restart|verify|logs" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  run_cmd "$cmd" || { echo "Unknown: $cmd" >&2; exit 1; }
done
