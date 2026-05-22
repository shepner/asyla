#!/bin/bash
# Cloudflare Tunnel (cloudflared) for d01.
# Usage: cloudflared.sh [switch ...] e.g. backup|up|down|restart|logs|refresh|update
# Switches can be combined (e.g. down backup up). Run from anywhere.
#
# Secrets/local state live in DATA_DIR (/mnt/docker/cloudflared), NOT in ~/scripts/.
# On up/restart, the script auto-migrates any secrets found in the script dir to DATA_DIR,
# and auto-generates config.yml if credentials.json is present but config.yml is not.
# Backups: daily-friendly rsync snapshots with hardlinks, under ${DOCKER_D1}/cloudflared-d01/<stamp>/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[ -f "$HOME/scripts/docker/common.env" ] && . "$HOME/scripts/docker/common.env"
# shellcheck source=/dev/null
. "$HOME/scripts/docker/backup_lib.sh"

DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"
export DOCKER_DL

DATA_DIR="${DOCKER_DL}/cloudflared"
export DATA_DIR

# Suffix dest with -d01 to avoid collision with the d02 cloudflared backup root.
BACKUP_ROOT="${DOCKER_D1}/cloudflared-d01"
BACKUP_KEEP="${BACKUP_KEEP:-14}"

COMPOSE_FILE="docker-compose.yml"

# ---------------------------------------------------------------------------
# Migrate any secrets that are still in the script dir to DATA_DIR
# ---------------------------------------------------------------------------
migrate_secrets() {
  mkdir -p "$DATA_DIR"
  local migrated=0
  for f in .env credentials.json config.yml; do
    if [ -f "$SCRIPT_DIR/$f" ] && [ ! -f "$DATA_DIR/$f" ]; then
      echo "[INFO] Migrating $f -> $DATA_DIR/"
      mv "$SCRIPT_DIR/$f" "$DATA_DIR/$f"
      migrated=1
    elif [ -f "$SCRIPT_DIR/$f" ] && [ -f "$DATA_DIR/$f" ]; then
      echo "[WARN] $f exists in both script dir and DATA_DIR; keeping DATA_DIR copy, removing script dir copy"
      rm "$SCRIPT_DIR/$f"
    fi
  done
  [ "$migrated" -eq 0 ] || echo "[INFO] Migration complete."
}

# ---------------------------------------------------------------------------
# Auto-generate config.yml from apps.yml if in config-file mode but config is missing
# ---------------------------------------------------------------------------
ensure_config() {
  if [ -f "$DATA_DIR/credentials.json" ] && [ ! -f "$DATA_DIR/config.yml" ]; then
    echo "[INFO] credentials.json found but config.yml missing; generating from apps.yml..."
    "$SCRIPT_DIR/generate-config.sh"
  fi
}

compose_mode() {
  if [ -f "$DATA_DIR/config.yml" ] && [ -f "$DATA_DIR/credentials.json" ]; then
    echo "-f docker-compose.config.yml"
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
  local extra
  extra="$(compose_mode)"
  local env_args=""
  [ -f "$DATA_DIR/.env" ] && env_args="--env-file $DATA_DIR/.env"
  # shellcheck disable=SC2086
  docker compose -f "$COMPOSE_FILE" $extra $env_args "$@"
}

do_backup() {
  # cloudflared state is tiny: .env, credentials.json, config.yml — back up
  # the whole DATA_DIR. Nothing churny to exclude.
  do_rsync_snapshot_backup \
    "$DATA_DIR" \
    "$BACKUP_ROOT" \
    "$BACKUP_KEEP"
}

do_update() {
  echo "[INFO] Pulling latest images (not starting app; use up or restart to start)"
  run_compose pull
}

prepare() {
  migrate_secrets
  [ -f "$DATA_DIR/.env" ] && . "$DATA_DIR/.env" || true
  ensure_config
  ensure_networks
  local mode
  if [ -f "$DATA_DIR/config.yml" ] && [ -f "$DATA_DIR/credentials.json" ]; then
    mode="config-file ($DATA_DIR/config.yml)"
  else
    mode="token (TUNNEL_TOKEN from $DATA_DIR/.env)"
  fi
  echo "[INFO] Mode: $mode"
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)  do_backup ;;
    update)  do_update ;;
    up)
      prepare
      run_compose up -d
      ;;
    down)
      run_compose down
      ;;
    restart)
      run_compose down
      prepare
      run_compose up -d
      ;;
    refresh)
      prepare
      run_compose pull
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
  echo "  backup   - rsync snapshot of $DATA_DIR to $BACKUP_ROOT/<stamp>/ (incremental; keeps $BACKUP_KEEP snapshots)" >&2
  echo "  update   - Pull latest images (no restart); use up/restart to start" >&2
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
  case "$cmd" in
    backup|update|up|down|restart|refresh|logs) ;;
    *)
      echo "Usage: $0 backup|up|down|restart|logs|refresh|update [ ... ]" >&2
      exit 1
      ;;
  esac
done

for cmd in "$@"; do
  run_cmd "$cmd"
done
