#!/bin/bash
# Bootstrap script for d03 VM
# This script completes the initial setup that cloud-init cannot handle
# Run this automatically on first boot or manually after first login

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

log_info "Starting d03 bootstrap script..."

# Create asyla group with GID 1000 if it doesn't exist
if ! getent group asyla > /dev/null 2>&1; then
    log_info "Creating asyla group (GID 1000)..."
    groupadd -g 1000 asyla
else
    log_info "asyla group already exists"
fi

# Modify docker user to have correct UID/GID and groups
if id docker > /dev/null 2>&1; then
    log_info "Configuring docker user..."
    
    # Get current UID/GID
    CURRENT_UID=$(id -u docker)
    CURRENT_GID=$(id -g docker)
    
    # Change primary group to asyla if needed
    if [ "$CURRENT_GID" != "1000" ]; then
        log_info "Changing docker user primary group to asyla..."
        usermod -g asyla docker
    fi
    
    # Change UID if needed
    if [ "$CURRENT_UID" != "1003" ]; then
        log_info "Changing docker user UID to 1003..."
        usermod -u 1003 docker
        # Fix home directory ownership
        chown -R docker:asyla /home/docker
    fi
    
    # Ensure docker user is in required groups
    log_info "Adding docker user to required groups..."
    usermod -aG docker,sudo docker
    
    # Ensure home directory ownership is correct
    chown -R docker:asyla /home/docker
else
    log_error "docker user does not exist - cloud-init may have failed"
    exit 1
fi

# Ensure .ssh directory exists with correct permissions
log_info "Configuring SSH directory..."
mkdir -p /home/docker/.ssh
chmod 700 /home/docker/.ssh
chown -R docker:asyla /home/docker/.ssh

# Note: SSH keys are already configured by cloud-init
# Private key and config will be copied manually from workstation

log_info "Bootstrap script completed successfully!"
log_info "Next steps:"
log_info "  1. Copy SSH private key: scp ~/.ssh/docker_rsa d03:.ssh/docker_rsa"
log_info "  2. Copy SSH config: scp ~/.ssh/config d03:.ssh/config"
log_info "  3. Set permissions: ssh d03 'chmod -R 700 ~/.ssh'"
log_info "  4. Run setup scripts: ~/scripts/d03/setup/*.sh"
