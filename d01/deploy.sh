#!/usr/bin/env bash
# Deploy d01: copy local .env secrets and restart all services.
# Run from your workstation (not on d01). Requires ssh access to docker@d01.
#
# Usage: ./deploy.sh [host]
#   host  - SSH target (default: d01)
#
# What it does:
#   1. Copies apps/cloudflared/.env (excluded from repo) to /mnt/docker/cloudflared/ on d01
#   2. Runs update_scripts.sh on d01 to pull latest repo changes
#   3. Deploys the internal Caddy from the internal-access repo (scripts/deploy-host.sh d01)
#   4. Restarts cloudflared, internal-access, and media stack
#
# The internal Caddy (caddy-internal-d01) lives in asyla/projects/internal-access, not in this repo
# (cut over 2026-09-28). Override its checkout with INTERNAL_ACCESS_REPO.
# Its secrets (CF_API_TOKEN, BREEDING_PROGRAM_LAN_SECRET) live only on d01 in /mnt/docker/internal-proxy/.env;
# this script never touches that file. To rotate, edit it on d01, then run
# ~/scripts/d01/apps/internal-access/internal-access.sh restart

set -euo pipefail

HOST="${1:-d01}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERNAL_ACCESS_REPO="${INTERNAL_ACCESS_REPO:-$HOME/local/asyla/projects/internal-access}"

log() { echo "[deploy] $*"; }

# ---------------------------------------------------------------------------
# Copy .env files that are excluded from the repo
# ---------------------------------------------------------------------------
copy_env() {
  local src="$1" remote_dest="$2" label="$3"
  if [ -f "$src" ]; then
    log "Copying $label .env -> $HOST:$remote_dest"
    ssh "$HOST" "mkdir -p $(dirname "$remote_dest")"
    scp "$src" "${HOST}:${remote_dest}"
  else
    log "WARN: $src not found — skipping $label .env"
  fi
}

log "=== Deploying to $HOST ==="

copy_env "$SCRIPT_DIR/apps/cloudflared/.env" /mnt/docker/cloudflared/.env cloudflared

# ---------------------------------------------------------------------------
# Pull latest scripts from repo
# ---------------------------------------------------------------------------
log "Running update_scripts.sh on $HOST..."
ssh "$HOST" "~/update_scripts.sh"

log "Deploying internal-access from $INTERNAL_ACCESS_REPO..."
"$INTERNAL_ACCESS_REPO/scripts/deploy-host.sh" d01

# ---------------------------------------------------------------------------
# Restart services
# ---------------------------------------------------------------------------
log "Restarting cloudflared..."
ssh "$HOST" "~/scripts/d01/apps/cloudflared/cloudflared.sh restart"

log "Restarting internal-access..."
ssh "$HOST" "~/scripts/d01/apps/internal-access/internal-access.sh restart verify"

log "Restarting media stack..."
ssh "$HOST" "~/scripts/d01/apps/media/media.sh restart"

log "=== Deploy complete ==="
