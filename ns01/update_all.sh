#!/bin/bash
# Comprehensive maintenance script for ns01
# Updates scripts, OS, and reloads all Docker containers

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

HOME_DIR="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}"
HOME_DIR="${HOME_DIR:-/home/docker}"

log_info "Starting comprehensive system maintenance..."

log_info "Step 1: Updating scripts from repository..."
"$HOME_DIR/update_scripts.sh"

log_info "Step 2: Updating operating system..."
"$HOME_DIR/update.sh"

log_info "Comprehensive maintenance completed successfully!"
