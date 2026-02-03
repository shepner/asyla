#!/bin/bash
# Create ~/.smbcredentials and optionally mount the SMB share.
# Run on the VM as user docker: ~/setup_smb_credentials.sh  (or ~/scripts/d03/setup/setup_smb_credentials.sh)

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
if [[ ! "${DO_MOUNT,,}" =~ ^n ]]; then
  if sudo mount "$MOUNT_POINT" 2>/dev/null; then
    echo "Mounted $MOUNT_POINT."
  else
    echo "Mount failed or already mounted. Try: sudo mount $MOUNT_POINT"
  fi
fi
