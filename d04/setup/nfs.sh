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

# Set proper permissions on the mount points, never on a mounted NAS share (a re-run would
# change the shared directory every host backs up to).
for mount_point in /mnt/nas/data1/docker /mnt/nas/data2/docker; do
    if ! mountpoint -q "$mount_point"; then
        chown docker:asyla "$mount_point"
        chmod 755 "$mount_point"
    fi
done

# A replica ([replica] in this host's host.toml, e.g. d04 as a d03 replica) mounts the NAS
# read-only: it carries the source host's app scripts, whose `backup` writes the source host's
# mirrors, and a read-only mount makes that impossible. Restore only reads the mirrors.
SPEC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/host.toml"
NFS_MODE=rw
if [ -f "$SPEC" ] && python3 -c 'import sys, tomllib; sys.exit(0 if tomllib.load(open(sys.argv[1], "rb")).get("replica") else 1)' "$SPEC"; then
    NFS_MODE=ro
    log_info "Replica host: NAS docker shares are mounted read-only"
fi

# Use IP (10.0.0.24) not hostname 'nas' so NFS mounts work before DNS is available.
# An existing entry with the other mode is replaced, and a mounted share is remounted.
for share in data1 data2; do
    export_path="10.0.0.24:/mnt/$share/docker"
    mount_point="/mnt/nas/$share/docker"
    line="$export_path $mount_point nfs $NFS_MODE,_netdev,auto,user 0 0"
    if grep -qxF "$line" /etc/fstab; then
        log_warn "NFS mount for $share/docker already in /etc/fstab ($NFS_MODE), skipping..."
        continue
    fi
    if grep -q "^$export_path " /etc/fstab; then
        log_info "Replacing the NFS entry for $share/docker in /etc/fstab ($NFS_MODE)..."
        sed -i "\\#^$export_path #d" /etc/fstab
        echo "$line" >> /etc/fstab
        if mountpoint -q "$mount_point"; then
            umount "$mount_point" || log_warn "Could not unmount $mount_point to change its mode"
        fi
    else
        log_info "Adding NFS mount for $share/docker to /etc/fstab ($NFS_MODE)..."
        echo "$line" >> /etc/fstab
    fi
done
systemctl daemon-reload

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

