#!/bin/bash
# Update system packages for Debian 13 (Trixie)
# Quick OS maintenance script - run via SSH for one-command system updates

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

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

log_info "Starting system update..."

if command -v docker >/dev/null 2>&1; then
    log_info "Cleaning up Docker images and system..."
    docker image prune --all -f || true
    docker system prune --all -f || true
fi

log_info "Updating package lists..."
apt update

log_info "Upgrading system packages..."
DEBIAN_FRONTEND=noninteractive apt upgrade -y

log_info "Removing unused packages..."
apt autoremove -y

log_info "Cleaning package cache..."
apt autoclean

log_info "System update completed successfully!"
