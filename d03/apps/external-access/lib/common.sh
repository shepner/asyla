# shellcheck shell=bash
# Shared helpers for per-host external-access (Docker / cloudflared).

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
  DATA_DIR="${DATA_DIR:-${DOCKER_DL}/cloudflared}"
  export DATA_DIR
}

migrate_secrets() {
  local script_dir="$1"
  mkdir -p "$DATA_DIR"
  for f in .env credentials.json config.yml; do
    if [ -f "$script_dir/$f" ] && [ ! -f "$DATA_DIR/$f" ]; then
      echo "[INFO] Migrating $f -> $DATA_DIR/"
      mv "$script_dir/$f" "$DATA_DIR/$f"
    elif [ -f "$script_dir/$f" ] && [ -f "$DATA_DIR/$f" ]; then
      echo "[WARN] $f exists in both script dir and DATA_DIR; keeping DATA_DIR copy, removing script dir copy"
      rm "$script_dir/$f"
    fi
  done
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

compose_config_override() {
  local script_dir="$1"
  if [ -f "$DATA_DIR/config.yml" ] && [ -f "$DATA_DIR/credentials.json" ]; then
    echo "-f ${script_dir}/docker-compose.config.yml"
  fi
}

run_compose() {
  local script_dir="$1"
  local compose_file="$2"
  shift 2
  local extra
  extra="$(compose_config_override "$script_dir")"
  local env_args=""
  [ -f "$DATA_DIR/.env" ] && env_args="--env-file $DATA_DIR/.env"
  # shellcheck disable=SC2086
  docker compose -f "$compose_file" $extra $env_args "$@"
}

ensure_tunnel_config() {
  local script_dir="$1"
  if [ -f "$DATA_DIR/credentials.json" ] && [ ! -f "$DATA_DIR/config.yml" ]; then
    if [ -f "$script_dir/apps.yml" ]; then
      echo "[INFO] credentials.json present; generating config.yml from apps.yml..."
      "$script_dir/lib/generate-config.sh" "$script_dir"
    else
      echo "[WARN] credentials.json without config.yml and no apps.yml to generate from"
    fi
  fi
}

tunnel_mode_label() {
  if [ -f "$DATA_DIR/config.yml" ] && [ -f "$DATA_DIR/credentials.json" ]; then
    echo "config-file ($DATA_DIR/config.yml)"
  else
    echo "token (TUNNEL_TOKEN from $DATA_DIR/.env or Cloudflare dashboard)"
  fi
}

do_backup_tgz() {
  local archive_root="${BACKUP_ARCHIVE_ROOT:-${DOCKER_D1}}"
  local prefix="${BACKUP_ARCHIVE_PREFIX:-cloudflared-${ASYLA_HOST_ID}}"
  local stamp archive
  stamp=$(date +%Y%m%d-%H%M%S)
  archive="${archive_root}/${prefix}-backup-${stamp}.tgz"
  echo "[INFO] Backing up $DATA_DIR to $archive"
  mkdir -p "$(dirname "$archive")"
  tar -czf "$archive" -C "$DATA_DIR" . 2>/dev/null || true
  echo "[INFO] Done. Size: $(du -h "$archive" 2>/dev/null | cut -f1)"
}

do_backup_rsync() {
  local backup_root="$1"
  local keep="${BACKUP_KEEP:-14}"
  if [ -f "$HOME/scripts/docker/backup_lib.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOME/scripts/docker/backup_lib.sh"
    do_rsync_snapshot_backup "$DATA_DIR" "$backup_root" "$keep"
  else
    do_backup_tgz
  fi
}
