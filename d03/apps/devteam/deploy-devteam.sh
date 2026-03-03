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
echo "  1. OpenBao    (secrets management)   — vault.asyla.org (internal only)"
echo "  2. Plane      (project management)   — plane.asyla.org (Cloudflare Access)"
echo "  3. Uptime Kuma (monitoring)          — status.asyla.org (Cloudflare Access)"
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
echo "=== [0/7] Pulling all images in parallel ==="
echo "[INFO] d03 has 12 threads (slow per-thread) — parallel pulls are much faster."

# Pull all three services' images concurrently in background
"$SCRIPT_DIR/plane/plane.sh" pull &
PID_PLANE_PULL=$!

docker pull openbao/openbao:latest &
PID_OPENBAO_PULL=$!

docker pull louislam/uptime-kuma:1 &
PID_KUMA_PULL=$!

echo "[INFO] Waiting for all image pulls to complete..."
wait $PID_PLANE_PULL && echo "[INFO] Plane images pulled." || echo "[WARN] Plane pull had issues."
wait $PID_OPENBAO_PULL && echo "[INFO] OpenBao image pulled." || echo "[WARN] OpenBao pull had issues."
wait $PID_KUMA_PULL && echo "[INFO] Uptime Kuma image pulled." || echo "[WARN] Uptime Kuma pull had issues."

echo "[INFO] All images pulled."

# ─── Step 1: OpenBao ─────────────────────────────────────────────────────────

echo ""
echo "=== [1/7] OpenBao ==="

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
echo "=== [2/7] Store Cursor API Key in OpenBao ==="

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

# ─── Step 3: Plane ───────────────────────────────────────────────────────────

echo ""
echo "=== [3/7] Plane ==="

echo "[INFO] Generating Plane .env (if needed)..."
"$SCRIPT_DIR/plane/generate-env.sh"

if docker ps --format '{{.Names}}' | grep -q '^plane-api$'; then
  echo "[INFO] Plane containers are already running."
else
  echo "[INFO] Starting Plane (this may take a few minutes on first run for image pulls)..."
  "$SCRIPT_DIR/plane/plane.sh" up
fi

echo "[INFO] Waiting for Plane API to become healthy..."
ATTEMPTS=0
MAX_ATTEMPTS=60
until curl -sf http://localhost:80/api/health > /dev/null 2>&1; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    echo "[ERROR] Plane API did not become healthy after ${MAX_ATTEMPTS} attempts."
    echo "        Check logs: $SCRIPT_DIR/plane/plane.sh logs api"
    exit 1
  fi
  printf "."
  sleep 5
done
echo ""
echo "[INFO] Plane API is healthy."

echo "[INFO] Running Plane setup..."
"$SCRIPT_DIR/plane/setup-plane.sh"

# ─── Step 4: Uptime Kuma ─────────────────────────────────────────────────────

echo ""
echo "=== [4/7] Uptime Kuma ==="

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
echo "=== [5/7] Restarting shared infrastructure ==="

echo "[INFO] Restarting internal-proxy (Caddy)..."
~/scripts/d03/apps/internal-proxy/internal-proxy.sh restart

echo "[INFO] Restarting cloudflared..."
~/scripts/d03/apps/cloudflared/cloudflared.sh restart

# ─── Step 6: DNS ─────────────────────────────────────────────────────────────

echo ""
echo "=== [6/7] Pi-hole DNS Records ==="
echo ""
echo "Add these A records in Pi-hole (Local DNS -> DNS Records):"
echo "  plane.asyla.org   -> 10.0.0.62"
echo "  vault.asyla.org   -> 10.0.0.62"
echo "  status.asyla.org  -> 10.0.0.62"
echo ""
read -rp "Press Enter when DNS records are added..."

# ─── Step 7: Verify ──────────────────────────────────────────────────────────

echo ""
echo "=== [7/7] Verification ==="
echo ""
echo "Test access (LAN):"

for host in vault.asyla.org plane.asyla.org status.asyla.org; do
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${host}/" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "000" ]; then
    echo "  [WARN] https://$host — connection failed (DNS not propagated yet?)"
  else
    echo "  [OK]   https://$host — HTTP $HTTP_CODE"
  fi
done

echo ""
echo "Test access (remote — requires Cloudflare Access):"
echo "  https://plane.asyla.org"
echo "  https://status.asyla.org"
echo "  (vault.asyla.org is internal only — no external access)"

echo ""
echo "============================================"
echo "  Deployment complete!"
echo "============================================"
