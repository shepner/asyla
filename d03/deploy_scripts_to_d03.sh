#!/bin/bash
# Deploy d03 setup and update scripts from workstation to the d03 VM.
# Use this when cloud-init did not fetch scripts or you prefer to push from repo.
# Run from repo root: ./d03/deploy_scripts_to_d03.sh

set -euo pipefail

HOST="${1:-d03}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "[INFO] Deploying scripts to $HOST (from $REPO_ROOT)..."

# Ensure target dirs exist on VM
ssh "$HOST" "mkdir -p ~/scripts/d03/setup"

# Deploy setup scripts (the five run manually per BUILD_CHECKLIST)
scp "$SCRIPT_DIR/setup/systemConfig.sh" "$SCRIPT_DIR/setup/nfs.sh" \
    "$SCRIPT_DIR/setup/smb.sh" "$SCRIPT_DIR/setup/iscsi_install.sh" "$SCRIPT_DIR/setup/iscsi.sh" \
    "$SCRIPT_DIR/setup/docker.sh" \
    "$SCRIPT_DIR/setup/setup_smb_credentials.sh" "$SCRIPT_DIR/setup/setup_iscsi_connect.sh" \
    "$SCRIPT_DIR/setup/setup_manual.sh" \
    "$HOST:~/scripts/d03/setup/"

# Deploy update scripts to home so ~/update.sh works
scp "$SCRIPT_DIR/update.sh" "$SCRIPT_DIR/update_scripts.sh" "$SCRIPT_DIR/update_all.sh" "$HOST:~/"

# Fix permissions on VM and link SMB credentials script into home
ssh "$HOST" "chmod 744 ~/scripts/d03/setup/*.sh ~/update.sh ~/update_scripts.sh ~/update_all.sh && ln -sf ~/scripts/d03/setup/setup_manual.sh ~/setup_manual.sh"

echo "[INFO] Done. On d03 run: ~/scripts/d03/setup/systemConfig.sh then nfs.sh, smb.sh, iscsi.sh, docker.sh"
echo "[INFO] Manual SMB + iSCSI: ~/setup_manual.sh"
