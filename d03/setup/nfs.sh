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
MOUNT_DATA1=false
MOUNT_DATA2=false

if grep -q "nas:/mnt/data1/docker" /etc/fstab; then
    log_warn "NFS mount for data1/docker already exists in /etc/fstab, skipping..."
else
    log_info "Adding NFS mount for data1/docker to /etc/fstab..."
    echo "nas:/mnt/data1/docker /mnt/nas/data1/docker nfs rw,_netdev,auto,user 0 0" >> /etc/fstab
    MOUNT_DATA1=true
fi

if grep -q "nas:/mnt/data2/docker" /etc/fstab; then
    log_warn "NFS mount for data2/docker already exists in /etc/fstab, skipping..."
else
    log_info "Adding NFS mount for data2/docker to /etc/fstab..."
    echo "nas:/mnt/data2/docker /mnt/nas/data2/docker nfs rw,_netdev,auto,user 0 0" >> /etc/fstab
    MOUNT_DATA2=true
fi

# Mount NFS shares now (if network is available)
log_info "Attempting to mount NFS shares..."
for mount_point in "/mnt/nas/data1/docker" "/mnt/nas/data2/docker"; do
    # Skip if already mounted
    if mountpoint -q "$mount_point" 2>/dev/null; then
        log_info "✅ $mount_point already mounted"
        continue
    fi
    
    # Try to mount
    if mount "$mount_point" 2>/dev/null; then
        log_info "✅ Successfully mounted $mount_point"
    else
        log_warn "⚠️  Could not mount $mount_point (network may not be ready; will mount on boot)"
    fi
done

# Clean up package cache
log_info "Cleaning up package cache..."
apt autoremove -y
apt autoclean

log_info "NFS client configuration completed successfully!"
log_info "✅ NFS mounts configured to mount automatically on boot"
log_info "Mounts: /mnt/nas/data1/docker and /mnt/nas/data2/docker"

