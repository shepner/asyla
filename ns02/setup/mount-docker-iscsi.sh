#!/bin/bash
# Wait for iSCSI block device (by UUID or device from fstab) then mount /mnt/docker.
# Used by mount-docker-iscsi.service at boot so mount happens after the device appears.

set -euo pipefail

FSTAB_LINE=$(grep -E '[ \t]/mnt/docker[ \t]' /etc/fstab) || exit 1
SPEC=$(echo "$FSTAB_LINE" | awk '{print $1}')
MOUNT_POINT="/mnt/docker"
MAX_WAIT=120
SLEEP=2

if [[ "$SPEC" == UUID=* ]]; then
    UUID="${SPEC#UUID=}"
    DEVICE_PATH="/dev/disk/by-uuid/$UUID"
else
    DEVICE_PATH="$SPEC"
fi

elapsed=0
while [ $elapsed -lt $MAX_WAIT ]; do
    if [ -b "$DEVICE_PATH" ]; then
        break
    fi
    sleep $SLEEP
    elapsed=$((elapsed + SLEEP))
done

if [ ! -b "$DEVICE_PATH" ]; then
    echo "Timeout waiting for $DEVICE_PATH after ${MAX_WAIT}s" >&2
    exit 1
fi

mount "$MOUNT_POINT"
