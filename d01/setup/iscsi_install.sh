#!/bin/bash
# Install open-iscsi and start iscsid (no discovery/login).
# Run during automated setup so the manual step only does connect + mount.

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root or with sudo" >&2
    exit 1
fi

apt-get update -qq
apt-get install -y open-iscsi
systemctl enable iscsid
systemctl start iscsid
