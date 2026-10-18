#!/bin/bash
# SMB/CIFS mount of the NAS media share at /mnt/nas/data1/media (d01: sonarr, radarr, calibre and
# duplicati's source; d02: Plex's library). Ported from d01/setup/smb.sh for the build (asyla-hosts build/setup/), with
# three changes: the credentials file is the host's [[secret]] (D01_ or D02_SMBCREDENTIALS, installed by the
# build's secrets phase before setup), never an empty template made here; a share that does not
# mount fails this step (an app started on an empty /mnt/nas/data1/media sees an empty library, and
# duplicati would back up an empty source); and no sudoers fragment (only the manual
# setup_smb_credentials.sh used it). A replica never mounts it: refused below. Idempotent; run as root.

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

# A replica (test01 as a d01 replica) runs the source's apps on restored data: with the media share
# mounted they could change the real library. HOST_SPEC: this host's host.toml, sent by the build.
SPEC="${HOST_SPEC:?HOST_SPEC must name the host.toml of this host}"
[ -f "$SPEC" ] || { log_error "HOST_SPEC $SPEC is not a file"; exit 1; }
if python3 -c 'import sys, tomllib; sys.exit(0 if tomllib.load(open(sys.argv[1], "rb")).get("replica") else 1)' "$SPEC"; then
    log_error "Replica host: the NAS media share is never mounted here; leave smb.sh out of its [setup].steps"
    exit 1
fi

NAS_IP="10.0.0.24"   # the IP, as nfs.sh: the mount works before DNS
SHARE="//${NAS_IP}/media"
MOUNT_POINT="/mnt/nas/data1/media"
DOCKER_USER="docker"
DOCKER_HOME=$(getent passwd "$DOCKER_USER" | cut -d: -f6)
if [ -z "$DOCKER_HOME" ]; then
    log_error "User '$DOCKER_USER' does not exist"
    exit 1
fi
CREDENTIALS_FILE="$DOCKER_HOME/.smbcredentials"
if [ ! -s "$CREDENTIALS_FILE" ]; then
    log_error "No credentials at $CREDENTIALS_FILE: the build's secrets phase installs it (the host's DNN_SMBCREDENTIALS)"
    exit 1
fi

log_info "Installing CIFS utilities..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cifs-utils >/dev/null

mkdir -p "$MOUNT_POINT"
if ! mountpoint -q "$MOUNT_POINT"; then   # never change a mounted share
    chown docker:asyla "$MOUNT_POINT"
    chmod 755 "$MOUNT_POINT"
fi

# _netdev and no noauto: mounted at boot. An existing entry for the mount point is replaced.
LINE="$SHARE $MOUNT_POINT cifs rw,uid=1003,gid=1000,credentials=$CREDENTIALS_FILE,_netdev,vers=3.0 0 0"
if grep -qxF "$LINE" /etc/fstab; then
    log_info "SMB mount already in /etc/fstab"
else
    if grep -q "[[:space:]]$MOUNT_POINT[[:space:]]" /etc/fstab; then
        log_info "Replacing the /etc/fstab entry for $MOUNT_POINT"
        sed -i "\\#[[:space:]]$MOUNT_POINT[[:space:]]#d" /etc/fstab
        if mountpoint -q "$MOUNT_POINT"; then
            umount "$MOUNT_POINT" || log_warn "Could not unmount $MOUNT_POINT to change its options"
        fi
    fi
    echo "$LINE" >> /etc/fstab
    log_info "Added the SMB mount to /etc/fstab"
fi
systemctl daemon-reload

if mountpoint -q "$MOUNT_POINT"; then
    log_info "$MOUNT_POINT already mounted"
else
    err=""
    for attempt in 1 2 3 4 5 6; do
        if err=$(mount "$MOUNT_POINT" 2>&1); then
            err=""
            break
        fi
        [ "$attempt" -eq 6 ] || sleep 10
    done
    if [ -n "$err" ] || ! mountpoint -q "$MOUNT_POINT"; then
        log_error "Could not mount $MOUNT_POINT: ${err:-mount reported success but nothing is mounted there}. Check the credentials and the NAS's SMB share. Stopping: the apps need the media share."
        exit 1
    fi
    log_info "Mounted $SHARE at $MOUNT_POINT"
fi
log_info "SMB configuration complete: $MOUNT_POINT (mounted at boot)"
