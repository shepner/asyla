#!/bin/bash
# Update Docker scripts from repository
# Uses sparse git checkout to get only needed files

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

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

REPO="shepner/asyla"
WORKDIR=~/scripts
HOSTNAME=$(hostname -s)

log_info "Updating scripts from repository..."

# Remove existing work directory if it exists
if [ -d "$WORKDIR" ]; then
    log_info "Removing existing scripts directory..."
    rm -rf "$WORKDIR"
fi

# Sparse git checkout - only get what we need
# https://stackoverflow.com/questions/2466735/how-to-sparsely-checkout-only-one-single-file-from-a-git-repository
log_info "Cloning repository (sparse checkout)..."
git clone --depth 1 --no-checkout --filter=blob:none "https://github.com/$REPO.git" "$WORKDIR"

cd "$WORKDIR"

# Checkout only the directories we need
log_info "Checking out host-specific scripts ($HOSTNAME)..."
git checkout master -- "$HOSTNAME" || log_warn "No $HOSTNAME directory found in repository"

log_info "Checking out docker scripts..."
git checkout master -- docker || log_warn "No docker directory found in repository"

# Set proper permissions on scripts
log_info "Setting script permissions..."
find "$WORKDIR" -name "*.sh" -exec chmod 744 {} \;

# Move host-specific scripts to home directory
if [ -d "$WORKDIR/$HOSTNAME" ]; then
    log_info "Moving host-specific scripts to home directory..."
    mv "$WORKDIR/$HOSTNAME"/*.sh ~/ 2>/dev/null || log_warn "No scripts to move from $HOSTNAME directory"
fi

# Clean up temporary git clone
log_info "Cleaning up temporary files..."
cd ~
rm -rf "$WORKDIR"

log_info "Scripts updated successfully!"

