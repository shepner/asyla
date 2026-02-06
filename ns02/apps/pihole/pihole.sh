#!/bin/bash
# Pi-hole DNS server on ns02. Usage: pihole.sh up|down|logs|pull
# Run from anywhere; loads ~/scripts/docker/common.env for DOCKER_DL, etc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D2="${DOCKER_D2:-/mnt/nas/data2/docker}"

export DOCKER_DL
export DOCKER_D2
export LOCAL_TZ

# Standalone app: own project dir and project name
APP_ROOT="${DOCKER_DL}/pihole-ns02"

run_compose() {
  docker compose -p pihole-ns02 -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

remove_stale_container() {
  docker rm -f pihole-ns02 2>/dev/null || true
}

cmd="${1:-}"

case "$cmd" in
  up)
    echo "[INFO] Creating app dirs if needed"
    mkdir -p "${APP_ROOT}/etc-pihole"
    mkdir -p "${APP_ROOT}/etc-dnsmasq.d"
    # Copy custom dnsmasq config if it exists
    if [ -f "${DOCKER_D2}/pihole/03-lan-dns.conf" ]; then
      echo "[INFO] Copying custom dnsmasq config"
      sudo cp "${DOCKER_D2}/pihole/03-lan-dns.conf" "${APP_ROOT}/etc-dnsmasq.d/" || cp "${DOCKER_D2}/pihole/03-lan-dns.conf" "${APP_ROOT}/etc-dnsmasq.d/"
    fi
    remove_stale_container
    echo "[INFO] Starting Pi-hole"
    run_compose up -d
    ;;
  down)
    run_compose down
    remove_stale_container
    ;;
  logs)
    run_compose logs -f "${@:2}"
    ;;
  pull)
    run_compose pull
    remove_stale_container
    run_compose up -d
    ;;
  *)
    echo "Usage: $0 up|down|logs|pull" >&2
    echo "  up   - start Pi-hole (access via http://10.0.0.11/admin or http://pi.hole/admin)" >&2
    echo "  down - stop and remove container" >&2
    echo "  logs - follow logs" >&2
    echo "  pull - pull image and up" >&2
    exit 1
    ;;
esac
