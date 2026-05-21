#!/bin/bash
# Plex on d02. Usage: plex.sh [switch ...] e.g. backup|up|down|refresh|restart|logs
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env.
# Config lives under ${DOCKER_DL}/plex/plexmediaserver.
# Backups: daily-friendly rsync snapshots with hardlinks, under ${DOCKER_D1}/plex/<stamp>/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"
DATA1="${DATA1:-/mnt/nas/data1}"

APP_NAME="plex"
APP_ROOT="$DOCKER_DL/$APP_NAME"
BACKUP_ROOT="$DOCKER_D1/$APP_NAME"
BACKUP_KEEP="${BACKUP_KEEP:-14}"  # number of snapshots to keep

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
  # Daily-friendly incremental snapshot of the Plex config tree.
  # - rsync with --link-dest hardlinks unchanged files from the previous snapshot,
  #   so each daily run only transfers what actually changed (typically megabytes).
  # - Plex's churny / regenerable dirs (Cache, Codecs, Logs, Crash Reports, Updates,
  #   Plug-in Support/Caches, etc.) are excluded — they rebuild themselves and are
  #   what made the old tgz backups hundreds of GB.
  # - Plex remains running during backup; SQLite is in WAL mode and tolerates this
  #   well enough for "good enough" daily snapshots. For a guaranteed-clean snapshot,
  #   run: plex.sh down backup up
  local stamp snapshot_dir latest_link tmp_link
  stamp=$(date +%Y%m%d-%H%M%S)
  snapshot_dir="$BACKUP_ROOT/$stamp"
  latest_link="$BACKUP_ROOT/latest"
  tmp_link="$BACKUP_ROOT/.latest.$$"

  mkdir -p "$BACKUP_ROOT"

  local link_dest_args=()
  if [ -L "$latest_link" ] && [ -d "$latest_link" ]; then
    link_dest_args=(--link-dest="$(readlink -f "$latest_link")")
    echo "[INFO] Incremental against previous snapshot: $(readlink "$latest_link")"
  else
    echo "[INFO] No previous snapshot found; first run will copy everything"
  fi

  # Plex churn / regenerable paths (relative to $APP_ROOT, i.e. /mnt/docker/plex/).
  local excludes=(
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Cache/"
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Codecs/"
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Crash Reports/"
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Diagnostics/"
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Logs/"
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Updates/"
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Caches/"
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Crash Reports/"
    --exclude="plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Logs/"
  )

  echo "[INFO] rsync $APP_ROOT/ -> $snapshot_dir/"
  rsync -aH --delete --stats --human-readable \
    "${excludes[@]}" \
    "${link_dest_args[@]}" \
    "$APP_ROOT/" "$snapshot_dir/"

  # Atomically update the 'latest' pointer (relative symlink for portability).
  ln -snr "$snapshot_dir" "$tmp_link"
  mv -T "$tmp_link" "$latest_link"

  # Retention: keep only the N newest snapshot directories.
  local removed=0
  local victim
  while IFS= read -r victim; do
    [ -n "$victim" ] || continue
    rm -rf "$victim" && removed=$((removed + 1))
  done < <(ls -1d "$BACKUP_ROOT"/20[0-9][0-9][0-1][0-9][0-3][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9] 2>/dev/null \
            | sort | head -n -"$BACKUP_KEEP")
  if [ "$removed" -gt 0 ]; then
    echo "[INFO] Pruned $removed snapshot(s) older than the most recent $BACKUP_KEEP"
  fi

  echo "[INFO] Backup complete: $snapshot_dir"
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)
      do_backup
      ;;
    up)
      run_compose up -d
      ;;
    down)
      run_compose down
      ;;
    refresh)
      echo "[INFO] Pulling latest images and starting"
      run_compose pull
      run_compose up -d
      ;;
    restart)
      run_compose down
      run_compose up -d
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
  echo "  backup   - rsync snapshot of $APP_ROOT to $BACKUP_ROOT/<stamp>/ (incremental, daily-friendly; keeps $BACKUP_KEEP snapshots)" >&2
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

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "Usage: $0 backup|up|down|refresh|restart|logs [ ... ]" >&2
    exit 1
  fi
done
