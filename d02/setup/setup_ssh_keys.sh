#!/bin/bash
# Setup SSH keys for docker user on d02 to enable docker-to-docker SSH access
# This allows the migrate-app.sh script to work between docker hosts
#
# Usage:
#   From workstation: curl -s https://raw.githubusercontent.com/shepner/asyla/master/d02/setup/setup_ssh_keys.sh | ssh docker@d02 bash
#   Or manually: ssh docker@d02 'bash -s' < d02/setup/setup_ssh_keys.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check if running as docker user
if [ "$(whoami)" != "docker" ]; then
    log_error "This script must be run as docker user"
    log_info "Run as: ssh docker@d02 'bash -s' < setup_ssh_keys.sh"
    exit 1
fi

log_info "Setting up SSH keys for docker-to-docker access..."

# Ensure .ssh directory exists
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Check if private key already exists
if [ -f ~/.ssh/docker_rsa ]; then
    log_info "SSH private key already exists"
else
    log_warn "SSH private key not found at ~/.ssh/docker_rsa"
    log_info "To set up SSH keys, copy them from your workstation:"
    echo ""
    echo "  # From your workstation:"
    echo "  scp ~/.ssh/docker_rsa d02:.ssh/docker_rsa"
    echo "  scp ~/.ssh/docker_rsa.pub d02:.ssh/docker_rsa.pub"
    echo "  scp ~/.ssh/config d02:.ssh/config"
    echo "  ssh d02 'chmod 600 ~/.ssh/docker_rsa ~/.ssh/config && chmod 700 ~/.ssh'"
    echo ""
    log_warn "SSH keys must be copied manually for docker-to-docker access to work"
    exit 1
fi

# Set correct permissions
log_info "Setting SSH key permissions..."
chmod 600 ~/.ssh/docker_rsa 2>/dev/null || true
chmod 644 ~/.ssh/docker_rsa.pub 2>/dev/null || true
chmod 600 ~/.ssh/config 2>/dev/null || true
chmod 700 ~/.ssh

# Test SSH connectivity to other docker hosts
log_info "Testing SSH connectivity to other docker hosts..."

if ssh -o ConnectTimeout=5 -o BatchMode=yes docker@d01 echo "SSH to d01 works" 2>/dev/null; then
    log_info "✅ SSH to d01 works"
else
    log_warn "⚠️  SSH to d01 failed - ensure d01 has docker user's public key in authorized_keys"
fi

if ssh -o ConnectTimeout=5 -o BatchMode=yes docker@d03 echo "SSH to d03 works" 2>/dev/null; then
    log_info "✅ SSH to d03 works"
else
    log_warn "⚠️  SSH to d03 failed - ensure d03 has docker user's public key in authorized_keys"
fi

log_info "SSH key setup complete!"
log_info ""
log_info "To enable docker-to-docker SSH on other hosts, add d02's public key to their authorized_keys:"
log_info "  # On d01 and d03, run:"
log_info "  cat ~/.ssh/docker_rsa.pub >> /home/docker/.ssh/authorized_keys"
log_info "  chmod 600 /home/docker/.ssh/authorized_keys"
