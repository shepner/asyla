# shellcheck shell=bash
# Shared helpers for per-host internal-access (Docker / Caddy).

load_host_env() {
  local script_dir="$1"
  if [ ! -f "$script_dir/host.env" ]; then
    echo "[ERROR] Missing host.env in $script_dir (deploy with scripts/deploy-host.sh)" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  . "$script_dir/host.env"
}

load_common_docker_env() {
  if [ -n "${ASYLA_COMMON_ENV:-}" ] && [ -f "$ASYLA_COMMON_ENV" ]; then
    # shellcheck source=/dev/null
    . "$ASYLA_COMMON_ENV"
  elif [ -f "$HOME/scripts/docker/common.env" ]; then
    # shellcheck source=/dev/null
    . "$HOME/scripts/docker/common.env"
  fi
  DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
  DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"
  export DOCKER_DL DOCKER_D1
  DATA_DIR="${DATA_DIR:-${DOCKER_DL}/internal-proxy}"
  export DATA_DIR
}

migrate_secrets() {
  local script_dir="$1"
  mkdir -p "$DATA_DIR/caddy-data" "$DATA_DIR/caddy-config"
  if [ -f "$script_dir/.env" ] && [ ! -f "$DATA_DIR/.env" ]; then
    echo "[INFO] Migrating .env -> $DATA_DIR/"
    mv "$script_dir/.env" "$DATA_DIR/.env"
  elif [ -f "$script_dir/.env" ] && [ -f "$DATA_DIR/.env" ]; then
    echo "[WARN] .env exists in both script dir and DATA_DIR; keeping DATA_DIR copy, removing script dir copy"
    rm "$script_dir/.env"
  fi
  if [ -d "$script_dir/certs" ] && [ "$(ls -A "$script_dir/certs" 2>/dev/null)" ]; then
    if [ ! -d "$DATA_DIR/certs" ] || [ -z "$(ls -A "$DATA_DIR/certs" 2>/dev/null)" ]; then
      echo "[INFO] Migrating certs/ -> $DATA_DIR/certs/"
      mkdir -p "$DATA_DIR/certs"
      cp -r "$script_dir/certs/." "$DATA_DIR/certs/"
    else
      echo "[WARN] certs exist in both locations; keeping DATA_DIR copy"
    fi
  fi
}

ensure_networks_from_file() {
  local networks_file="$1"
  [ -f "$networks_file" ] || return 0
  while IFS= read -r net || [ -n "$net" ]; do
    net="${net%%#*}"
    net="$(echo "$net" | xargs)"
    [ -z "$net" ] && continue
    docker network create "$net" 2>/dev/null || true
  done <"$networks_file"
}

run_compose() {
  local compose_file="$1"
  shift
  local env_args=""
  [ -f "$DATA_DIR/.env" ] && env_args="--env-file $DATA_DIR/.env"
  # shellcheck disable=SC2086
  docker compose -f "$compose_file" $env_args "$@"
}

do_backup_tgz() {
  local script_dir="$1"
  local archive_root="${BACKUP_ARCHIVE_ROOT:-${DOCKER_D1}}"
  local prefix="${BACKUP_ARCHIVE_PREFIX:-internal-proxy-${ASYLA_HOST_ID}}"
  local stamp archive
  stamp=$(date +%Y%m%d-%H%M%S)
  archive="${archive_root}/${prefix}-backup-${stamp}.tgz"
  echo "[INFO] Backing up $script_dir to $archive"
  mkdir -p "$(dirname "$archive")"
  tar -czf "$archive" -C "$script_dir" . 2>/dev/null || true
  echo "[INFO] Done. Size: $(du -h "$archive" 2>/dev/null | cut -f1)"
}

do_backup_rsync() {
  local backup_root="$1"
  local keep="${BACKUP_KEEP:-14}"
  if [ -f "$HOME/scripts/docker/backup_lib.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOME/scripts/docker/backup_lib.sh"
    do_rsync_snapshot_backup \
      "$DATA_DIR" \
      "$backup_root" \
      "$keep" \
      -- \
      --exclude="caddy-data/locks/" \
      --exclude="caddy-config/"
  else
    echo "[WARN] backup_lib.sh not found; falling back to tgz backup of DATA_DIR"
    do_backup_tgz "$DATA_DIR"
  fi
}
