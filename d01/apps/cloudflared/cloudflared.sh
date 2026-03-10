#!/bin/bash
# Cloudflare Tunnel (cloudflared) for d01.
# Usage: cloudflared.sh [switch ...] e.g. backup|up|down|restart|logs|refresh|update
# Switches can be combined (e.g. down backup up). Run from anywhere.
#
# Secrets/local state live in DATA_DIR (/mnt/docker/cloudflared), NOT in ~/scripts/.
# This means update_scripts.sh never clobbers credentials.json, config.yml, or .env.
# Files that must be in DATA_DIR:
#   .env              - TUNNEL_TOKEN (token mode) or TUNNEL_ID + API creds (config/API mode)
#   credentials.json  - tunnel credentials (config-file mode only)
#   config.yml        - generated ingress config (config-file mode only; run generate-config.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
SCREEN_APP="cloudflared-d01"

[ -f "$HOME/scripts/docker/common.env" ] && . "$HOME/scripts/docker/common.env"
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"
export DOCKER_DL

DATA_DIR="${DOCKER_DL}/cloudflared"
export DATA_DIR

# Load local secrets (TUNNEL_TOKEN, TUNNEL_ID, etc.) from DATA_DIR
[ -f "$DATA_DIR/.env" ] && . "$DATA_DIR/.env"

COMPOSE_FILE="docker-compose.yml"
COMPOSE_EXTRA=""
if [ -f "$DATA_DIR/config.yml" ] && [ -f "$DATA_DIR/credentials.json" ]; then
  COMPOSE_EXTRA="-f docker-compose.config.yml"
fi

ensure_networks() {
  docker network create d01_internal 2>/dev/null || true
  docker network create media_net 2>/dev/null || true
  docker network create calibre_net 2>/dev/null || true
  docker network create homebridge_net 2>/dev/null || true
  docker network create duplicati_net 2>/dev/null || true
}

run_compose() {
  local env_args=""
  [ -f "$DATA_DIR/.env" ] && env_args="--env-file $DATA_DIR/.env"
  # shellcheck disable=SC2086
  docker compose -f "$COMPOSE_FILE" $COMPOSE_EXTRA $env_args "$@"
}

do_backup() {
  stamp=$(date +%Y%m%d-%H%M%S)
  archive="${DOCKER_D1}/cloudflared-d01-backup-${stamp}.tgz"
  echo "[INFO] Backing up cloudflared config (DATA_DIR + script dir) to $archive"
  mkdir -p "$(dirname "$archive")"
  tar -czf "$archive" -C "$DATA_DIR" . 2>/dev/null || true
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
      echo "[INFO] Ensuring networks and data dir exist..."
      mkdir -p "$DATA_DIR"
      ensure_networks
      if [ -n "$COMPOSE_EXTRA" ]; then
        echo "[INFO] Using config file mode ($DATA_DIR/config.yml + credentials.json)"
      else
        echo "[INFO] Using token mode (TUNNEL_TOKEN from $DATA_DIR/.env)"
      fi
      run_compose up -d
      ;;
    down)
      run_compose down
      ;;
    restart)
      run_compose down
      mkdir -p "$DATA_DIR"
      ensure_networks
      run_compose up -d
      ;;
    refresh)
      echo "[INFO] Pulling latest images and starting"
      mkdir -p "$DATA_DIR"
      ensure_networks
      if [ -n "$COMPOSE_EXTRA" ]; then
        echo "[INFO] Using config file mode ($DATA_DIR/config.yml + credentials.json)"
      else
        echo "[INFO] Using token mode (TUNNEL_TOKEN from $DATA_DIR/.env)"
      fi
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
  echo "  backup   - Create tgz of DATA_DIR to NFS (runs in screen)" >&2
  echo "  update   - Pull latest images in screen; use up/restart to start" >&2
  echo "  refresh  - Pull latest images + start (inline)" >&2
  echo "  up       - Start containers only" >&2
  echo "  down     - Stop and remove containers" >&2
  echo "  restart  - Down then up" >&2
  echo "  logs     - Follow logs (optionally for one service)" >&2
  echo "" >&2
  echo "  DATA_DIR: $DATA_DIR  (secrets: .env, credentials.json, config.yml)" >&2
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
