#!/bin/bash
# Plex on d02. Usage: plex.sh [switch ...] e.g. backup|up|down|refresh|restart|logs
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

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)  do_backup ;;
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
    backup|up|down|refresh|restart|logs) ;;
    *)
      echo "Usage: $0 backup|up|down|refresh|restart|logs [ ... ]" >&2
      exit 1
      ;;
  esac
done

for cmd in "$@"; do
  run_cmd "$cmd"
done
