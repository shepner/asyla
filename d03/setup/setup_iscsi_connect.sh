#!/bin/bash
# Connect to iSCSI target and mount /mnt/docker (after-the-fact).
# Run once initiator is in TrueNAS Initiator Group: ~/setup_manual.sh  (or sudo ~/scripts/d03/setup/setup_iscsi_connect.sh)
# No prompts; assumes open-iscsi is installed.

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root or with sudo" >&2
    exit 1
fi

IP_OF_TARGET="10.0.0.24"
NAME_OF_TARGET="iqn.2005-10.org.freenas.ctl:nas01:d03:01"

echo "This host's initiator (must be in TrueNAS Initiator Group for target nas01:d03:01):"
grep -E "^InitiatorName=" /etc/iscsi/initiatorname.iscsi 2>/dev/null || true
echo ""

echo "Discovering iSCSI target..."
if ! iscsiadm -m discovery -t sendtargets -p "$IP_OF_TARGET" 2>/dev/null; then
    echo "Discovery returned no targets. Add the initiator above to TrueNAS Initiator Group 3, then re-run this script."
    exit 1
fi

echo "Logging in..."
if ! iscsiadm --mode node --targetname "$NAME_OF_TARGET" --portal "$IP_OF_TARGET" --login 2>/dev/null; then
    echo "Login failed. Add the initiator above to TrueNAS Initiator Group 3, then re-run: sudo $0"
    exit 1
fi

echo "Setting automatic on boot..."
iscsiadm -m node -T "$NAME_OF_TARGET" -p "$IP_OF_TARGET" --op update -n node.conn[0].startup -v automatic

echo "Waiting for device..."
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
    echo "No iSCSI block device found. Check: lsblk"
    exit 1
fi

blkid "$ISCSI_DEVICE" >/dev/null 2>&1 || {
    echo "Device $ISCSI_DEVICE is not formatted. Partition and mkfs.ext4, then re-run."
    exit 1
}

ISCSI_PARTITION=""
for part in "${ISCSI_DEVICE}"[0-9]*; do
    [ -b "$part" ] && { ISCSI_PARTITION="$part"; break; }
done

[ -n "$ISCSI_PARTITION" ] || {
    echo "No partition on $ISCSI_DEVICE. Partition and format, then re-run."
    exit 1
}

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

mount /mnt/docker 2>/dev/null || true
echo "Done. /mnt/docker: $(df /mnt/docker 2>/dev/null | tail -1 || echo 'mount with: mount /mnt/docker')"
