#!/bin/bash
# Check SMB mount status and attempt mount with full error output.
# Use when SMB was configured but mount fails or is not mounted (e.g. after reboot).
# Usage: sudo ~/scripts/d02/setup/check_smb_mount.sh   or  sudo mount /mnt/nas/data1/media

set -euo pipefail

SMB_MOUNT="/mnt/nas/data1/media"

echo "SMB mount check for $SMB_MOUNT"
echo ""

if mountpoint -q "$SMB_MOUNT" 2>/dev/null; then
    echo "OK: $SMB_MOUNT is mounted"
    df -h "$SMB_MOUNT"
    exit 0
fi

echo "Not mounted. Checking configuration..."

if ! grep "/mnt/nas/data1/media" /etc/fstab 2>/dev/null | grep -q "cifs"; then
    echo "ERROR: No SMB entry in /etc/fstab. Run: sudo ~/scripts/d02/setup/smb.sh"
    exit 1
fi
echo "  fstab: OK"

CRED="/home/docker/.smbcredentials"
if [ ! -f "$CRED" ]; then
    echo "ERROR: Credentials file missing: $CRED"
    echo "  Create it (vi $CRED) with: username=... password=... domain=..."
    exit 1
fi
echo "  credentials file: present"

echo ""
echo "Attempting mount (error output below)..."
mount "$SMB_MOUNT" || true
if mountpoint -q "$SMB_MOUNT" 2>/dev/null; then
    echo "OK: Mounted successfully."
    df -h "$SMB_MOUNT"
    exit 0
fi

echo ""
echo "Mount failed. Common causes:"
echo "  - Wrong username/password in $CRED"
echo "  - NAS unreachable: ping nas  or  ping 10.0.0.24"
echo "  - Share path changed on NAS (expects //nas/media)"
echo "  - SMB dialect: try adding vers=3.0 or vers=2.0 to the fstab options"
exit 1
