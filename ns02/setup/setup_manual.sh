#!/bin/bash
# Run manual storage setup: iSCSI connect.
# Usage: ~/setup_manual.sh  (or sudo ~/setup_manual.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/setup_iscsi_connect.sh" ] || SCRIPT_DIR="$HOME/scripts/ns02/setup"

echo "=============================================="
echo "  Manual storage setup (iSCSI)"
echo "=============================================="
echo ""

read -r -p "Run iSCSI connect (discovery, login, mount)? [Y/n]: " DO_ISCSI
if ! echo "${DO_ISCSI}" | grep -qi '^n'; then
  echo ""
  sudo "$SCRIPT_DIR/setup_iscsi_connect.sh"
  echo ""
else
  echo "Skipped iSCSI."
  echo ""
fi

echo "Done. iSCSI: /mnt/docker"
