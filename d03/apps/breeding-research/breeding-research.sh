#!/bin/bash
# breeding-research on d03. Usage: breeding-research.sh [build|backup|restore|update|refresh|up|down|restart|verify|logs]
# Image: gitea.asyla.org/personal/breeding-research:latest (its CI publishes it from main and
# rebuilds it weekly). up and restart pull it only when it is not on this host, so a running app
# never moves to a new image by itself (host-maintenance's rollback re-tags the old image, then runs
# up); update and refresh pull. BREEDING_RESEARCH_PULL_OVERRIDE=0: a local build from source instead.
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
# shellcheck source=/dev/null
. "$HOME/scripts/docker/backup_lib.sh"
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
BACKUP_DIR="$DOCKER_D1/$APP_NAME/mirror"
# The script owns the image choice (asyla backlog 2026-11-03-hosts-apps-follow-latest-redeployed-weekly):
# the registry's `latest`, pulled; by hand, BREEDING_RESEARCH_IMAGE_OVERRIDE=<ref> pins another, and
# BREEDING_RESEARCH_PULL_OVERRIDE=0 builds from source (breeding-research:local unless an image
# override is given). The .env's BREEDING_RESEARCH_IMAGE and BREEDING_RESEARCH_PULL (from GitLab
# variable D03_BREEDING_RESEARCH_ENV) are no longer read.
REGISTRY_IMAGE="gitea.asyla.org/personal/breeding-research:latest"
LOCAL_IMAGE="breeding-research:local"
BREEDING_RESEARCH_PULL="${BREEDING_RESEARCH_PULL_OVERRIDE:-1}"
if [ "$BREEDING_RESEARCH_PULL" = 1 ]; then
  BREEDING_RESEARCH_IMAGE="${BREEDING_RESEARCH_IMAGE_OVERRIDE:-$REGISTRY_IMAGE}"
else
  BREEDING_RESEARCH_IMAGE="${BREEDING_RESEARCH_IMAGE_OVERRIDE:-$LOCAL_IMAGE}"
fi

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
  d="$SCRIPT_DIR/.src/breeding-research"
  if [ -f "$d/Dockerfile" ]; then
    printf '%s' "$d"
    return 0
  fi
  echo "[ERROR] breeding-research source not found. Set BREEDING_RESEARCH_SRC or clone https://gitea.asyla.org/personal/breeding-research.git to $d" >&2
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
  src="$(resolve_source_dir)" || return
  docker_native_build "$BREEDING_RESEARCH_IMAGE" "$src" "$@"
}

# up and restart: pull only when the image is not on this host (update and refresh pull a newer one).
ensure_image() {
  if use_registry_pull; then
    if image_exists_locally; then
      echo "[INFO] Using $BREEDING_RESEARCH_IMAGE on this host (update or refresh pulls a newer one)"
      return 0
    fi
    echo "[INFO] Pulling $BREEDING_RESEARCH_IMAGE (not on this host)"
    run_compose pull
    return
  fi
  if image_exists_locally; then
    echo "[INFO] Using local image $BREEDING_RESEARCH_IMAGE"
    return 0
  fi
  echo "[INFO] Building $BREEDING_RESEARCH_IMAGE for this host"
  do_build
}

do_backup() {
  do_rsync_mirror_backup "$APP_ROOT" "$BACKUP_DIR"
}

do_update() {
  if use_registry_pull; then
    echo "[INFO] Pulling $BREEDING_RESEARCH_IMAGE"
    run_compose pull
    return
  fi
  local src
  src="$(resolve_source_dir)" || return
  if [ -d "$src/.git" ]; then
    git -C "$src" pull --ff-only || return
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
  ensure_image || return
  run_compose up -d
}

# Every step checks the one before it: run_cmd runs under `||`, where bash ignores set -e.
run_cmd() {
  case "$1" in
    build) do_build ;;
    rebuild) do_build --no-cache && run_compose up -d --force-recreate ;;
    backup) run_detached_if_interactive backup do_backup ;;
    _backup) do_backup ;;
    # Rebuilt host only: refuses unless APP_ROOT is empty and the mirror's last backup is OK.
    restore) do_rsync_mirror_restore "$BACKUP_DIR" "$APP_ROOT" ;;
    update) run_detached_if_interactive update do_update ;;
    _update) do_update ;;
    refresh) do_update && do_up ;;
    up) do_up ;;
    down) run_compose down ;;
    restart) run_compose down && do_up ;;
    verify) do_verify ;;
    logs) run_compose logs -f ;;
    *) echo "[ERROR] Unknown: $1" >&2; usage; return 2 ;;
  esac
}

usage() {
  echo "Usage: $0 build|rebuild|backup|restore|update|refresh|up|down|restart|verify|logs ..." >&2
}

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

# A switch that fails exits with its own status (an unknown one: 2, after the usage).
for cmd in "$@"; do
  rc=0
  run_cmd "$cmd" || rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
done
