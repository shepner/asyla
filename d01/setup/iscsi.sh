#!/bin/bash
# Configure iSCSI initiator for Debian 13 (Trixie)
# Connects to TrueNAS iSCSI target for Docker data storage

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

if [ -t 0 ]; then
    log_warn "============================================================"
    log_warn "⚠️  PRODUCTION SAFETY: TrueNAS iSCSI Verification Required"
    log_warn "Before running this script, verify on TrueNAS (nas01):"
    log_warn "  1. iSCSI target exists: iqn.2005-10.org.freenas.ctl:nas01:d01:01"
    log_warn "  2. Initiator access controls are configured correctly"
    log_warn "  3. Old d01 instance is disconnected"
    log_warn "============================================================"
    read -p "Have you verified TrueNAS iSCSI configuration? (yes/no): " verify_response
    if [ "$verify_response" != "yes" ]; then
        log_error "Please verify TrueNAS configuration before proceeding"
        exit 1
    fi
fi

log_info "Starting iSCSI initiator configuration..."

apt update
log_info "Installing iSCSI initiator..."
apt install -y open-iscsi

systemctl enable iscsid
systemctl start iscsid
sleep 2

IP_OF_TARGET="10.0.0.24"
NAME_OF_TARGET="iqn.2005-10.org.freenas.ctl:nas01:d01:01"
INITIATOR_FILE="/etc/iscsi/initiatorname.iscsi"
if [ -f "$INITIATOR_FILE" ]; then
    log_info "This host's initiator (add to TrueNAS Initiator Group if not already):"
    grep -E "^InitiatorName=" "$INITIATOR_FILE" || true
    if [ -t 0 ]; then
        log_warn "Add this initiator to the target's Initiator Group on TrueNAS, then press Enter..."
        read -r
    fi
fi

log_info "Discovering iSCSI target..."
if ! iscsiadm -m discovery -t sendtargets -p "$IP_OF_TARGET" 2>/dev/null; then
    log_warn "Discovery returned no targets. Add initiator to TrueNAS and re-run this script."
    exit 1
fi

log_info "Connecting to iSCSI target..."
if iscsiadm --mode node --targetname "$NAME_OF_TARGET" --portal "$IP_OF_TARGET" --login; then
    log_info "Successfully connected to iSCSI target"
else
    log_error "Failed to connect to iSCSI target"
    exit 1
fi

iscsiadm -m node -T "$NAME_OF_TARGET" -p "$IP_OF_TARGET" --op update -n node.conn[0].startup -v automatic
sleep 3

ISCSI_DEVICE=""
for device in /dev/sd[b-z] /dev/sd[a-z][a-z]; do
    if [ -b "$device" ]; then
        if ! mountpoint -q "$device" 2>/dev/null && ! grep -q "$device" /etc/fstab 2>/dev/null; then
            [ -z "$ISCSI_DEVICE" ] && ISCSI_DEVICE="$device"
        fi
    fi
done

if [ -z "$ISCSI_DEVICE" ]; then
    log_error "Could not automatically detect iSCSI device"
    exit 1
fi

log_info "Detected iSCSI device: $ISCSI_DEVICE"

if ! blkid "$ISCSI_DEVICE" >/dev/null 2>&1; then
    log_warn "Device $ISCSI_DEVICE does not appear to be formatted"
    exit 1
fi

ISCSI_PARTITION=""
for part in "${ISCSI_DEVICE}"[0-9]*; do
    if [ -b "$part" ]; then
        ISCSI_PARTITION="$part"
        break
    fi
done

if [ -z "$ISCSI_PARTITION" ]; then
    log_warn "No partition found on $ISCSI_DEVICE"
    exit 1
fi

mkdir -p /mnt/docker
chown docker:asyla /mnt/docker
chmod 755 /mnt/docker

if ! grep -q "/mnt/docker" /etc/fstab; then
    UUID=$(blkid -s UUID -o value "$ISCSI_PARTITION")
    if [ -n "$UUID" ]; then
        echo "UUID=$UUID /mnt/docker ext4 _netdev,rw,noauto 0 0" >> /etc/fstab
    else
        echo "$ISCSI_PARTITION /mnt/docker ext4 _netdev,rw,noauto 0 0" >> /etc/fstab
    fi
fi

if mount /mnt/docker 2>/dev/null; then
    chown docker:asyla /mnt/docker
    chmod 755 /mnt/docker
    log_info "Mounted and set /mnt/docker to docker:asyla"
fi

apt autoremove -y
apt autoclean

log_info "iSCSI initiator configuration completed successfully!"
