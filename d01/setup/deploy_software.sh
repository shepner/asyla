#!/bin/bash
# One-time software deploy for d01 VM
# Use when cloud-init did not complete software install.
# Usage:   curl -s https://raw.githubusercontent.com/shepner/asyla/master/d01/setup/deploy_software.sh | sudo bash
#          Or from workstation: ssh d01 'sudo bash -s' < d01/setup/deploy_software.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

if [ "$EUID" -ne 0 ]; then
  log_error "Run as root or with sudo"
  exit 1
fi

HOSTNAME=$(hostname -s)
if [ "$HOSTNAME" != "d01" ]; then
  log_warn "Hostname is $HOSTNAME (expected d01). update_scripts.sh uses hostname to install scripts."
fi

TARGET_USER="docker"
TARGET_HOME="/home/$TARGET_USER"

if ! getent group asyla >/dev/null 2>&1; then
  log_info "Creating asyla group..."
  if getent group 1000 >/dev/null 2>&1; then
    groupadd asyla
  else
    groupadd -g 1000 asyla
  fi
  usermod -aG asyla "$TARGET_USER" 2>/dev/null || true
fi

log_info "Step 0: Install required packages (git, curl)..."
apt-get update -qq
apt-get install -y -qq git curl >/dev/null 2>&1 || {
  log_error "Failed to install git/curl"
  exit 1
}

log_info "Step 1: Install scripts (update_scripts.sh)..."
curl -s https://raw.githubusercontent.com/shepner/asyla/master/d01/update_scripts.sh | bash || {
  log_error "update_scripts.sh failed"
  exit 1
}

if [ ! -f "$TARGET_HOME/scripts/d01/setup/systemConfig.sh" ]; then
  log_error "Scripts not found at $TARGET_HOME/scripts/d01/setup/ - aborting"
  exit 1
fi

log_info "Step 2: Run systemConfig.sh..."
"$TARGET_HOME/scripts/d01/setup/systemConfig.sh" || { log_warn "systemConfig.sh exited non-zero (continuing)"; }

log_info "Step 3: Run nfs.sh..."
"$TARGET_HOME/scripts/d01/setup/nfs.sh" || { log_warn "nfs.sh exited non-zero (continuing)"; }

log_info "Step 4: Run smb.sh..."
"$TARGET_HOME/scripts/d01/setup/smb.sh" || { log_warn "smb.sh exited non-zero (continuing)"; }

log_info "Step 5: Run iscsi_install.sh..."
"$TARGET_HOME/scripts/d01/setup/iscsi_install.sh" || { log_warn "iscsi_install.sh exited non-zero (continuing)"; }

log_info "Step 6: Run docker.sh..."
"$TARGET_HOME/scripts/d01/setup/docker.sh" || { log_warn "docker.sh exited non-zero (continuing)"; }

log_info "Step 7: Run update.sh (full apt upgrade)..."
"$TARGET_HOME/update.sh" || { log_warn "update.sh exited non-zero (continuing)"; }

log_info "Deploy complete. Docker user should run: newgrp docker (or log out and back in), then: docker ps"
log_info ""
log_info "Next: Set up SSH keys for docker-to-docker access:"
log_info "  Run: ~/scripts/d01/setup/setup_ssh_keys.sh"
log_info "  Or copy SSH keys manually (see d01/README.md)"
