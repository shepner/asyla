#!/bin/bash
# Comprehensive maintenance script
# Updates scripts, OS, and reloads all Docker containers

set -euo pipefail  # Exit on error, undefined vars, pipe failures

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

# Re-run as root if needed
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# When running as root, run scripts from the invoker's home (e.g. /home/docker)
if [ -n "${SUDO_USER:-}" ]; then
    HOME_DIR=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    HOME_DIR="$HOME"
fi
HOME_DIR="${HOME_DIR:-/home/docker}"

log_info "Starting comprehensive system maintenance..."

# Step 1: Update scripts from repository
log_info "Step 1: Updating scripts from repository..."
"$HOME_DIR/update_scripts.sh"

# Step 2: Update OS
log_info "Step 2: Updating operating system..."
"$HOME_DIR/update.sh"

# Step 3: Reload all Docker containers
log_info "Step 3: Reloading all Docker containers..."
if [ -f "$HOME_DIR/scripts/docker/refresh_all.sh" ]; then
    "$HOME_DIR/scripts/docker/refresh_all.sh"
else
    log_warn "refresh_all.sh not found, skipping Docker container reload"
    log_info "Docker containers can be managed manually with docker compose"
fi

log_info "Comprehensive maintenance completed successfully!"
