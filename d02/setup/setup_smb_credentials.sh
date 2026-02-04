#!/bin/bash
# Create ~/.smbcredentials and optionally mount the SMB share.
# Run on the VM as user docker: ~/setup_manual.sh  (or ~/scripts/d02/setup/setup_smb_credentials.sh)

set -euo pipefail

CREDFILE="${HOME}/.smbcredentials"
MOUNT_POINT="/mnt/nas/data1/media"

echo "SMB credentials → $CREDFILE"
echo ""

read -r -p "SMB username: " SMB_USER
read -r -p "SMB domain (optional): " SMB_DOMAIN
read -r -s -p "SMB password: " SMB_PASS
echo ""

if [ -z "$SMB_USER" ] || [ -z "$SMB_PASS" ]; then
  echo "Username and password are required. Exiting."
  exit 1
fi

printf 'username=%s\npassword=%s\ndomain=%s\n' "$SMB_USER" "$SMB_PASS" "${SMB_DOMAIN:-}" > "$CREDFILE"
chmod 600 "$CREDFILE"
echo "Created $CREDFILE (mode 600)."

read -r -p "Mount SMB share now? [Y/n]: " DO_MOUNT
if echo "${DO_MOUNT}" | grep -qi '^n'; then
  echo "Skipped mount. To mount later: sudo mount $MOUNT_POINT"
else
  if sudo mount "$MOUNT_POINT" 2>/dev/null; then
    echo "Mount successful: $MOUNT_POINT"
    mountpoint -q "$MOUNT_POINT" && df -h "$MOUNT_POINT" | tail -1
  elif mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "Mount successful (already mounted): $MOUNT_POINT"
    df -h "$MOUNT_POINT" | tail -1
  else
    echo "Mount failed. Check credentials and try: sudo mount $MOUNT_POINT"
    exit 1
  fi
fi
