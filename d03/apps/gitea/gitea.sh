#!/bin/bash
# Gitea on d03. Usage: gitea.sh [switch ...] e.g. backup|update|refresh|up|down|restart|logs
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env.
# Data under /mnt/docker/Gitea; backups go to /mnt/nas/data1/docker (tgz).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="gitea"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
# shellcheck source=/dev/null
. "$HOME/scripts/docker/backup_lib.sh"
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"

APP_NAME="Gitea"
APP_ROOT="$DOCKER_DL/Gitea"
BACKUP_DIR="$DOCKER_D1"
# Newest archives kept in $BACKUP_DIR; older ones are deleted after a successful backup.
BACKUP_KEEP="${BACKUP_KEEP:-7}"

export DOCKER_DL
export DOCKER_D1
export LOCAL_TZ

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

do_backup() {
  do_tgz_backup "$DOCKER_DL" Gitea "$BACKUP_DIR" "$APP_NAME" "$BACKUP_KEEP"
}

do_update() {
  echo "[INFO] Pulling latest images (not starting app; use up or restart to start)"
  run_compose pull
}

do_verify() {
  echo "[INFO] Health check https://gitea.asyla.org/ (via proxy) and local :3000"
  if curl -sf -o /dev/null -w "%{http_code}" --max-time 15 http://127.0.0.1:3000/ | grep -qE '^(200|302)$'; then
    echo "[INFO] Local :3000 OK"
  else
    echo "[WARN] Local :3000 check failed (container may still be starting)" >&2
  fi
  if curl -sfk -o /dev/null -w "%{http_code}" --max-time 20 https://gitea.asyla.org/ | grep -qE '^(200|302)$'; then
    echo "[INFO] https://gitea.asyla.org OK"
  else
    echo "[ERROR] https://gitea.asyla.org check failed" >&2
    return 1
  fi
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)
      run_detached_if_interactive backup do_backup
      ;;
    _backup)
      do_backup
      ;;
    update)
      run_detached_if_interactive update do_update
      ;;
    _update)
      do_update
      ;;
    refresh)
      echo "[INFO] Pulling latest images and starting"
      run_compose pull
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
  echo "  backup   - Create tgz backup of $APP_ROOT in $BACKUP_DIR; keeps $BACKUP_KEEP (screen if interactive)" >&2
  echo "  update   - Pull latest images (screen if interactive); use up/restart to start" >&2
  echo "  refresh  - Pull latest images + start (inline)" >&2
  echo "  up       - Start containers only" >&2
  echo "  down     - Stop and remove containers" >&2
  echo "  restart  - Down then up" >&2
  echo "  verify   - curl local :3000 and https://gitea.asyla.org" >&2
  echo "  logs     - Follow logs (optionally for one service)" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "Usage: $0 backup|update|refresh|up|down|restart|verify|logs [ ... ]" >&2
    exit 1
  fi
done
