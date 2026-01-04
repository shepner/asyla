#!/bin/bash
# Configure NFS client for Debian 13 (Trixie)
# Sets up NFS mounts for Docker backup storage

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

log_info "Starting NFS client configuration..."

# Update package lists
log_info "Updating package lists..."
apt update

# Install NFS client utilities
log_info "Installing NFS client utilities..."
apt install -y nfs-common

# Create mount points
log_info "Creating NFS mount points..."
mkdir -p /mnt/nas/data1/docker
mkdir -p /mnt/nas/data2/docker

# Set proper permissions on mount points
chown docker:asyla /mnt/nas/data1/docker
chown docker:asyla /mnt/nas/data2/docker
chmod 755 /mnt/nas/data1/docker
chmod 755 /mnt/nas/data2/docker

# Check if fstab entries already exist
if grep -q "nas:/mnt/data1/docker" /etc/fstab; then
    log_warn "NFS mount for data1/docker already exists in /etc/fstab, skipping..."
else
    log_info "Adding NFS mount for data1/docker to /etc/fstab..."
    echo "nas:/mnt/data1/docker /mnt/nas/data1/docker nfs rw,noauto,user 0 0" >> /etc/fstab
fi

if grep -q "nas:/mnt/data2/docker" /etc/fstab; then
    log_warn "NFS mount for data2/docker already exists in /etc/fstab, skipping..."
else
    log_info "Adding NFS mount for data2/docker to /etc/fstab..."
    echo "nas:/mnt/data2/docker /mnt/nas/data2/docker nfs rw,noauto,user 0 0" >> /etc/fstab
fi

# Clean up package cache
log_info "Cleaning up package cache..."
apt autoremove -y
apt autoclean

log_info "NFS client configuration completed successfully!"
log_warn "NFS mounts are configured but not automatically mounted."
log_info "To mount manually: mount /mnt/nas/data1/docker"
log_info "To mount all: mount -a"
log_info "Mounts will be available after reboot or manual mount"

