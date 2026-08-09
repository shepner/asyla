#!/usr/bin/env bash
# Verify internal-access on this Docker host (expects host.env in repo root = script dir parent).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/lib/common.sh"

load_host_env "$SCRIPT_DIR" || exit 1
load_common_docker_env

COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
HTTP_BIND="${INTERNAL_PROXY_HTTP_PORT:-80}"
VERIFY_MARKER="${VERIFY_HTTP_MARKER:-internal proxy ready}"

run_compose_local() {
  run_compose "$COMPOSE_FILE" "$@"
}

if [[ "$HTTP_BIND" == *:* ]]; then
  CURL_HOST="${HTTP_BIND%%:*}"
  CURL_PORT="${HTTP_BIND##*:}"
else
  CURL_HOST="127.0.0.1"
  CURL_PORT="$HTTP_BIND"
fi
[ -n "$CURL_PORT" ] || CURL_PORT="80"
[[ "$CURL_HOST" == "0.0.0.0" ]] && CURL_HOST="127.0.0.1"

echo "[verify:${ASYLA_HOST_ID}] Checking caddy-internal container..."
if ! run_compose_local exec -T caddy-internal caddy version >/dev/null 2>&1; then
  echo "[verify:${ASYLA_HOST_ID}] FAIL: caddy-internal not running" >&2
  run_compose_local ps -a >&2 || true
  exit 1
fi

echo "[verify:${ASYLA_HOST_ID}] HTTP GET http://${CURL_HOST}:${CURL_PORT}/ (expect marker in body)..."
body="$(curl -sfS --max-time "${VERIFY_HTTP_TIMEOUT:-10}" "http://${CURL_HOST}:${CURL_PORT}/" || true)"
if [[ "$body" != *"$VERIFY_MARKER"* ]]; then
  echo "[verify:${ASYLA_HOST_ID}] FAIL: unexpected HTTP body (len ${#body})" >&2
  exit 1
fi

echo "[verify:${ASYLA_HOST_ID}] OK"
