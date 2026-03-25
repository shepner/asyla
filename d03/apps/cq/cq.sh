#!/bin/bash
# Mozilla cq team store on d03 — team API + review UI.
# Usage: cq.sh [switch ...] e.g. up|down|restart|logs|pull|build
# Bootstraps: clones mozilla-ai/cq into ./upstream if missing; creates .env with CQ_JWT_SECRET if unset.
# Optional: CQ_UPSTREAM_REF (default 0.4.0), DOCKER_DL in ~/scripts/docker/common.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="cq"
CQ_UPSTREAM_URL="${CQ_UPSTREAM_URL:-https://github.com/mozilla-ai/cq.git}"
CQ_UPSTREAM_REF="${CQ_UPSTREAM_REF:-0.4.0}"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi

DOCKER_DL="${DOCKER_DL:-/mnt/docker}"

rand_hex_32() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 64
    echo
  fi
}

ensure_upstream() {
  local u="$SCRIPT_DIR/upstream"
  if [ -d "$u/team-api" ] && [ -d "$u/team-ui" ]; then
    return 0
  fi
  if [ -e "$u" ]; then
    echo "[ERROR] $u exists but is not a complete mozilla-ai/cq checkout (need team-api and team-ui)." >&2
    echo "  Remove it and re-run this script: rm -rf \"$u\"" >&2
    exit 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo "[ERROR] git is required to clone upstream. Install git or clone manually:" >&2
    echo "  git clone --depth 1 --branch \"$CQ_UPSTREAM_REF\" \"$CQ_UPSTREAM_URL\" \"$u\"" >&2
    exit 1
  fi
  echo "[INFO] Cloning mozilla-ai/cq (ref $CQ_UPSTREAM_REF) into $u ..."
  git clone --depth 1 --branch "$CQ_UPSTREAM_REF" "$CQ_UPSTREAM_URL" "$u"
}

# CQ_JWT_SECRET: shared secret the team API uses to sign JWTs (login sessions). Not your UI password.
# If missing or empty in .env, we generate one once and write .env (never printed).
ensure_cq_env() {
  local envf="$SCRIPT_DIR/.env"
  local ex="$SCRIPT_DIR/.env.example"
  if [ ! -f "$envf" ]; then
    if [ -f "$ex" ]; then
      cp "$ex" "$envf"
    else
      printf '# cq team API — auto-created by cq.sh\nCQ_JWT_SECRET=\n' >"$envf"
    fi
  fi
  local line val
  line=""
  if grep -qE '^CQ_JWT_SECRET=' "$envf" 2>/dev/null; then
    line="$(grep -E '^CQ_JWT_SECRET=' "$envf" | tail -n1)"
  fi
  val="${line#CQ_JWT_SECRET=}"
  val="${val//$'\r'/}"
  val="${val//\"/}"
  val="${val//\'/}"
  if [ -n "$val" ]; then
    return 0
  fi
  local secret
  secret="$(rand_hex_32 | tr -d '\n')"
  local tmp
  tmp="$(mktemp)"
  if grep -q '^CQ_JWT_SECRET=' "$envf"; then
    grep -v '^CQ_JWT_SECRET=' "$envf" >"$tmp" || true
  else
    cat "$envf" >"$tmp"
  fi
  printf 'CQ_JWT_SECRET=%s\n' "$secret" >>"$tmp"
  mv "$tmp" "$envf"
  echo "[INFO] Wrote CQ_JWT_SECRET in $envf (API JWT signing key; keep the file private). You do not paste this into clients." >&2
}

ensure_upstream
ensure_cq_env

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

do_pull_build() {
  echo "[INFO] Building cq images from ./upstream (no pre-published images on Docker Hub)."
  run_compose build --pull
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    pull)
      do_pull_build
      ;;
    build)
      do_pull_build
      ;;
    update)
      screen -S "update-${SCREEN_APP}-$(date +%Y%m%d-%H%M%S)" -dm "$0" _update
      echo "[INFO] Rebuild running in screen; attach: screen -r"
      ;;
    _update)
      do_pull_build
      ;;
    refresh)
      do_pull_build
      run_compose up -d
      ;;
    up)
      run_compose up -d
      ;;
    down)
      run_compose down
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
  echo "  pull|build   - Build images from ./upstream" >&2
  echo "  update       - Build in screen" >&2
  echo "  refresh      - Build + up -d" >&2
  echo "  up|down|restart|logs" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "Usage: $0 pull|build|update|refresh|up|down|restart|logs" >&2
    exit 1
  fi
done
