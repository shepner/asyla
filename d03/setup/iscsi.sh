#!/bin/bash
# Configure iSCSI initiator for Debian 13 (Trixie)
# Connects to TrueNAS iSCSI target for Docker data storage

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

# Optional interactive verification when running with a TTY
if [ -t 0 ]; then
    log_warn "============================================================"
    log_warn "⚠️  PRODUCTION SAFETY: TrueNAS iSCSI Verification Required"
    log_warn "Before running this script, verify on TrueNAS (nas01):"
    log_warn "  1. iSCSI target exists: iqn.2005-10.org.freenas.ctl:nas01:d03:01"
    log_warn "  2. Initiator access controls are configured correctly"
    log_warn "  3. Old d03 instance is disconnected"
    log_warn "============================================================"
    read -p "Have you verified TrueNAS iSCSI configuration? (yes/no): " verify_response
    if [ "$verify_response" != "yes" ]; then
        log_error "Please verify TrueNAS configuration before proceeding"
        exit 1
    fi
else
    log_info "Non-interactive run: skipping verification prompt."
fi

log_info "Starting iSCSI initiator configuration..."

# Update package lists
log_info "Updating package lists..."
apt update

# Install iSCSI initiator
log_info "Installing iSCSI initiator..."
apt install -y open-iscsi

# Enable and start iscsid service
log_info "Enabling and starting iscsid service..."
systemctl enable iscsid
systemctl start iscsid

# Wait a moment for service to be ready
sleep 2

# Show initiator name so user can add it to TrueNAS before first login
IP_OF_TARGET="10.0.0.24"
NAME_OF_TARGET="iqn.2005-10.org.freenas.ctl:nas01:d03:01"
INITIATOR_FILE="/etc/iscsi/initiatorname.iscsi"
if [ -f "$INITIATOR_FILE" ]; then
    log_info "This host's initiator (add to TrueNAS Initiator Group if not already):"
    grep -E "^InitiatorName=" "$INITIATOR_FILE" || true
    if [ -t 0 ]; then
        log_warn "Add this initiator to the target's Initiator Group on TrueNAS, then press Enter..."
        read -r
    else
        log_info "Non-interactive: proceeding with discovery and login."
    fi
fi

log_info "Discovering iSCSI target..."
if ! iscsiadm -m discovery -t sendtargets -p "$IP_OF_TARGET" 2>/dev/null; then
    log_warn "Discovery returned no targets. Add initiator to TrueNAS and re-run this script."
    exit 1
fi

log_info "Connecting to iSCSI target..."
log_info "Target IP: $IP_OF_TARGET"
log_info "Target Name: $NAME_OF_TARGET"

# Connect to the iSCSI target
if iscsiadm --mode node --targetname "$NAME_OF_TARGET" --portal "$IP_OF_TARGET" --login; then
    log_info "Successfully connected to iSCSI target"
else
    log_error "Failed to connect to iSCSI target"
    log_error "Add this initiator to TrueNAS Initiator Group and re-run: sudo $0"
    exit 1
fi

# Configure automatic connection on boot
log_info "Configuring automatic connection on boot..."
iscsiadm -m node -T "$NAME_OF_TARGET" -p "$IP_OF_TARGET" --op update -n node.conn[0].startup -v automatic

# Wait for device to appear
log_info "Waiting for iSCSI device to appear..."
sleep 3

# Detect iSCSI device
log_info "Detecting iSCSI device..."
# List block devices and find the iSCSI device (usually /dev/sdb, /dev/sdc, etc.)
# Exclude /dev/sda (usually the system disk)
ISCSI_DEVICE=""
for device in /dev/sd[b-z] /dev/sd[a-z][a-z]; do
    if [ -b "$device" ]; then
        # Check if device is an iSCSI device by checking if it's not mounted and not in fstab
        if ! mountpoint -q "$device" 2>/dev/null && ! grep -q "$device" /etc/fstab 2>/dev/null; then
            # Additional check: see if it's a new device
            if [ -z "$ISCSI_DEVICE" ]; then
                ISCSI_DEVICE="$device"
            fi
        fi
    fi
done

if [ -z "$ISCSI_DEVICE" ]; then
    log_error "Could not automatically detect iSCSI device"
    log_error "Please run 'lsblk' or 'fdisk -l' to identify the device"
    log_error "Then manually update /etc/fstab with the correct device"
    exit 1
fi

log_info "Detected iSCSI device: $ISCSI_DEVICE"

# Check if device has a partition table
if ! blkid "$ISCSI_DEVICE" >/dev/null 2>&1; then
    log_warn "Device $ISCSI_DEVICE does not appear to be formatted"
    log_warn "You may need to partition and format it manually:"
    log_warn "  fdisk $ISCSI_DEVICE"
    log_warn "  mkfs.ext4 ${ISCSI_DEVICE}1"
    log_warn "Then re-run this script or manually add to /etc/fstab"
    exit 1
fi

# Find the partition (usually device + 1, e.g., /dev/sdb1)
ISCSI_PARTITION=""
for part in "${ISCSI_DEVICE}"[0-9]*; do
    if [ -b "$part" ]; then
        ISCSI_PARTITION="$part"
        break
    fi
done

if [ -z "$ISCSI_PARTITION" ]; then
    log_warn "No partition found on $ISCSI_DEVICE"
    log_warn "You may need to partition it manually: fdisk $ISCSI_DEVICE"
    log_warn "Then format: mkfs.ext4 ${ISCSI_DEVICE}1"
    log_warn "Then re-run this script or manually add to /etc/fstab"
    exit 1
fi

log_info "Using partition: $ISCSI_PARTITION"

# Create mount point
log_info "Creating mount point..."
mkdir -p /mnt/docker

# Set proper ownership and permissions
chown docker:asyla /mnt/docker
chmod 755 /mnt/docker

# Check if fstab entry already exists
if grep -q "/mnt/docker" /etc/fstab; then
    log_warn "Mount point /mnt/docker already exists in /etc/fstab, skipping..."
else
    log_info "Adding iSCSI mount to /etc/fstab..."
    # Use UUID for more reliable mounting (device names can change)
    UUID=$(blkid -s UUID -o value "$ISCSI_PARTITION")
    if [ -n "$UUID" ]; then
        echo "UUID=$UUID /mnt/docker ext4 _netdev,rw,noauto 0 0" >> /etc/fstab
        log_info "Added mount using UUID: $UUID"
    else
        # Fallback to device name if UUID not available
        echo "$ISCSI_PARTITION /mnt/docker ext4 _netdev,rw,noauto 0 0" >> /etc/fstab
        log_warn "Added mount using device name (UUID not available)"
    fi
fi

# Mount and set ownership so docker user owns the volume root
log_info "Mounting /mnt/docker and setting ownership to docker:asyla..."
if mount /mnt/docker 2>/dev/null; then
    chown docker:asyla /mnt/docker
    chmod 755 /mnt/docker
    log_info "Mounted and set /mnt/docker to docker:asyla"
else
    log_info "Mount skipped or already mounted. After mounting, run: chown docker:asyla /mnt/docker"
fi

# Clean up package cache
log_info "Cleaning up package cache..."
apt autoremove -y
apt autoclean

log_info "iSCSI initiator configuration completed successfully!"
log_info "iSCSI device: $ISCSI_PARTITION"
log_info "Mount point: /mnt/docker (owned by docker:asyla when mounted)"
log_info "To mount manually: mount /mnt/docker && chown docker:asyla /mnt/docker"
log_info "Mount will be available after reboot or manual mount"

