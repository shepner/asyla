#!/bin/bash
# Prepare a host's data disk and mount it (run as root; the host build calls it).
# Usage: data_disk.sh <proxmox-bus-slot> <mountpoint> [owner:group]
#   e.g. data_disk.sh scsi2 /mnt/docker docker:asyla
# Finds /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-<slot>. A disk with no partition table and no
# filesystem gets one GPT partition with ext4 (label from the mountpoint); a disk that already has
# either is never touched, so re-running on a host with data is safe. Adds fstab by UUID
# (defaults,nofail, as d01/d02 have) and mounts.
set -euo pipefail

slot="${1:?slot, e.g. scsi2}" mnt="${2:?mountpoint}" owner="${3:-docker:asyla}"
[ "$EUID" -eq 0 ] || { echo "[ERROR] run as root" >&2; exit 1; }
disk="/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-$slot"
[ -b "$disk" ] || { echo "[ERROR] no disk at $disk" >&2; exit 1; }
disk=$(readlink -f "$disk")
part="${disk}1"

if [ -z "$(lsblk -no PTTYPE "$disk" | head -1)" ] && [ -z "$(blkid -o value -s TYPE "$disk" 2>/dev/null)" ]; then
  echo "[INFO] $disk is blank: creating GPT + ext4"
  parted -s "$disk" mklabel gpt mkpart primary ext4 0% 100%
  udevadm settle
  mkfs.ext4 -q -L "$(basename "$mnt")" "$part"
elif [ ! -b "$part" ]; then
  echo "[ERROR] $disk is not blank and has no partition 1; not touching it" >&2
  exit 1
else
  echo "[INFO] $disk already has data; leaving it as is"
fi

uuid=$(blkid -o value -s UUID "$part")
[ -n "$uuid" ] || { echo "[ERROR] no filesystem UUID on $part" >&2; exit 1; }
mkdir -p "$mnt"
if ! grep -qE "^UUID=$uuid[[:space:]]" /etc/fstab; then
  if grep -qE "[[:space:]]$mnt[[:space:]]" /etc/fstab; then
    echo "[ERROR] /etc/fstab already mounts something else at $mnt" >&2
    exit 1
  fi
  echo "UUID=$uuid $mnt ext4 defaults,nofail 0 2" >> /etc/fstab
  systemctl daemon-reload
fi
mountpoint -q "$mnt" || mount "$mnt"
chown "$owner" "$mnt"
echo "[OK] $mnt: $(findmnt -no SOURCE,SIZE "$mnt" 2>/dev/null || findmnt -no SOURCE "$mnt")"
