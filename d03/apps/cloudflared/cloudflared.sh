#!/bin/bash
# Cloudflare Tunnel (cloudflared) for d03.
# Usage: cloudflared.sh [switch ...] e.g. backup|up|down|restart|logs|refresh|update
# Switches can be combined (e.g. down backup up). Run from anywhere. .env (TUNNEL_TOKEN) in this directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
SCREEN_APP="cloudflared-d03"

[ -f "$HOME/scripts/docker/common.env" ] && . "$HOME/scripts/docker/common.env"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"

COMPOSE_FILE="docker-compose.yml"

ensure_networks() {
  docker network create tc_datalogger_net 2>/dev/null || true
}

run_compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

do_backup() {
  stamp=$(date +%Y%m%d-%H%M%S)
  archive="${DOCKER_D1}/cloudflared-d03-backup-${stamp}.tgz"
  echo "[INFO] Backing up cloudflared config (.env, config files) to $archive"
  mkdir -p "$(dirname "$archive")"
  tar -czf "$archive" -C "$SCRIPT_DIR" . 2>/dev/null || true
  echo "[INFO] Done. Size: $(du -h "$archive" 2>/dev/null | cut -f1)"
}

do_update() {
  echo "[INFO] Pulling latest images (not starting app; use up or restart to start)"
  run_compose pull
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)
      screen -S "backup-${SCREEN_APP}-$(date +%Y%m%d-%H%M%S)" -dm "$0" _backup
      echo "[INFO] Backup running in screen; attach with: screen -r"
      ;;
    _backup)
      do_backup
      ;;
    up)
      echo "[INFO] Ensuring networks exist..."
      ensure_networks
      echo "[INFO] Using token mode (.env TUNNEL_TOKEN)"
      run_compose up -d
      ;;
    down)
      run_compose down
      ;;
    restart)
      run_compose down
      ensure_networks
      run_compose up -d
      echo "[INFO] Restarted cloudflared"
      ;;
    refresh)
      echo "[INFO] Pulling latest images and starting"
      ensure_networks
      echo "[INFO] Using token mode (.env TUNNEL_TOKEN)"
      run_compose pull
      run_compose up -d
      ;;
    update)
      screen -S "update-${SCREEN_APP}-$(date +%Y%m%d-%H%M%S)" -dm "$0" _update
      echo "[INFO] Update running in screen; use 'up' or 'restart' to start when done. Attach: screen -r"
      ;;
    _update)
      do_update
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
  echo "  backup   - Create tgz of .env/config to NFS (runs in screen)" >&2
  echo "  update   - Pull latest images in screen; use up/restart to start" >&2
  echo "  refresh  - Pull latest images + start (inline)" >&2
  echo "  up       - Start containers only" >&2
  echo "  down     - Stop and remove containers" >&2
  echo "  restart  - Down then up (useful for reloading config)" >&2
  echo "  logs     - Follow logs (optionally for one service)" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "Usage: $0 backup|up|down|restart|logs|refresh|update [ ... ]" >&2
    exit 1
  fi
done
