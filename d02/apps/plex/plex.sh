#!/bin/bash
# Plex on d02. Usage: plex.sh [switch ...] e.g. backup|restore|up|down|refresh|restart|verify|logs
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env.
# Config lives under ${DOCKER_DL}/plex/plexmediaserver.
# Backups: one rsync mirror at ${DOCKER_D1}/plex/mirror/; daily history is nas01's ZFS
# snapshots of data1/docker (see README).

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
DATA1="${DATA1:-/mnt/nas/data1}"

APP_NAME="plex"
APP_ROOT="$DOCKER_DL/$APP_NAME"
BACKUP_DIR="$DOCKER_D1/$APP_NAME/mirror"

export DOCKER_DL
export DOCKER_D1
export DATA1
export LOCAL_TZ
export DOCKER_UID
export DOCKER_GID
export MY_DOMAIN

mkdir -p "$APP_ROOT"

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$APP_ROOT" "$@"
}

do_backup() {
  # Mirror of the Plex config tree. The tree has ~826k entries (Media/ and
  # Metadata/ are ~400k each), which made the old hardlink-snapshot style take
  # ~23 h per run over NFS; a mirror only touches what changed.
  # Plex's churn / regenerable dirs are excluded — they rebuild themselves and
  # are what made the old tgz backups hundreds of GB. Plex remains running
  # during backup; SQLite is in WAL mode and tolerates this well enough for
  # "good enough" daily backups. For a guaranteed-clean copy run:
  #   plex.sh down backup up
  do_rsync_mirror_backup \
    "$APP_ROOT" \
    "$BACKUP_DIR" \
    -- \
    --exclude="plexmediaserver/.ssh/" \
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Cache/" \
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Codecs/" \
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Crash Reports/" \
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Diagnostics/" \
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Logs/" \
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Updates/" \
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Caches/" \
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Crash Reports/" \
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Logs/"
}

# The inverse of do_backup, for a rebuilt host (scripts/build_host.py restore phase). Refuses when
# the mirror's .backup-status is not OK or APP_ROOT already holds files (backup_lib.sh). The mirror
# holds none of the excluded dirs; Plex rebuilds them.
do_restore() {
  do_rsync_mirror_restore "$BACKUP_DIR" "$APP_ROOT"
}

# Plex answers on 32400 as the restored server: /identity is claimed and its machineIdentifier is
# the one in the restored Preferences.xml. Waits up to 3 minutes for Plex to start.
do_verify() {
  local prefs="$APP_ROOT/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"
  local want got i
  want=$(grep -o 'ProcessedMachineIdentifier="[^"]*"' "$prefs" | cut -d'"' -f2) || true
  if [ -z "$want" ]; then
    echo "[ERROR] verify: no ProcessedMachineIdentifier in $prefs" >&2
    return 1
  fi
  for i in $(seq 1 36); do
    got=$(curl -fsS --max-time 5 http://127.0.0.1:32400/identity 2>/dev/null) && break
    sleep 5
  done
  if ! printf '%s' "$got" | grep -q 'claimed="1"'; then
    echo "[ERROR] verify: Plex /identity on 127.0.0.1:32400 did not answer as a claimed server" >&2
    return 1
  fi
  if ! printf '%s' "$got" | grep -q "machineIdentifier=\"$want\""; then
    echo "[ERROR] verify: Plex answers with another machineIdentifier than Preferences.xml's" >&2
    return 1
  fi
  echo "[OK] Plex answers on 32400, claimed, as server ${want:0:6}..."
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)  do_backup ;;
    restore) do_restore ;;
    verify)  do_verify ;;
    up)      run_compose up -d ;;
    down)    run_compose down ;;
    refresh)
      echo "[INFO] Pulling latest images and starting"
      run_compose pull
      run_compose up -d
      ;;
    restart)
      run_compose down
      run_compose up -d
      ;;
    logs)    run_compose logs -f ;;
    *)       return 1 ;;
  esac
}

if [ $# -eq 0 ]; then
  echo "Usage: $0 [switch ...]" >&2
  echo "  Switches can be combined, e.g. down backup up" >&2
  echo "" >&2
  echo "  backup   - rsync mirror of $APP_ROOT to $BACKUP_DIR/ (history: NAS ZFS snapshots)" >&2
  echo "  restore  - copy $BACKUP_DIR/ back to an empty $APP_ROOT (rebuilt host; stop Plex first)" >&2
  echo "  verify   - Plex answers on 32400 as the restored server" >&2
  echo "  refresh  - Pull latest images + start" >&2
  echo "  up       - Start containers only" >&2
  echo "  down     - Stop and remove containers" >&2
  echo "  restart  - Down then up" >&2
  echo "  logs     - Follow logs (optionally for one service)" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

# Validate all commands up-front so set -e inside run_cmd / do_backup is honored
# during execution (the previous `if ! run_cmd` form silently swallowed errors).
for cmd in "$@"; do
  case "$cmd" in
    backup|restore|up|down|refresh|restart|verify|logs) ;;
    *)
      echo "Usage: $0 backup|restore|up|down|refresh|restart|verify|logs [ ... ]" >&2
      exit 1
      ;;
  esac
done

for cmd in "$@"; do
  run_cmd "$cmd"
done
