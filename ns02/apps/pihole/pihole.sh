#!/bin/bash
# Pi-hole DNS server on ns02. Usage: pihole.sh up|down|logs|refresh|update
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
export DOCKER_UID
export DOCKER_GID

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
    # Ownership so container (PIHOLE_UID:PIHOLE_GID) can read/write DB and config
    PIHOLE_UID="${DOCKER_UID:-1003}"
    PIHOLE_GID="${DOCKER_GID:-1000}"
    if command -v sudo >/dev/null 2>&1; then
      sudo chown -R "${PIHOLE_UID}:${PIHOLE_GID}" "${APP_ROOT}/etc-pihole" "${APP_ROOT}/etc-dnsmasq.d" 2>/dev/null || true
    fi
    # Copy custom dnsmasq config if it exists
    if [ -f "${DOCKER_D2}/pihole/03-lan-dns.conf" ]; then
      echo "[INFO] Copying custom dnsmasq config"
      sudo cp "${DOCKER_D2}/pihole/03-lan-dns.conf" "${APP_ROOT}/etc-dnsmasq.d/" 2>/dev/null || cp "${DOCKER_D2}/pihole/03-lan-dns.conf" "${APP_ROOT}/etc-dnsmasq.d/"
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
  refresh)
    # Pull latest images + start
    echo "[INFO] Pulling latest images and starting"
    run_compose pull
    remove_stale_container
    run_compose up -d
    ;;
  update)
    # Pull latest images + start (same as refresh)
    echo "[INFO] Pulling latest images and starting"
    run_compose pull
    remove_stale_container
    run_compose up -d
    ;;
  *)
    echo "Usage: $0 up|down|logs|refresh|update" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  update   - Pull latest images + start" >&2
    echo "  refresh  - Pull latest images + start (same as update)" >&2
    echo "  up       - Start containers only (no pull; fails if images missing)" >&2
    echo "" >&2
    echo "  down     - Stop and remove containers" >&2
    echo "  logs     - Follow logs" >&2
    echo "" >&2
    echo "When to use:" >&2
    echo "  update   - After image updates or when you need latest images" >&2
    echo "  refresh  - Same as update" >&2
    echo "  up       - Just start already-pulled containers" >&2
    echo "" >&2
    echo "Access: http://10.0.0.11/admin or http://pi.hole/admin" >&2
    exit 1
    ;;
esac
