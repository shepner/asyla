#!/usr/bin/env bash
# Deploy d01: pull latest scripts, deploy internal-access, and restart all services.
# Run from your workstation (not on d01). Requires ssh access to docker@d01.
#
# Usage: ./deploy.sh [host]
#   host  - SSH target (default: d01)
#
# What it does:
#   1. Runs update_scripts.sh on d01 to pull latest repo changes. d01 stores no GitLab credential:
#      run this through the credentials capability so the deploy token reaches the updater on stdin
#      (from ~/local/asyla: python3 core/tools/credentials.py exec ASYLA_HOSTS_DEPLOY_USER
#      ASYLA_HOSTS_DEPLOY_TOKEN -- projects/asyla-hosts/d01/deploy.sh). Without them this step is
#      skipped with a warning and the installed scripts are used.
#   2. Deploys the internal Caddy from the internal-access repo (scripts/deploy-host.sh d01)
#   3. Restarts cloudflared, internal-access, and media stack
#
# Secrets live only on d01 and this script never touches them (no workstation copies):
#   /mnt/docker/cloudflared/.env       CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_ZONE_ID, CLOUDFLARE_API_TOKEN, TUNNEL_TOKEN
#   /mnt/docker/internal-proxy/.env    CF_API_TOKEN, BREEDING_PROGRAM_LAN_SECRET
# To rotate, edit the file on d01, then restart that app:
#   ~/scripts/d01/apps/cloudflared/cloudflared.sh restart
#   ~/scripts/d01/apps/internal-access/internal-access.sh restart
#
# The internal Caddy (caddy-internal-d01) lives in asyla/projects/internal-access, not in this repo
# (cut over 2026-09-28). Override its checkout with INTERNAL_ACCESS_REPO.

set -euo pipefail

HOST="${1:-d01}"
INTERNAL_ACCESS_REPO="${INTERNAL_ACCESS_REPO:-$HOME/local/asyla/projects/internal-access}"

log() { echo "[deploy] $*"; }

log "=== Deploying to $HOST ==="

# ---------------------------------------------------------------------------
# Pull latest scripts from repo
# ---------------------------------------------------------------------------
if [ -n "${ASYLA_HOSTS_DEPLOY_USER:-}" ] && [ -n "${ASYLA_HOSTS_DEPLOY_TOKEN:-}" ]; then
  log "Running update_scripts.sh on $HOST (the deploy token on its stdin)..."
  # printf is a bash builtin: the token is in no process's argv, only on the ssh stdin.
  printf 'username=%s\npassword=%s\n' "$ASYLA_HOSTS_DEPLOY_USER" "$ASYLA_HOSTS_DEPLOY_TOKEN" | ssh "$HOST" "~/update_scripts.sh"
else
  log "WARN: no ASYLA_HOSTS_DEPLOY_USER/ASYLA_HOSTS_DEPLOY_TOKEN: scripts on $HOST not updated (run through credentials exec)"
fi

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
