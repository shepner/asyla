#!/bin/bash
# TC_datalogger on d03: backup, update, refresh, rebuild, up.
# Working files live under /mnt/docker/TC_datalogger; backups go to /mnt/nas/data1/docker (tgz).
# Usage: tc_datalogger.sh backup|update|refresh|rebuild|up
# Run from anywhere; loads ~/scripts/docker/common.env for DOCKER_DL and DOCKER_D1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi

APP_NAME="TC_datalogger"
APP_ROOT="${DOCKER_DL:?}/$APP_NAME"
REPO_DIR="$APP_ROOT/repo"
BACKUP_DIR="${DOCKER_D1:?}"  # tgz under NFS

export DOCKER_DL
export DOCKER_D1
export LOCAL_TZ

cmd="${1:-}"

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

case "$cmd" in
  backup)
    # Backup working dirs (config + logs) to tgz; exclude repo (re-pull on restore)
    stamp=$(date +%Y%m%d-%H%M%S)
    archive="$BACKUP_DIR/${APP_NAME}-${stamp}.tgz"
    echo "[INFO] Backing up $APP_ROOT to $archive (excluding repo)"
    tar -czf "$archive" -C "${DOCKER_DL}" --exclude="$APP_NAME/repo" "$APP_NAME"
    echo "[INFO] Done. Size: $(du -h "$archive" | cut -f1)"
    ;;
  update)
    # Pull latest from app repo, rebuild images, bring up
    echo "[INFO] Pulling latest from app repo"
    git -C "$REPO_DIR" pull
    echo "[INFO] Rebuilding and starting"
    run_compose build --pull
    run_compose up -d
    ;;
  refresh)
    # Rebuild and restart (no git pull)
    echo "[INFO] Rebuilding and starting"
    run_compose up -d --build
    ;;
  rebuild)
    # Full rebuild (no cache) and start
    echo "[INFO] Full rebuild (no cache) and start"
    run_compose build --no-cache
    run_compose up -d
    ;;
  up)
    # Start (build if needed)
    run_compose up -d --build
    ;;
  down)
    run_compose down
    ;;
  logs)
    run_compose logs -f "${@:2}"
    ;;
  *)
    echo "Usage: $0 backup|update|refresh|rebuild|up|down|logs [service...]" >&2
    echo "  backup   - tgz of $APP_ROOT (excl. repo) to $BACKUP_DIR" >&2
    echo "  update   - git pull in repo, build, up" >&2
    echo "  refresh  - build and up (no pull)" >&2
    echo "  rebuild  - build --no-cache and up" >&2
    echo "  up       - build if needed and start" >&2
    echo "  down     - stop and remove containers" >&2
    echo "  logs     - follow logs (optionally for one service)" >&2
    exit 1
    ;;
esac
