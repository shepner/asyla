#!/bin/bash
# One-time: move /mnt/docker from iSCSI (sdb) to a local directory on /.
# ns01 only. Run: sudo ~/scripts/ns01/setup/migrate-docker-off-iscsi.sh

set -euo pipefail

ISCSI_TARGET="iqn.2005-10.org.freenas.ctl:nas01:ns01:01"
ISCSI_PORTAL="10.0.0.24"
MOUNT_POINT="/mnt/docker"
STAGING="/var/lib/ns01-docker-migrate"
PIHOLE_DIR="$MOUNT_POINT/pihole-ns01"
COMPOSE_HELPER="/home/docker/scripts/ns01/apps/pihole/pihole.sh"

if [ "$EUID" -ne 0 ]; then
  echo "Run with sudo" >&2
  exit 1
fi

copy_pihole_tree() {
  local src="$1" dst="$2"
  mkdir -p "$dst/etc-dnsmasq.d" "$dst/etc-pihole"
  cp -a "$src/etc-dnsmasq.d/." "$dst/etc-dnsmasq.d/"
  shopt -s nullglob
  for f in "$src/etc-pihole/"*; do
    base=$(basename "$f")
    case "$base" in
      pihole-FTL.db|pihole-FTL.db-*)
        echo "Skipping $base (fresh FTL DB will be created on start)"
        ;;
      *)
        cp -a "$f" "$dst/etc-pihole/"
        ;;
    esac
  done
  shopt -u nullglob
}

echo "=== preflight ==="
hostname | grep -q ns01 || { echo "Expected ns01"; exit 1; }
mountpoint -q "$MOUNT_POINT" || { echo "$MOUNT_POINT not mounted"; exit 1; }
findmnt -n -o SOURCE "$MOUNT_POINT" | grep -q "/dev/sd" || {
  echo "$MOUNT_POINT is not a block device mount; already local?"
  findmnt "$MOUNT_POINT"
  exit 1
}
[ -d "$PIHOLE_DIR" ] || { echo "Missing $PIHOLE_DIR"; exit 1; }

USED=$(du -sh "$PIHOLE_DIR" | awk '{print $1}')
AVAIL=$(df -h / | awk 'NR==2 {print $4}')
echo "Pi-hole data: $USED; root avail: $AVAIL"

echo "=== stop pihole ==="
if [ -x "$COMPOSE_HELPER" ]; then
  sudo -u docker "$COMPOSE_HELPER" down || true
else
  docker stop pihole-ns01 2>/dev/null || true
  docker rm -f pihole-ns01 2>/dev/null || true
fi

echo "=== copy to staging on / (excluding pihole-FTL.db*) ==="
rm -rf "$STAGING"
mkdir -p "$STAGING/pihole-ns01"
copy_pihole_tree "$PIHOLE_DIR" "$STAGING/pihole-ns01"
chown -R docker:docker "$STAGING/pihole-ns01"

echo "=== unmount iSCSI docker disk ==="
umount "$MOUNT_POINT"

echo "=== logout iSCSI ==="
iscsiadm --mode node --targetname "$ISCSI_TARGET" --portal "$ISCSI_PORTAL" --logout || true
iscsiadm -m node -T "$ISCSI_TARGET" -p "$ISCSI_PORTAL" --op update -n node.startup -v manual || true
iscsiadm -m node -T "$ISCSI_TARGET" -p "$ISCSI_PORTAL" --op update -n node.conn[0].startup -v manual || true

echo "=== disable iSCSI mount service ==="
systemctl disable --now mount-docker-iscsi.service 2>/dev/null || true

echo "=== remove /mnt/docker from fstab ==="
cp -a /etc/fstab /etc/fstab.bak.$(date +%Y%m%d-%H%M%S)
grep -vE "[[:space:]]${MOUNT_POINT}[[:space:]]" /etc/fstab > /etc/fstab.new
mv /etc/fstab.new /etc/fstab

echo "=== create local /mnt/docker ==="
mkdir -p "$MOUNT_POINT"
chown docker:asyla "$MOUNT_POINT"
chmod 755 "$MOUNT_POINT"
mkdir -p "$PIHOLE_DIR"
copy_pihole_tree "$STAGING/pihole-ns01" "$PIHOLE_DIR"
chown -R docker:docker "$PIHOLE_DIR"

echo "=== start pihole ==="
sudo -u docker "$COMPOSE_HELPER" up -d

echo "=== verify ==="
findmnt "$MOUNT_POINT" && { echo "ERROR: still a mount"; exit 1; } || echo "$MOUNT_POINT is a local directory (good)"
docker ps --filter name=pihole-ns01 --format "{{.Names}} {{.Status}}"
du -sh "$PIHOLE_DIR"
iscsiadm -m session 2>&1 | grep -q ns01 && echo "WARNING: iSCSI session still active" || echo "iSCSI session gone (good)"
echo "Done. Remove staging after verification: rm -rf $STAGING"
