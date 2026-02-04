#!/bin/bash
# Run manual storage setup: SMB credentials and iSCSI connect.
# Usage: ~/setup_manual.sh  (or sudo ~/setup_manual.sh)
# SMB runs as current user (writes ~/.smbcredentials); iSCSI runs with sudo.

set -euo pipefail

# Resolve script dir: when run as ~/setup_manual.sh (symlink), scripts live in ~/scripts/d02/setup/
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/setup_smb_credentials.sh" ] || SCRIPT_DIR="$HOME/scripts/d02/setup"

echo "=============================================="
echo "  Manual storage setup (SMB + iSCSI)"
echo "=============================================="
echo ""

# --- SMB credentials (interactive) ---
read -r -p "Run SMB credentials setup? [Y/n]: " DO_SMB
if ! echo "${DO_SMB}" | grep -qi '^n'; then
  echo ""
  "$SCRIPT_DIR/setup_smb_credentials.sh"
  echo ""
else
  echo "Skipped SMB."
  echo ""
fi

# --- iSCSI connect (requires sudo) ---
read -r -p "Run iSCSI connect (discovery, login, mount)? [Y/n]: " DO_ISCSI
if ! echo "${DO_ISCSI}" | grep -qi '^n'; then
  echo ""
  sudo "$SCRIPT_DIR/setup_iscsi_connect.sh"
  echo ""
else
  echo "Skipped iSCSI."
  echo ""
fi

echo "Done. SMB: ~/.smbcredentials, mount /mnt/nas/data1/media; iSCSI: /mnt/docker"
