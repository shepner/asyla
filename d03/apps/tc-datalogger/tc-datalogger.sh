#!/bin/bash
# tc-datalogger on d03. Usage: tc-datalogger.sh [up|down|restart|verify|pull|backup|logs|...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="tc-datalogger"

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
APP_NAME="tc-datalogger"
APP_ROOT="$DOCKER_DL/$APP_NAME"
export DOCKER_DL DOCKER_D1 TC_REGISTRY TC_IMAGE_TAG DASHBOARD_SECRET_KEY DASHBOARD_MODE LOCAL_TZ

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

do_backup() {
  stamp=$(date +%Y%m%d-%H%M%S)
  archive="$DOCKER_D1/${APP_NAME}-${stamp}.tgz"
  echo "[INFO] Backing up $APP_ROOT (excluding repo) to $archive"
  tar -czf "$archive" -C "${DOCKER_DL}" --exclude="$APP_NAME/repo" "$APP_NAME"
  echo "[INFO] Done: $(du -h "$archive" | cut -f1)"
}

do_verify() {
  curl -sf -o /dev/null http://127.0.0.1:8081/login || {
    echo "[ERROR] Local dashboard :8081 failed" >&2
    return 1
  }
  echo "[INFO] Local http://127.0.0.1:8081/login OK"
  if curl -sfk -o /dev/null --max-time 25 https://tc-datalogger.asyla.org/login; then
    echo "[INFO] https://tc-datalogger.asyla.org/login OK"
  else
    echo "[ERROR] Public URL failed" >&2
    return 1
  fi
}

run_cmd() {
  case "$1" in
    pull) run_compose pull ;;
    up) run_compose pull; run_compose up -d ;;
    down) run_compose down ;;
    restart) run_compose down; run_compose up -d ;;
    refresh) run_compose pull; run_compose up -d ;;
    verify) do_verify ;;
    backup)
      screen -S "backup-${SCREEN_APP}-$(date +%Y%m%d-%H%M%S)" -dm "$0" _backup
      echo "[INFO] Backup in screen"
      ;;
    _backup) do_backup ;;
    logs) run_compose logs -f ;;
    *) return 1 ;;
  esac
}

if [ $# -eq 0 ]; then
  echo "Usage: $0 pull|up|down|restart|verify|backup|logs" >&2
  exit 1
fi
[ "$1" = "logs" ] && { run_compose logs -f "${@:2}"; exit 0; }
for c in "$@"; do run_cmd "$c" || { echo "Unknown: $c" >&2; exit 1; }; done
