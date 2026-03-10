#!/bin/bash
# Internal Caddy proxy for d01 (split-DNS).
# Usage: internal-proxy.sh [switch ...] e.g. backup|up|down|restart|logs|refresh|update
# Switches can be combined (e.g. down backup up). Use 'restart' after update_scripts.sh so Caddy reloads the Caddyfile.
# Run from anywhere.
#
# Secrets/local state live in DATA_DIR (/mnt/docker/internal-proxy), NOT in ~/scripts/.
# On up/restart, the script auto-migrates any .env found in the script dir to DATA_DIR
# and ensures Caddy's TLS data directories exist before the container starts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
SCREEN_APP="internal-proxy-d01"

[ -f "$HOME/scripts/docker/common.env" ] && . "$HOME/scripts/docker/common.env"
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"
export DOCKER_DL

DATA_DIR="${DOCKER_DL}/internal-proxy"
export DATA_DIR

COMPOSE_FILE="docker-compose.yml"

# ---------------------------------------------------------------------------
# Migrate any secrets still in the script dir to DATA_DIR
# ---------------------------------------------------------------------------
migrate_secrets() {
  mkdir -p "$DATA_DIR/caddy-data" "$DATA_DIR/caddy-config"
  if [ -f "$SCRIPT_DIR/.env" ] && [ ! -f "$DATA_DIR/.env" ]; then
    echo "[INFO] Migrating .env -> $DATA_DIR/"
    mv "$SCRIPT_DIR/.env" "$DATA_DIR/.env"
  elif [ -f "$SCRIPT_DIR/.env" ] && [ -f "$DATA_DIR/.env" ]; then
    echo "[WARN] .env exists in both script dir and DATA_DIR; keeping DATA_DIR copy, removing script dir copy"
    rm "$SCRIPT_DIR/.env"
  fi
  # Migrate legacy certs dir if it exists
  if [ -d "$SCRIPT_DIR/certs" ] && [ "$(ls -A "$SCRIPT_DIR/certs" 2>/dev/null)" ]; then
    if [ ! -d "$DATA_DIR/certs" ] || [ -z "$(ls -A "$DATA_DIR/certs" 2>/dev/null)" ]; then
      echo "[INFO] Migrating certs/ -> $DATA_DIR/certs/"
      mkdir -p "$DATA_DIR/certs"
      cp -r "$SCRIPT_DIR/certs/." "$DATA_DIR/certs/"
    else
      echo "[WARN] certs exist in both locations; keeping DATA_DIR copy"
    fi
  fi
}

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
  docker compose -f "$COMPOSE_FILE" $env_args "$@"
}

do_backup() {
  stamp=$(date +%Y%m%d-%H%M%S)
  archive="${DOCKER_D1}/internal-proxy-d01-backup-${stamp}.tgz"
  echo "[INFO] Backing up $DATA_DIR to $archive"
  mkdir -p "$(dirname "$archive")"
  tar -czf "$archive" -C "$DATA_DIR" . 2>/dev/null || true
  echo "[INFO] Done. Size: $(du -h "$archive" 2>/dev/null | cut -f1)"
}

do_update() {
  echo "[INFO] Pulling latest images (not starting app; use up or restart to start)"
  run_compose pull
}

prepare() {
  migrate_secrets
  ensure_networks
  if [ ! -f "$DATA_DIR/.env" ]; then
    echo "[WARN] $DATA_DIR/.env not found — CF_API_TOKEN will be unset and TLS cert renewal will fail"
    echo "[WARN] Run deploy.sh from your workstation to copy the .env into place"
  fi
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
      prepare
      echo "[INFO] Starting internal proxy"
      run_compose up -d
      ;;
    down)
      run_compose down
      ;;
    restart)
      run_compose down
      prepare
      run_compose up -d
      echo "[INFO] Restarted; Caddy loaded current Caddyfile"
      ;;
    refresh)
      prepare
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
  echo "  restart  - Down then up; use after update_scripts to reload Caddyfile" >&2
  echo "  down     - Stop and remove containers" >&2
  echo "  logs     - Follow logs (optionally for one service)" >&2
  echo "" >&2
  echo "  DATA_DIR: $DATA_DIR  (secrets: .env with CF_API_TOKEN; TLS data: caddy-data/)" >&2
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
