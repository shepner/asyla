#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/lib/common.sh"

load_host_env "$SCRIPT_DIR" || exit 1
load_common_docker_env

COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
LOG_WAIT="${VERIFY_TUNNEL_LOG_WAIT:-45}"

run_compose_local() {
  run_compose "$SCRIPT_DIR" "$COMPOSE_FILE" "$@"
}

echo "[verify:${ASYLA_HOST_ID}] Checking cloudflared container..."
if ! run_compose_local exec -T cloudflared cloudflared --version >/dev/null 2>&1; then
  echo "[verify:${ASYLA_HOST_ID}] FAIL: cloudflared not running" >&2
  run_compose_local ps -a >&2 || true
  exit 1
fi

echo "[verify:${ASYLA_HOST_ID}] Waiting up to ${LOG_WAIT}s for tunnel registration in logs..."
deadline=$((SECONDS + LOG_WAIT))
ok=0
while (( SECONDS < deadline )); do
  logs="$(run_compose_local logs --tail=120 cloudflared 2>/dev/null || true)"
  if echo "$logs" | grep -qiE 'registered tunnel connection|connection registered|Started tunnel|tunnel connection|connIndex.*Registered'; then
    ok=1
    break
  fi
  if echo "$logs" | grep -qiE 'fatal|failed to serve tunnel connection|invalid tunnel token|authentication failed'; then
    echo "[verify:${ASYLA_HOST_ID}] FAIL: fatal/auth error in logs" >&2
    echo "$logs" | tail -n 40 >&2
    exit 1
  fi
  sleep 2
done

if [ "$ok" -ne 1 ]; then
  echo "[verify:${ASYLA_HOST_ID}] FAIL: no tunnel registration in logs within ${LOG_WAIT}s" >&2
  run_compose_local logs --tail=80 cloudflared >&2 || true
  exit 1
fi

echo "[verify:${ASYLA_HOST_ID}] OK — cloudflared running; tunnel looks connected."
