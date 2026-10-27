#!/bin/bash
# Home Assistant on d01. Usage: home-assistant.sh [switch ...] e.g. backup|up|down|logs|refresh|update|restart|verify
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env.
# up also sets HA's proxy trust (http-trust-proxy.py, with HA stopped), so internal-access works
# without an admin promoting anything.
# The config folder holds the integration logins (asyla decisions/home-assistant-integration-logins.md):
# up keeps it mode 700, and the backup mirror leaves .storage out (HA's own encrypted backups carry it).
# up also installs the vendored custom integrations in custom_components/ (README, "Watts Home").

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
NET_SUBNET="172.31.240.0/24"   # HA trusts it as the proxy through http-trust-proxy.py; internal-access d01 networks.txt sets the same subnet
PROXY_NAME="homeassistant.asyla.org"

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

# configuration.yaml comes from this repo on every start. It has no http block: in 2026.10 HA
# imports http YAML only as a pending trial that reverts to the default after 5 minutes unless an
# admin promotes it (core homeassistant/components/http/config.py, AUTO_REVERT_DELAY), and there is
# no admin on a first start. trust_proxy writes the stable config instead.
install_config() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$APP_ROOT" "$CONFIG_DIR"
  install -m 600 "$SCRIPT_DIR/configuration.yaml" "$CONFIG_DIR/configuration.yaml"
  # The includes in configuration.yaml need these; HA writes the same defaults on a bare first start.
  [ -e "$CONFIG_DIR/automations.yaml" ] || install -m 600 /dev/null "$CONFIG_DIR/automations.yaml"
  [ -s "$CONFIG_DIR/automations.yaml" ] || printf '[]' > "$CONFIG_DIR/automations.yaml"
  [ -e "$CONFIG_DIR/scripts.yaml" ] || install -m 600 /dev/null "$CONFIG_DIR/scripts.yaml"
  [ -e "$CONFIG_DIR/scenes.yaml" ] || install -m 600 /dev/null "$CONFIG_DIR/scenes.yaml"
  mkdir -p "$CONFIG_DIR/themes"
  install_custom_components
}

# Each folder in ./custom_components (vendored at one reviewed commit, PIN.txt) is mirrored into
# config/custom_components/<name>: folders 700, files 600, files no longer shipped removed. Python's
# __pycache__ (written by HA as root) is left alone. Integrations not shipped here are not touched.
install_custom_components() {
  local src_root="$SCRIPT_DIR/custom_components" dest_root="$CONFIG_DIR/custom_components"
  local src name dest rel
  [ -d "$src_root" ] || return 0
  mkdir -p "$dest_root"
  chmod 700 "$dest_root"
  for src in "$src_root"/*/; do
    [ -d "$src" ] || continue
    src="${src%/}"
    name="${src##*/}"
    dest="$dest_root/$name"
    mkdir -p "$dest"
    while IFS= read -r rel; do
      mkdir -p "$dest/$rel"
      chmod 700 "$dest/$rel"
    done < <(cd "$src" && find . -type d)
    while IFS= read -r rel; do
      cmp -s "$src/$rel" "$dest/$rel" || install -m 600 "$src/$rel" "$dest/$rel"
      chmod 600 "$dest/$rel"
    done < <(cd "$src" && find . -type f)
    while IFS= read -r rel; do
      [ -e "$src/$rel" ] || rm -f "$dest/$rel"
    done < <(cd "$dest" && find . -name __pycache__ -prune -o -type f -print)
    echo "[INFO] custom integration $name: $(sed -n 's/^commit: *//p' "$src/PIN.txt" 2>/dev/null || echo unpinned)"
  done
}

# Write the proxy trust into the stable half of config/.storage/http, with HA stopped so it does not
# overwrite the file. Runs http-trust-proxy.py in the pinned image (its python3, no network); the
# script prints only set or unchanged. Nothing else under .storage is read or printed.
trust_proxy() {
  local image rc=0
  image=$(run_compose config --images | head -1)
  if [ -z "$image" ]; then
    echo "[ERROR] no image in $COMPOSE_FILE" >&2
    return 1
  fi
  echo "[INFO] Stopping Home Assistant to set the proxy trust ($NET_SUBNET)"
  run_compose stop 2>/dev/null || true
  remove_stale_container
  docker run --rm -i --network none -v "$CONFIG_DIR:/config" --entrypoint python3 "$image" \
    - "$NET_SUBNET" < "$SCRIPT_DIR/http-trust-proxy.py" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[ERROR] http-trust-proxy.py failed (exit $rc); HA's proxy trust is not set" >&2
  fi
  return "$rc"
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

# A store that exists gets the trust before the start. Without one (fresh install, or a restore
# without .storage), HA writes it on its first start: wait for it, set the trust, start again.
do_up() {
  local store="$CONFIG_DIR/.storage/http" had_store=0 waited=0
  install_config
  ensure_network
  if [ -e "$store" ]; then
    had_store=1
    trust_proxy
  fi
  remove_stale_container
  echo "[INFO] Starting Home Assistant"
  run_compose up -d
  [ "$had_store" -eq 1 ] && return 0
  echo "[INFO] Waiting up to 300 s for HA's first start to write its HTTP config"
  while [ ! -e "$store" ]; do
    if [ "$waited" -ge 300 ]; then
      echo "[ERROR] $store did not appear in 300 s; HA does not trust the proxy (run up again)" >&2
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  trust_proxy
  echo "[INFO] Starting Home Assistant"
  run_compose up -d
}

# Read-only checks: the container is healthy, the folder modes hold, and HA trusts the proxy (a
# request through internal-access gets 400 while it does not).
do_verify() {
  local rc=0 state mode code
  state=$(docker inspect -f '{{.State.Health.Status}}' home-assistant 2>/dev/null || echo missing)
  echo "[INFO] container health: $state"
  [ "$state" = healthy ] || rc=1
  for d in "$APP_ROOT" "$CONFIG_DIR"; do
    mode=$(stat -c %a "$d")
    echo "[INFO] $d mode $mode"
    [ "$mode" = 700 ] || rc=1
  done
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "$PROXY_NAME:443:127.0.0.1" "https://$PROXY_NAME/" || true)
  case "$code" in
    200|302) echo "[INFO] https://$PROXY_NAME/ -> $code through internal-access" ;;
    400)
      echo "[WARN] https://$PROXY_NAME/ -> 400: HA does not trust the proxy; run up again (README)"
      rc=1
      ;;
    *)
      echo "[WARN] https://$PROXY_NAME/ -> ${code:-no answer} through internal-access"
      rc=1
      ;;
  esac
  # The vendored integrations match this repo's copy (names of differing files only).
  for d in "$SCRIPT_DIR"/custom_components/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    if diff -rq -x __pycache__ "$d" "$CONFIG_DIR/custom_components/${d##*/}" >/dev/null 2>&1; then
      echo "[INFO] custom integration ${d##*/} matches the repo"
    else
      echo "[WARN] custom integration ${d##*/} differs from the repo or is missing; run up"
      rc=1
    fi
  done
  return "$rc"
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)  do_backup ;;
    # Rebuilt host only: refuses unless APP_ROOT is empty and the mirror's last backup is OK.
    # .storage is not in the mirror: run up, then restore HA's own backup from config/backups in
    # onboarding (README).
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
  echo "  up       - Install configuration.yaml and custom integrations, set the proxy trust, start" >&2
  echo "  down     - Stop and remove the container" >&2
  echo "  restart  - Down then up" >&2
  echo "  verify   - Health, folder modes, HA trusts the proxy, custom integrations match" >&2
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
