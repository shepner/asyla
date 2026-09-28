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
#   3. Deploys the internal Caddy from the internal-access repo (scripts/deploy-host.sh d01)
#   4. Restarts cloudflared, internal-access, and media stack
#
# The internal Caddy (caddy-internal-d01) lives in asyla/projects/internal-access, not in this repo
# (cut over 2026-09-28). Override its checkout with INTERNAL_ACCESS_REPO.

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

# Set each KEY=value from a local file in the remote .env, keeping keys that exist only on the host
# (e.g. BREEDING_PROGRAM_LAN_SECRET, generated on d01). Values travel by scp, never on a command line.
merge_env() {
  local src="$1" remote_dest="$2" label="$3" tmp
  if [ ! -f "$src" ]; then
    log "WARN: $src not found — skipping $label .env"
    return 0
  fi
  log "Merging $label .env keys -> $HOST:$remote_dest"
  tmp="/tmp/deploy-env-$$"
  scp -q "$src" "${HOST}:${tmp}"
  # shellcheck disable=SC2029
  ssh "$HOST" "set -e; umask 077; mkdir -p $(dirname "$remote_dest"); touch '$remote_dest'
    awk -F= 'NR==FNR { if (\$0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/) set[\$1]=1; next } !(\$1 in set)' '$tmp' '$remote_dest' >'$remote_dest.new'
    grep -E '^[A-Za-z_][A-Za-z0-9_]*=' '$tmp' >>'$remote_dest.new' || true
    chmod 600 '$remote_dest.new'; mv '$remote_dest.new' '$remote_dest'; rm -f '$tmp'"
}

log "=== Deploying to $HOST ==="

copy_env  "$SCRIPT_DIR/apps/cloudflared/.env" /mnt/docker/cloudflared/.env    cloudflared
merge_env "$SCRIPT_DIR/internal-access.env"   /mnt/docker/internal-proxy/.env internal-access

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
