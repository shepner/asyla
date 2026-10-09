#!/bin/bash
# Configure NFS client for Debian 13 (Trixie)
# Sets up NFS mounts for Docker backup storage

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

log_info "Starting NFS client configuration..."

apt update
log_info "Installing NFS client utilities..."
apt install -y nfs-common

log_info "Creating NFS mount points..."
mkdir -p /mnt/nas/data1/docker
mkdir -p /mnt/nas/data2/docker
# Never on a mounted NAS share (a re-run would change the shared directory every host backs up to).
for mount_point in /mnt/nas/data1/docker /mnt/nas/data2/docker; do
    if ! mountpoint -q "$mount_point"; then
        chown docker:asyla "$mount_point"
        chmod 755 "$mount_point"
    fi
done

# Use IP (10.0.0.24) not hostname 'nas' so NFS mounts work before DNS is available.
if ! grep -q "10.0.0.24:/mnt/data1/docker" /etc/fstab; then
    log_info "Adding NFS mount for data1/docker to /etc/fstab..."
    echo "10.0.0.24:/mnt/data1/docker /mnt/nas/data1/docker nfs rw,_netdev,auto,user 0 0" >> /etc/fstab
fi
if ! grep -q "10.0.0.24:/mnt/data2/docker" /etc/fstab; then
    log_info "Adding NFS mount for data2/docker to /etc/fstab..."
    echo "10.0.0.24:/mnt/data2/docker /mnt/nas/data2/docker nfs rw,_netdev,auto,user 0 0" >> /etc/fstab
fi

log_info "Attempting to mount NFS shares..."
for mount_point in "/mnt/nas/data1/docker" "/mnt/nas/data2/docker"; do
    if mountpoint -q "$mount_point" 2>/dev/null; then
        log_info "✅ $mount_point already mounted"
    elif mount "$mount_point" 2>/dev/null; then
        log_info "✅ Successfully mounted $mount_point"
    else
        log_warn "⚠️  Could not mount $mount_point (network may not be ready)"
    fi
done

apt autoremove -y
apt autoclean

log_info "NFS client configuration completed successfully!"
