#!/bin/bash
# Internal Caddy proxy on a Docker host (d01 / d02 / d03).
# Deployed to ~/scripts/<host>/apps/internal-access/ via scripts/deploy-host.sh
#
# Usage (on host): ./internal-access.sh up|down|restart|verify|backup|...
# From workstation: ./scripts/fleet.sh --host d01 restart

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

load_host_env "$SCRIPT_DIR" || exit 1
load_common_docker_env

COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
NETWORKS_FILE="${SCRIPT_DIR}/networks.txt"
SCREEN_APP="${INTERNAL_PROXY_SCREEN_APP:-internal-access-${ASYLA_HOST_ID}}"

prepare() {
  migrate_secrets "$SCRIPT_DIR"
  ensure_networks_from_file "$NETWORKS_FILE"
  if [ ! -f "$DATA_DIR/.env" ]; then
    echo "[WARN] $DATA_DIR/.env not found — CF_API_TOKEN unset; TLS renewal may fail"
  fi
}

do_backup() {
  case "${BACKUP_MODE:-rsync}" in
    rsync)
      do_backup_rsync "${BACKUP_RSYNC_ROOT:-${DOCKER_D1}/internal-proxy-${ASYLA_HOST_ID}}"
      ;;
    tgz|*)
      do_backup_tgz "$SCRIPT_DIR"
      ;;
  esac
}

do_update() {
  echo "[INFO] Pulling latest images (not starting; use up or restart after)"
  run_compose "$COMPOSE_FILE" pull
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)
      if [ "${BACKUP_USE_SCREEN:-false}" = true ]; then
        screen -S "backup-${SCREEN_APP}-$(date +%Y%m%d-%H%M%S)" -dm "$0" _backup
        echo "[INFO] Backup running in screen; attach: screen -r"
      else
        do_backup
      fi
      ;;
    _backup)
      do_backup
      ;;
    start|up)
      prepare
      echo "[INFO] Starting internal-access on ${ASYLA_HOST_ID}"
      run_compose "$COMPOSE_FILE" up -d
      ;;
    stop|down)
      run_compose "$COMPOSE_FILE" down
      ;;
    rebuild)
      prepare
      run_compose "$COMPOSE_FILE" pull
      run_compose "$COMPOSE_FILE" up -d --force-recreate
      echo "[INFO] Rebuild complete"
      ;;
    restart)
      run_compose "$COMPOSE_FILE" down
      prepare
      run_compose "$COMPOSE_FILE" up -d
      echo "[INFO] Restarted; Caddy loaded current Caddyfile"
      ;;
    refresh)
      prepare
      run_compose "$COMPOSE_FILE" pull
      run_compose "$COMPOSE_FILE" up -d
      ;;
    update)
      if [ "${BACKUP_USE_SCREEN:-false}" = true ]; then
        screen -S "update-${SCREEN_APP}-$(date +%Y%m%d-%H%M%S)" -dm "$0" _update
        echo "[INFO] Update running in screen; use up/restart when done"
      else
        do_update
      fi
      ;;
    _update)
      do_update
      ;;
    verify)
      "$SCRIPT_DIR/lib/verify.sh"
      ;;
    logs)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

if [ $# -eq 0 ]; then
  echo "Usage: $0 [switch ...]  (host: ${ASYLA_HOST_ID:-unknown})" >&2
  echo "  start|stop|rebuild|backup|up|down|restart|verify|refresh|update|logs" >&2
  echo "  DATA_DIR: ${DATA_DIR:-<unset>}" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose "$COMPOSE_FILE" logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "Usage: $0 start|stop|rebuild|verify|backup|up|down|restart|logs|refresh|update [ ... ]" >&2
    exit 1
  fi
done
