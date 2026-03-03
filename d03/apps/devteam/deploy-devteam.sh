#!/bin/bash
# deploy-devteam.sh — one-time setup for devteam infrastructure on d03.
# Run on d03 after update_scripts.sh syncs the repo.
# Idempotent: safe to re-run (checks if services are already running, skips completed steps).
#
# Usage: ~/scripts/d03/apps/devteam/deploy-devteam.sh
#
# Deploys: OpenBao, Plane, Uptime Kuma
# Updates: internal-proxy, cloudflared
# Prompts: Cursor API key, OpenBao unseal keys, Plane EA account, Pi-hole DNS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo "  DevTeam Infrastructure Deployment (d03)"
echo "============================================"
echo ""
echo "This script will deploy:"
echo "  1. OpenBao     (secrets management)  — vault.asyla.org (internal only)"
echo "  2. Vikunja     (task management)     — vikunja.asyla.org (Cloudflare Access)"
echo "  3. Uptime Kuma (monitoring)          — status.asyla.org (Cloudflare Access)"
echo ""
echo "NOTE: Plane is already deployed and left running (will be removed once Vikunja is verified)."
echo ""
echo "It will also restart internal-proxy and cloudflared."
echo ""
read -rp "Continue? [y/N] " CONFIRM
if [[ "$CONFIRM" != [yY] ]]; then
  echo "Aborted."
  exit 0
fi

# ─── Step 0: Pull all images in parallel ─────────────────────────────────────

echo ""
echo "=== [0/8] Pulling all images in parallel ==="
echo "[INFO] d03 has 12 threads (slow per-thread) — parallel pulls are much faster."

# Pull all services' images concurrently in background
"$SCRIPT_DIR/vikunja/vikunja.sh" pull &
PID_VIKUNJA_PULL=$!

docker pull openbao/openbao:latest &
PID_OPENBAO_PULL=$!

docker pull louislam/uptime-kuma:1 &
PID_KUMA_PULL=$!

echo "[INFO] Waiting for all image pulls to complete..."
wait $PID_VIKUNJA_PULL && echo "[INFO] Vikunja images pulled." || echo "[WARN] Vikunja pull had issues."
wait $PID_OPENBAO_PULL && echo "[INFO] OpenBao image pulled." || echo "[WARN] OpenBao pull had issues."
wait $PID_KUMA_PULL && echo "[INFO] Uptime Kuma image pulled." || echo "[WARN] Uptime Kuma pull had issues."

echo "[INFO] All images pulled."

# ─── Step 1: OpenBao ─────────────────────────────────────────────────────────

echo ""
echo "=== [1/8] OpenBao ==="

if docker ps --format '{{.Names}}' | grep -q '^openbao$'; then
  echo "[INFO] OpenBao container is already running."
else
  echo "[INFO] Starting OpenBao..."
  "$SCRIPT_DIR/openbao/openbao.sh" up
  sleep 3
fi

echo "[INFO] Initializing OpenBao (if needed)..."
"$SCRIPT_DIR/openbao/init-openbao.sh"

# ─── Step 2: Store Cursor API key ────────────────────────────────────────────

echo ""
echo "=== [2/8] Store Cursor API Key in OpenBao ==="

read -rsp "Enter OpenBao root token: " BAO_TOKEN && echo

# Check if key already exists
if docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="$BAO_TOKEN" \
  openbao bao kv get secret/devteam/cursor-api-key >/dev/null 2>&1; then
  echo "[INFO] Cursor API key already stored in OpenBao."
  read -rp "Overwrite? [y/N] " OVERWRITE
  if [[ "$OVERWRITE" != [yY] ]]; then
    echo "[INFO] Keeping existing key."
  else
    read -rsp "Enter Cursor API key: " CURSOR_KEY && echo
    docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="$BAO_TOKEN" \
      openbao bao kv put secret/devteam/cursor-api-key value="$CURSOR_KEY"
    echo "[INFO] Cursor API key updated."
  fi
else
  read -rsp "Enter Cursor API key: " CURSOR_KEY && echo
  docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="$BAO_TOKEN" \
    openbao bao kv put secret/devteam/cursor-api-key value="$CURSOR_KEY"
  echo "[INFO] Cursor API key stored."
fi

export BAO_TOKEN

# ─── Step 3: Vikunja ─────────────────────────────────────────────────────────

echo ""
echo "=== [3/8] Vikunja ==="

echo "[INFO] Generating Vikunja .env (if needed)..."
"$SCRIPT_DIR/vikunja/generate-env.sh"

# Temporarily enable registration so setup-vikunja.sh can create the admin user.
VIKUNJA_ENV="$SCRIPT_DIR/vikunja/.env"
if grep -q 'ENABLE_REGISTRATION=false' "$VIKUNJA_ENV" 2>/dev/null; then
  sed -i 's/ENABLE_REGISTRATION=false/ENABLE_REGISTRATION=true/' "$VIKUNJA_ENV"
  REGISTRATION_ENABLED_BY_SCRIPT=true
  echo "[INFO] Temporarily enabled user registration."
fi

if docker ps --format '{{.Names}}' | grep -q '^vikunja$'; then
  echo "[INFO] Vikunja is already running."
else
  echo "[INFO] Starting Vikunja..."
  "$SCRIPT_DIR/vikunja/vikunja.sh" up
fi

echo "[INFO] Waiting for Vikunja to become healthy..."
ATTEMPTS=0
MAX_ATTEMPTS=60
until docker run --rm --network vikunja_net curlimages/curl -sf http://vikunja:3456/api/v1/info > /dev/null 2>&1; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    echo "[ERROR] Vikunja did not respond after ${MAX_ATTEMPTS} attempts."
    echo "        Check logs: $SCRIPT_DIR/vikunja/vikunja.sh logs"
    exit 1
  fi
  printf "."
  sleep 3
done
echo ""
echo "[INFO] Vikunja is healthy."

# Pre-create external networks that internal-proxy depends on
docker network create uptimekuma_net 2>/dev/null || true

echo "[INFO] Restarting internal-proxy so vikunja.asyla.org is routable..."
~/scripts/d03/apps/internal-proxy/internal-proxy.sh restart

echo "[INFO] Running Vikunja setup (creates admin user, project, labels, API token)..."
"$SCRIPT_DIR/vikunja/setup-vikunja.sh"

# Disable registration after setup
if [ "${REGISTRATION_ENABLED_BY_SCRIPT:-false}" = "true" ]; then
  sed -i 's/ENABLE_REGISTRATION=true/ENABLE_REGISTRATION=false/' "$VIKUNJA_ENV"
  echo "[INFO] Registration disabled. Restarting Vikunja..."
  "$SCRIPT_DIR/vikunja/vikunja.sh" restart
  echo "[INFO] Vikunja restarted with registration disabled."
fi

# ─── Step 4: Uptime Kuma ─────────────────────────────────────────────────────

echo ""
echo "=== [4/8] Uptime Kuma ==="

if docker ps --format '{{.Names}}' | grep -q '^uptime-kuma$'; then
  echo "[INFO] Uptime Kuma container is already running."
else
  echo "[INFO] Starting Uptime Kuma..."
  "$SCRIPT_DIR/uptime-kuma/uptime-kuma.sh" up
  sleep 5
fi

echo "[INFO] Running Uptime Kuma monitor setup..."
"$SCRIPT_DIR/uptime-kuma/setup-monitors.sh"

# ─── Step 5: Restart shared infra ────────────────────────────────────────────

echo ""
echo "=== [5/8] Restarting shared infrastructure ==="

echo "[INFO] Restarting internal-proxy (Caddy)..."
~/scripts/d03/apps/internal-proxy/internal-proxy.sh restart

echo "[INFO] Restarting cloudflared..."
~/scripts/d03/apps/cloudflared/cloudflared.sh restart

# ─── Step 6: DNS ─────────────────────────────────────────────────────────────

echo ""
echo "=== [6/8] Pi-hole DNS Records ==="
echo ""
echo "Add (or verify) these A records in Pi-hole (Local DNS -> DNS Records):"
echo "  vault.asyla.org    -> 10.0.0.62"
echo "  vikunja.asyla.org  -> 10.0.0.62"
echo "  status.asyla.org   -> 10.0.0.62"
echo ""
echo "(plane.asyla.org should already exist from the earlier deployment.)"
echo ""
read -rp "Press Enter when DNS records are added..."

# ─── Step 7: Cloudflare Access ───────────────────────────────────────────────

echo ""
echo "=== [7/8] Cloudflare Access ==="
echo ""
echo "Ensure vikunja.asyla.org is added to the Cloudflare Access application:"
echo "  Cloudflare Zero Trust -> Access -> Applications"
echo "  Add vikunja.asyla.org (or extend the existing devteam app to cover it)."
echo ""
read -rp "Press Enter when Cloudflare Access is configured (or skip if already done)..."

# ─── Step 8: Verify ──────────────────────────────────────────────────────────

echo ""
echo "=== [8/8] Verification ==="
echo ""
echo "Test access (LAN):"

for host in vault.asyla.org vikunja.asyla.org status.asyla.org; do
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${host}/" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "000" ]; then
    echo "  [WARN] https://$host — connection failed (DNS not propagated yet?)"
  else
    echo "  [OK]   https://$host — HTTP $HTTP_CODE"
  fi
done

echo ""
echo "Test dispatcher (dry-run):"
echo "  cd ~/scripts/knowledge-hub"
echo "  python3 .cursor/helpers/dispatch_agent.py --ticket 1 --project . --dry-run"
echo ""
echo "Test remote access (requires Cloudflare Access):"
echo "  https://vikunja.asyla.org"
echo "  https://status.asyla.org"
echo "  (vault.asyla.org is internal only)"

echo ""
echo "============================================"
echo "  Deployment complete!"
echo "============================================"
