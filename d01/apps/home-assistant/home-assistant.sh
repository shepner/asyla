#!/bin/bash
# Home Assistant on d01. Usage: home-assistant.sh [switch ...] e.g. backup|up|down|logs|refresh|update|restart|verify
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env.
# The config folder holds the integration logins (asyla decisions/home-assistant-integration-logins.md):
# up keeps it mode 700, and the backup mirror leaves .storage out (HA's own encrypted backups carry it).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
# shellcheck source=/dev/null
. "$HOME/scripts/docker/backup_lib.sh"

DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"

export DOCKER_DL
export DOCKER_D1
export LOCAL_TZ

APP_NAME="home-assistant"
APP_ROOT="${DOCKER_DL}/${APP_NAME}"
CONFIG_DIR="${APP_ROOT}/config"
BACKUP_DIR="${DOCKER_D1}/${APP_NAME}/mirror"
NET_NAME="home_assistant_net"
NET_SUBNET="172.31.240.0/24"   # http-first-start.yaml trusts this subnet; change both together

# Not in the mirror: .storage (integration logins and tokens, users, the access token theOrg
# scrapes with), the YAML secrets file, the recorder database (3 days of history, not the trend
# store) and logs. HA's encrypted backups in config/backups are mirrored and carry .storage.
BACKUP_EXCLUDES=(
  --exclude=/config/.storage/
  --exclude=/config/secrets.yaml
  --exclude="/config/home-assistant_v2.db*"
  --exclude="*.log"
  --exclude="*.log.*"
)

run_compose() {
  docker compose -p "$APP_NAME" -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

remove_stale_container() {
  docker rm -f home-assistant 2>/dev/null || true
}

ensure_network() {
  local subnet
  if ! docker network inspect "$NET_NAME" >/dev/null 2>&1; then
    docker network create --subnet "$NET_SUBNET" "$NET_NAME" >/dev/null
  fi
  subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NET_NAME")
  if [ "$subnet" != "$NET_SUBNET" ]; then
    echo "[ERROR] $NET_NAME has subnet $subnet, not $NET_SUBNET; HA would not trust the proxy" >&2
    return 1
  fi
}

# configuration.yaml comes from this repo on every start. The http block goes in only until HA has
# migrated it into .storage/http on its first start; after that HA ignores http YAML.
install_config() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$APP_ROOT" "$CONFIG_DIR"
  install -m 600 "$SCRIPT_DIR/configuration.yaml" "$CONFIG_DIR/configuration.yaml"
  if [ ! -e "$CONFIG_DIR/.storage/http" ]; then
    cat "$SCRIPT_DIR/http-first-start.yaml" >> "$CONFIG_DIR/configuration.yaml"
    echo "[INFO] First start: http proxy settings added for HA to migrate"
  fi
  # The includes in configuration.yaml need these; HA writes the same defaults on a bare first start.
  [ -e "$CONFIG_DIR/automations.yaml" ] || install -m 600 /dev/null "$CONFIG_DIR/automations.yaml"
  [ -s "$CONFIG_DIR/automations.yaml" ] || printf '[]' > "$CONFIG_DIR/automations.yaml"
  [ -e "$CONFIG_DIR/scripts.yaml" ] || install -m 600 /dev/null "$CONFIG_DIR/scripts.yaml"
  [ -e "$CONFIG_DIR/scenes.yaml" ] || install -m 600 /dev/null "$CONFIG_DIR/scenes.yaml"
  mkdir -p "$CONFIG_DIR/themes"
}

do_backup() {
  do_rsync_mirror_backup "$APP_ROOT" "$BACKUP_DIR" -- "${BACKUP_EXCLUDES[@]}"
}

do_update() {
  echo "[INFO] Pulling the pinned image (not starting app; use up or restart to start)"
  # Pull only. Never remove the container here: update_all.sh runs update and
  # does not start the app again, so removing it here took the app down.
  run_compose pull
}

do_up() {
  install_config
  ensure_network
  remove_stale_container
  echo "[INFO] Starting Home Assistant"
  run_compose up -d
}

# Read-only checks: the container is healthy, the folder modes hold, and the proxy settings landed.
do_verify() {
  local rc=0 state mode
  state=$(docker inspect -f '{{.State.Health.Status}}' home-assistant 2>/dev/null || echo missing)
  echo "[INFO] container health: $state"
  [ "$state" = healthy ] || rc=1
  for d in "$APP_ROOT" "$CONFIG_DIR"; do
    mode=$(stat -c %a "$d")
    echo "[INFO] $d mode $mode"
    [ "$mode" = 700 ] || rc=1
  done
  if [ -e "$CONFIG_DIR/.storage/http" ]; then
    echo "[INFO] .storage/http present (proxy settings migrated)"
  else
    echo "[WARN] .storage/http missing: HA has not migrated the http settings yet"
    rc=1
  fi
  return "$rc"
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)  do_backup ;;
    # Rebuilt host only: refuses unless APP_ROOT is empty and the mirror's last backup is OK.
    # .storage is not in the mirror: restore HA's own backup from config/backups in the UI (README).
    restore) do_rsync_mirror_restore "$BACKUP_DIR" "$APP_ROOT" ;;
    update)  do_update ;;
    up)      do_up ;;
    down)
      run_compose down
      remove_stale_container
      ;;
    logs)
      run_compose logs -f
      ;;
    refresh)
      echo "[INFO] Pulling the pinned image and starting"
      run_compose pull
      do_up
      ;;
    restart)
      run_compose down
      do_up
      ;;
    verify)  do_verify ;;
    *)
      return 1
      ;;
  esac
}

if [ $# -eq 0 ]; then
  echo "Usage: $0 [switch ...]" >&2
  echo "  Switches can be combined, e.g. down backup up" >&2
  echo "" >&2
  echo "  backup   - rsync mirror of $APP_ROOT to $BACKUP_DIR, without .storage (history: nas01 ZFS snapshots)" >&2
  echo "  restore  - rebuilt host: $BACKUP_DIR back to an empty $APP_ROOT" >&2
  echo "  update   - Pull the pinned image (no restart); use up/restart to start" >&2
  echo "  refresh  - Pull the pinned image + start" >&2
  echo "  up       - Install configuration.yaml, start the container" >&2
  echo "  down     - Stop and remove the container" >&2
  echo "  restart  - Down then up" >&2
  echo "  verify   - Health, folder modes, proxy settings migrated" >&2
  echo "  logs     - Follow logs" >&2
  echo "" >&2
  echo "Access: https://homeassistant.asyla.org via internal-access (no published ports)" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  case "$cmd" in
    backup|restore|update|up|down|logs|refresh|restart|verify) ;;
    *)
      echo "Usage: $0 backup|restore|up|down|logs|refresh|update|restart|verify [ ... ]" >&2
      exit 1
      ;;
  esac
done

for cmd in "$@"; do
  run_cmd "$cmd"
done
