#!/bin/bash
# Apply iSCSI fix (open-iscsi override, mount-docker-iscsi, node startup=automatic, NFS IP)
# to d01, d02, d03. Run from workstation (where you have SSH to d01/d02/d03 or docker@IP).
# Usage: ./scripts/apply_iscsi_fix_d01_d02_d03.sh [--reboot]
#   --reboot  Reboot each host after applying (default: just apply, you reboot manually).
# Requires: ssh/scp to each host (e.g. Host d01 in ~/.ssh/config or docker@10.0.0.60).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REBOOT_AFTER=false
[[ "${1:-}" == "--reboot" ]] && REBOOT_AFTER=true

# Prefer IP as SSH target (when SSH config has Host 10.0.0.60 with User docker)
ssh_target() {
    local ip="$1"
    if ssh -o ConnectTimeout=3 -o BatchMode=yes "$ip" "true" 2>/dev/null; then
        echo "$ip"
    else
        echo "docker@$ip"
    fi
}

apply_host() {
    local host="$1"
    local ip="$2"
    local target_iqn="$3"
    local setup_subdir="$4"
    local target
    target="$(ssh_target "$ip")"

    echo "===== $host ($target) ====="
    # Fix NFS fstab: nas -> 10.0.0.24
    ssh "$target" "sudo sed -i 's|nas:|10.0.0.24:|g' /etc/fstab 2>/dev/null; grep -E '10.0.0.24|/mnt/docker' /etc/fstab" || { echo "  SSH failed"; return 1; }

    # Fix /mnt/docker fstab: ensure noauto (remove x-systemd options if present)
    ssh "$target" "sudo sed -i 's|_netdev,rw,x-systemd.requires=iscsid.service,x-systemd.device-timeout=[0-9]*|_netdev,rw,noauto|' /etc/fstab 2>/dev/null; true"

    # Copy repo files into place (so setup_iscsi_connect.sh can install them)
    scp -q "$REPO_ROOT/$setup_subdir/setup/mount-docker-iscsi.sh" "$REPO_ROOT/$setup_subdir/setup/mount-docker-iscsi.service" "$target:~/scripts/$setup_subdir/setup/" 2>/dev/null || true
    ssh "$target" "mkdir -p ~/scripts/$setup_subdir/setup/systemd/open-iscsi.service.d ~/scripts/$setup_subdir/setup/systemd/iscsid.service.d"
    scp -q "$REPO_ROOT/$setup_subdir/setup/systemd/open-iscsi.service.d/override.conf" "$target:~/scripts/$setup_subdir/setup/systemd/open-iscsi.service.d/"
    scp -q "$REPO_ROOT/$setup_subdir/setup/systemd/iscsid.service.d/network-online.conf" "$target:~/scripts/$setup_subdir/setup/systemd/iscsid.service.d/"
    scp -q "$REPO_ROOT/$setup_subdir/setup/setup_iscsi_connect.sh" "$target:~/scripts/$setup_subdir/setup/"

    # Install units and set node to automatic (without requiring login to succeed)
    ssh "$target" 'sudo install -d /etc/systemd/system/open-iscsi.service.d && sudo install -m 644 ~/scripts/'"$setup_subdir"'/setup/systemd/open-iscsi.service.d/override.conf /etc/systemd/system/open-iscsi.service.d/ && sudo systemctl enable open-iscsi.service && sudo install -m 755 ~/scripts/'"$setup_subdir"'/setup/mount-docker-iscsi.sh /usr/local/bin/mount-docker-iscsi.sh && sudo install -d /etc/systemd/system/iscsid.service.d && sudo install -m 644 ~/scripts/'"$setup_subdir"'/setup/systemd/iscsid.service.d/network-online.conf /etc/systemd/system/iscsid.service.d/ && sudo install -m 644 ~/scripts/'"$setup_subdir"'/setup/mount-docker-iscsi.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable mount-docker-iscsi.service'

    # Set node to automatic if node exists
    ssh "$target" "sudo iscsiadm -m node -T $target_iqn -p 10.0.0.24 --op update -n node.conn[0].startup -v automatic 2>/dev/null; sudo iscsiadm -m node -T $target_iqn -p 10.0.0.24 --op update -n node.startup -v automatic 2>/dev/null" || true

    echo "  Config applied. Run setup_iscsi_connect.sh on $host if iSCSI login needed; then reboot."
    if [[ "$REBOOT_AFTER" == true ]]; then
        echo "  Rebooting $host..."
        ssh "$target" "sudo reboot" || true
    fi
}

# Host label, SSH target (IP or hostname), target iqn, path (d01, d02, d03)
# Use IPs if SSH config has Host 10.0.0.60 etc. with User docker and IdentityFile
apply_host d01 10.0.0.60 "iqn.2005-10.org.freenas.ctl:nas01:d01:01" "d01"
apply_host d02 10.0.0.61 "iqn.2005-10.org.freenas.ctl:nas01:d02:01" "d02"
apply_host d03 10.0.0.62 "iqn.2005-10.org.freenas.ctl:nas01:d03:01" "d03"

echo ""
echo "Done. Reboot each host to verify iSCSI login and /mnt/docker mount at boot."
echo "To reboot from this script, run: $0 --reboot"
