#!/usr/bin/env bash
# Deploy d01: copy local .env secrets and restart all services.
# Run from your workstation (not on d01). Requires ssh access to docker@d01.
#
# Usage: ./deploy.sh [host]
#   host  - SSH target (default: d01)
#
# What it does:
#   1. Copies local .env files (excluded from repo) to /mnt/docker/<app>/ on d01
#   2. Runs update_scripts.sh on d01 to pull latest repo changes
#   3. Restarts cloudflared, internal-proxy, and media stack

set -euo pipefail

HOST="${1:-d01}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

copy_env "$SCRIPT_DIR/apps/cloudflared/.env"    /mnt/docker/cloudflared/.env    cloudflared
copy_env "$SCRIPT_DIR/apps/internal-proxy/.env" /mnt/docker/internal-proxy/.env internal-proxy

# ---------------------------------------------------------------------------
# Pull latest scripts from repo
# ---------------------------------------------------------------------------
log "Running update_scripts.sh on $HOST..."
ssh "$HOST" "~/update_scripts.sh"

# ---------------------------------------------------------------------------
# Restart services
# ---------------------------------------------------------------------------
log "Restarting cloudflared..."
ssh "$HOST" "~/scripts/d01/apps/cloudflared/cloudflared.sh restart"

log "Restarting internal-proxy..."
ssh "$HOST" "~/scripts/d01/apps/internal-proxy/internal-proxy.sh restart"

log "Restarting media stack..."
ssh "$HOST" "~/scripts/d01/apps/media/media.sh restart"

log "=== Deploy complete ==="
