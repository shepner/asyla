#!/bin/bash
# Ensure /mnt/docker exists as a local directory on the VM root disk (not iSCSI).
# Run from setup_manual.sh, deploy_software.sh, or cloud-init.

set -euo pipefail

MOUNT_POINT="/mnt/docker"

if [ "$EUID" -ne 0 ]; then
  echo "Run as root or with sudo" >&2
  exit 1
fi

if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
  echo "ERROR: $MOUNT_POINT is still a mount point (iSCSI?)." >&2
  echo "Run migrate-docker-off-iscsi.sh first, or unmount manually." >&2
  exit 1
fi

mkdir -p "$MOUNT_POINT"
chown docker:asyla "$MOUNT_POINT"
chmod 755 "$MOUNT_POINT"
echo "Ready: local $MOUNT_POINT on root disk"
