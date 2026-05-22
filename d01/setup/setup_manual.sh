#!/bin/bash
# Run manual storage setup: SMB credentials.
# Usage: ~/setup_manual.sh

set -euo pipefail

# Resolve script dir: when run as ~/setup_manual.sh (symlink), scripts live in ~/scripts/d01/setup/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/setup_smb_credentials.sh" ] || SCRIPT_DIR="$HOME/scripts/d01/setup"

echo "=============================================="
echo "  Manual storage setup (SMB credentials)"
echo "=============================================="
echo ""

read -r -p "Run SMB credentials setup? [Y/n]: " DO_SMB
if ! echo "${DO_SMB}" | grep -qi '^n'; then
  echo ""
  "$SCRIPT_DIR/setup_smb_credentials.sh"
  echo ""
else
  echo "Skipped SMB."
  echo ""
fi

echo "Done. SMB: ~/.smbcredentials, mount /mnt/nas/data1/media"
