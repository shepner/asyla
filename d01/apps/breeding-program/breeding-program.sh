#!/bin/bash
# breeding-program on d01. Usage: breeding-program.sh [switch ...]
#   init     create app dirs, app.env (from app.env.example) and the session secret; never overwrites
#   check    confirm app.env and secrets are in place (mode 600) before starting
#   build    build breeding-program:local from ${APP_ROOT}/src (shipped by push-source.sh)
#   up|down|restart|logs|verify|backup
# Switches can be combined (e.g. build restart verify). Loads ~/scripts/docker/common.env.

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
DATA1="${DATA1:-/mnt/nas/data1}"
DOCKER_D1="${DOCKER_D1:-${DATA1}/docker}"
DOCKER_UID="${DOCKER_UID:-1003}"
DOCKER_GID="${DOCKER_GID:-1000}"
BREEDING_PROGRAM_IMAGE="${BREEDING_PROGRAM_IMAGE:-breeding-program:local}"
export DOCKER_DL DOCKER_UID DOCKER_GID LOCAL_TZ BREEDING_PROGRAM_IMAGE

APP_NAME="breeding-program"
APP_ROOT="${DOCKER_DL}/${APP_NAME}"
SECRETS="${APP_ROOT}/secrets"
SRC="${APP_ROOT}/src"
BACKUP_ROOT="${DOCKER_D1}/${APP_NAME}"
BACKUP_KEEP="${BACKUP_KEEP:-14}"
PUBLIC_URL="https://breeding-program.asyla.org"

run_compose() {
  docker compose -p "$APP_NAME" -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

do_init() {
  mkdir -p "$SECRETS"
  chmod 700 "$SECRETS"
  if [ ! -f "$APP_ROOT/app.env" ]; then
    install -m 600 "$SCRIPT_DIR/app.env.example" "$APP_ROOT/app.env"
    echo "[INFO] Created $APP_ROOT/app.env from the example; set CF_ACCESS_AUD before 'up'"
  fi
  if [ ! -f "$SECRETS/session-secret" ]; then
    (umask 077; python3 -c "import secrets; print(secrets.token_urlsafe(48))" >"$SECRETS/session-secret")
    echo "[INFO] Generated $SECRETS/session-secret"
  fi
  docker network create breeding_program_net >/dev/null 2>&1 || true
  do_check || true
}

do_check() {
  local ok=0 f mode
  for f in "$APP_ROOT/app.env" "$SECRETS/session-secret" "$SECRETS/gcp-sa.json"; do
    if [ ! -f "$f" ]; then
      echo "[ERROR] missing $f" >&2; ok=1; continue
    fi
    mode="$(stat -c %a "$f")"
    if [ "$mode" != "600" ]; then
      echo "[ERROR] $f is mode $mode; want 600" >&2; ok=1
    fi
  done
  if [ -f "$APP_ROOT/app.env" ] && ! grep -qE '^CF_ACCESS_AUD=[0-9a-f]{20,}' "$APP_ROOT/app.env"; then
    echo "[ERROR] CF_ACCESS_AUD is not set in $APP_ROOT/app.env" >&2; ok=1
  fi
  [ "$ok" -eq 0 ] && echo "[INFO] app.env and secrets OK"
  return "$ok"
}

do_build() {
  if [ ! -f "$SRC/Dockerfile" ]; then
    echo "[ERROR] no source at $SRC; run push-source.sh from a workstation first" >&2
    return 1
  fi
  local sha
  sha="$(cat "$SRC/.git-sha" 2>/dev/null || echo unknown)"
  echo "[INFO] Building $BREEDING_PROGRAM_IMAGE from $SRC (GIT_SHA=$sha)"
  docker build --build-arg "GIT_SHA=$sha" -t "$BREEDING_PROGRAM_IMAGE" "$@" "$SRC"
}

do_up() {
  do_check
  docker network create breeding_program_net >/dev/null 2>&1 || true
  if ! docker image inspect "$BREEDING_PROGRAM_IMAGE" >/dev/null 2>&1; then
    do_build
  fi
  run_compose up -d
  # cloudflared-d01 must share this network; connect live (its compose lists it for restarts).
  docker network connect breeding_program_net cloudflared-d01 2>/dev/null || true
}

do_verify() {
  local status code i
  # Right after a restart the app is still loading its data from BigQuery: wait up to 60 s before failing.
  for i in $(seq 1 30); do
    if docker exec "$APP_NAME" python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=4)" 2>/dev/null; then
      break
    fi
    if [ "$i" -eq 30 ]; then
      echo "[ERROR] in-container /healthz failed after 60 s" >&2; return 1
    fi
    sleep 2
  done
  echo "[INFO] in-container /healthz OK"
  status="$(docker inspect -f '{{.State.Health.Status}}' "$APP_NAME" 2>/dev/null || echo missing)"
  echo "[INFO] container health: $status"
  # Unauthenticated requests must be stopped by Cloudflare Access (redirect to the login page).
  code="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 "$PUBLIC_URL/" || true)"
  echo "[INFO] $PUBLIC_URL/ -> $code"
  case "$code" in
    30[27]\ *cloudflareaccess.com*) echo "[INFO] public URL is behind Cloudflare Access" ;;
    *) echo "[WARN] expected a redirect to cloudflareaccess.com (not live yet, or Access missing)" >&2 ;;
  esac
}

do_backup() {
  # Data lives in BigQuery; this keeps app.env and the secrets.
  do_rsync_snapshot_backup "$APP_ROOT" "$BACKUP_ROOT" "$BACKUP_KEEP"
}

run_cmd() {
  case "$1" in
    init) do_init ;;
    check) do_check ;;
    build) do_build ;;
    rebuild) do_build --no-cache ;;
    up) do_up ;;
    down) run_compose down ;;
    restart) run_compose down; do_up ;;
    verify) do_verify ;;
    backup) do_backup ;;
    logs) run_compose logs -f ;;
  esac
}

USAGE="init|check|build|rebuild|up|down|restart|verify|backup|logs"
if [ $# -eq 0 ]; then
  echo "Usage: $0 $USAGE" >&2
  exit 1
fi
for cmd in "$@"; do
  case "|$USAGE|" in
    *"|$cmd|"*) ;;
    *) echo "Unknown: $cmd (want $USAGE)" >&2; exit 1 ;;
  esac
done
# Plain calls (not inside || or if) so set -e stops at the first failure.
for cmd in "$@"; do
  run_cmd "$cmd"
done
