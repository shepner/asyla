#!/bin/bash
# Full build script for d03 VM
#
# Purpose: Destroy and recreate VM 103 on Proxmox, import Debian cloud image,
#          configure cloud-init (vendor runs install), and verify SSH and software.
# Usage:   ./d03/build.sh   (from repo root or d03/)
# Requires: SSH access to root@vmh02, d03 in ~/.ssh/config (HostName 10.0.0.62, User docker),
#           and ~/.ssh/docker_rsa.pub for cloud-init.
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_step() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Configuration - paths relative to this script so build works from repo root or d03/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMID=103
VM_NAME="d03"
PROXMOX_HOST="vmh02"
# Try generic image first (more likely to include cloud-init), fall back to nocloud
IMAGE_PATH="/mnt/nas/data1/iso/template/iso/debian-13-generic-amd64.qcow2"
IMAGE_PATH_FALLBACK="/mnt/nas/data1/iso/template/iso/debian-13-nocloud-amd64.qcow2"
CLOUD_INIT_FILE="$SCRIPT_DIR/setup/cloud-init-userdata.yml"
CLOUD_INIT_VENDOR_FILE="$SCRIPT_DIR/setup/cloud-init-vendor.yml"
SNIPPETS_PATH="/var/lib/vz/snippets/d03-cloud-init.yml"
VM_HOST="d03"
VM_SSH_OPTS="-o StrictHostKeyChecking=no"

log_step "Starting Full Build Test for d03 VM"

# Step 1: Verify cloud-init user-data file exists locally
log_step "Step 1: Verify cloud-init user-data file"
if [ ! -f "$CLOUD_INIT_FILE" ]; then
    log_error "Cloud-init user-data file not found: $CLOUD_INIT_FILE"
    exit 1
fi
log_info "Cloud-init user-data file found: $CLOUD_INIT_FILE"

# Step 2: Copy cloud-init user-data and vendor files to Proxmox host
log_step "Step 2: Copy cloud-init files to Proxmox"
log_info "Copying $CLOUD_INIT_FILE to root@$PROXMOX_HOST:$SNIPPETS_PATH"
scp "$CLOUD_INIT_FILE" "root@$PROXMOX_HOST:$SNIPPETS_PATH" || {
    log_error "Failed to copy cloud-init user-data file"
    exit 1
}
log_info "Cloud-init user-data file copied successfully"
log_info "Note: VM fetches user-data from GitHub (vendor curl). Push cloud-init-userdata.yml to master before rebuild to use local changes."

# Step 3: Stop and destroy existing VM (if it exists)
log_step "Step 3: Clean up existing VM (if any)"
ssh "root@$PROXMOX_HOST" "qm stop $VMID 2>/dev/null || true" && sleep 2
ssh "root@$PROXMOX_HOST" "qm destroy $VMID --purge 2>/dev/null || true"
log_info "Existing VM cleaned up (if it existed)"

# Step 4: Create new VM
log_step "Step 4: Create new VM"
ssh "root@$PROXMOX_HOST" "qm create $VMID \
  --name $VM_NAME \
  --sockets 2 \
  --cores 6 \
  --memory 25600 \
  --ostype l26 \
  --scsihw virtio-scsi-pci \
  --net0 virtio,bridge=vmbr1,firewall=1,tag=100 \
  --onboot 1 \
  --numa 0 \
  --agent 1,fstrim_cloned_disks=1" || {
    log_error "Failed to create VM"
    exit 1
}
log_info "VM created successfully"

# Step 5: Verify cloud image exists (prefer generic - includes cloud-init per Razuuu/Debian-CloudInit-Docs)
log_step "Step 5: Verify cloud image exists"
IMAGE_DIR=$(dirname "$IMAGE_PATH")
FINAL_IMAGE_PATH=$(ssh "root@$PROXMOX_HOST" "
set -e
if [ -f \"$IMAGE_PATH\" ]; then
  echo \"$IMAGE_PATH\"
  exit 0
fi
# Generic missing: try download so cloud-init works (nocloud often lacks cloud-init)
if [ ! -f \"$IMAGE_PATH\" ] && [ -d \"$IMAGE_DIR\" ]; then
  echo 'Downloading debian-13-generic-amd64.qcow2 (includes cloud-init)...' >&2
  if wget -q -O \"$IMAGE_PATH\" \
    https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2; then
    echo \"$IMAGE_PATH\"
    exit 0
  fi
  rm -f \"$IMAGE_PATH\" 2>/dev/null || true
fi
if [ -f \"$IMAGE_PATH_FALLBACK\" ]; then
  echo \"$IMAGE_PATH_FALLBACK\"
  exit 0
fi
echo 'ERROR: No cloud image found'
exit 1
") || {
    log_error "Could not obtain cloud image"
    exit 1
}

if echo "$FINAL_IMAGE_PATH" | grep -q "ERROR"; then
    log_error "Cloud image not found. Searched: $IMAGE_PATH and $IMAGE_PATH_FALLBACK"
    exit 1
fi

if [ "$FINAL_IMAGE_PATH" = "$IMAGE_PATH_FALLBACK" ]; then
    log_warn "Using nocloud image (generic not found/download failed); VM may need manual bootstrap if cloud-init is missing"
fi
log_info "Using cloud image: $FINAL_IMAGE_PATH"

# Update IMAGE_PATH for rest of script
IMAGE_PATH="$FINAL_IMAGE_PATH"

ssh "root@$PROXMOX_HOST" "
echo 'Checking if image includes cloud-init (this may take a moment)...'
if command -v virt-ls >/dev/null 2>&1; then
  if virt-ls -a \"$IMAGE_PATH\" /usr/bin 2>/dev/null | grep -q cloud-init; then
    echo '✅ Image appears to include cloud-init'
  else
    echo '⚠️  WARNING: Image may not include cloud-init'
    echo '   The vendor file will install it automatically if missing'
  fi
else
  echo 'Note: virt-ls not available - skipping cloud-init check in image'
  echo '   Debian cloud images include cloud-init by default'
fi
" || {
    log_warn "Could not verify cloud-init in image (non-fatal)"
}

# Step 6: Import cloud image
log_step "Step 6: Import Debian cloud image"
log_info "This may take a few minutes..."
ssh "root@$PROXMOX_HOST" "qm disk import $VMID \"$IMAGE_PATH\" nas-data1-vm --format qcow2" || {
    log_error "Failed to import cloud image"
    exit 1
}
log_info "Cloud image imported successfully"

# Step 7: Configure disk
log_step "Step 7: Configure disk"
ssh "root@$PROXMOX_HOST" "
qm set $VMID --scsi0 nas-data1-vm:$VMID/vm-$VMID-disk-0.qcow2,discard=on,ssd=1 && \
qm resize $VMID scsi0 64G
" || {
    log_error "Failed to configure disk"
    exit 1
}
log_info "Disk configured and resized to 64GB"

# Step 7b: Add cloud-init drive (required for Proxmox to attach cloud-init ISO)
# See https://github.com/Razuuu/Debian-CloudInit-Docs - without this, cloud-init has no datasource
log_step "Step 7b: Add cloud-init drive"
ssh "root@$PROXMOX_HOST" "qm set $VMID --scsi1 nas-data1-vm:cloudinit" || {
    log_error "Failed to add cloud-init drive"
    exit 1
}
log_info "Cloud-init drive added (scsi1)"

# Step 8: Configure VGA
log_step "Step 8: Configure VGA display"
ssh "root@$PROXMOX_HOST" "qm set $VMID --vga std" || {
    log_error "Failed to configure VGA"
    exit 1
}
log_info "VGA configured for console access"

# Step 9: Configure cloud-init using Proxmox built-in + vendor file
log_step "Step 9: Configure cloud-init"
log_info "Copying vendor file to Proxmox..."
scp "$CLOUD_INIT_VENDOR_FILE" "root@$PROXMOX_HOST:/var/lib/vz/snippets/d03-cloud-init-vendor.yml" || {
    log_error "Failed to copy vendor file"
    exit 1
}

# Copy SSH public key to Proxmox host for cloud-init
log_info "Copying SSH public key to Proxmox host..."
SSH_PUB_KEY="$HOME/.ssh/docker_rsa.pub"
if [ ! -f "$SSH_PUB_KEY" ]; then
    log_error "SSH public key not found: $SSH_PUB_KEY"
    exit 1
fi
scp "$SSH_PUB_KEY" "root@$PROXMOX_HOST:/tmp/docker_rsa.pub" || {
    log_error "Failed to copy SSH public key"
    exit 1
}

log_info "Configuring Proxmox built-in cloud-init options..."
# Use Proxmox's built-in options for basic setup
# These generate an ISO that cloud-init reads when installed
# The vendor file will install cloud-init if missing and process our full config
ssh "root@$PROXMOX_HOST" "
qm set $VMID --ciuser docker && \
qm set $VMID --cipassword '\$(openssl passwd -6 TempPassword123!)' && \
qm set $VMID --sshkeys /tmp/docker_rsa.pub && \
qm set $VMID --ipconfig0 ip=10.0.0.62/24,gw=10.0.0.1 && \
qm set $VMID --nameserver '10.0.0.10 10.0.0.11' && \
qm set $VMID --searchdomain asyla.org && \
qm set $VMID --cicustom vendor=local:snippets/d03-cloud-init-vendor.yml && \
qm cloudinit update $VMID && \
rm -f /tmp/docker_rsa.pub
" || {
    log_error "Failed to configure cloud-init"
    exit 1
}
log_info "Cloud-init configured with Proxmox built-in options + vendor file"

# Step 10: Set boot order
log_step "Step 10: Set boot order"
ssh "root@$PROXMOX_HOST" "qm set $VMID --boot order=scsi0" || {
    log_error "Failed to set boot order"
    exit 1
}
log_info "Boot order set to scsi0 (prevents network boot loop)"

# Step 11: Verify configuration
log_step "Step 11: Verify VM configuration"
ssh "root@$PROXMOX_HOST" "
echo 'VM Configuration:'
qm config $VMID | grep -E '^boot:|^cicustom:|^scsi0:|^net0:' | head -10
"

# Step 12: Start VM
log_step "Step 12: Start VM"
ssh "root@$PROXMOX_HOST" "qm start $VMID" || {
    log_error "Failed to start VM"
    exit 1
}
log_info "VM started successfully"

# Step 13: Wait for VM to boot
log_step "Step 13: Wait for VM to boot"
log_info "Waiting for SSH (d03) - checking once per minute, max 20 min..."
for i in $(seq 1 20); do
  if ssh $VM_SSH_OPTS -o ConnectTimeout=5 "$VM_HOST" "echo ok" 2>/dev/null; then
    log_info "SSH ready after ~${i} min"
    break
  fi
  [ "$i" -eq 20 ] && log_warn "SSH not ready after 20 min - will retry verification at end"
  sleep 60
done

# Step 13b: Wait for cloud-init to finish (userdata runcmd can take 5–15 min after second boot)
log_step "Step 13b: Wait for cloud-init to complete"
log_info "Waiting for cloud-init (scripts/Docker install) - checking every 60s, max 18 min..."
SOFTWARE_READY=""
for i in $(seq 1 18); do
  if ssh $VM_SSH_OPTS -o ConnectTimeout=10 "$VM_HOST" "test -f ~/scripts/d03/setup/docker.sh && command -v docker >/dev/null 2>&1" 2>/dev/null; then
    log_info "Scripts and Docker ready after ~$((i + 2)) min total"
    SOFTWARE_READY=1
    break
  fi
  sleep 60
done
if [ -z "${SOFTWARE_READY:-}" ]; then
  log_warn "Scripts/Docker not ready after 18 min - cloud-init may still be running or run deploy_software.sh"
  # Capture cloud-init logs for debugging (best-effort)
  if ssh $VM_SSH_OPTS -o ConnectTimeout=10 "$VM_HOST" "test -r /var/log/cloud-init-output.log" 2>/dev/null; then
    log_info "Last 80 lines of cloud-init-output.log (for debugging):"
    ssh $VM_SSH_OPTS -o ConnectTimeout=10 "$VM_HOST" "tail -80 /var/log/cloud-init-output.log" 2>/dev/null | sed 's/^/  | /' || true
  fi
  if ssh $VM_SSH_OPTS -o ConnectTimeout=10 "$VM_HOST" "test -r /var/log/cloud-init.log" 2>/dev/null; then
    log_info "Last 40 lines of cloud-init.log:"
    ssh $VM_SSH_OPTS -o ConnectTimeout=10 "$VM_HOST" "tail -40 /var/log/cloud-init.log" 2>/dev/null | sed 's/^/  | /' || true
  fi
fi

# Step 14: Check if cloud-init is installed (via console if SSH not available)
log_step "Step 14: Verify cloud-init installation"
log_info "Checking if cloud-init is installed and working..."

# Try to check via SSH if possible, otherwise provide console instructions
if ssh $VM_SSH_OPTS -o ConnectTimeout=5 "root@${VM_HOST}" "command -v cloud-init >/dev/null 2>&1" 2>/dev/null; then
    log_info "✅ cloud-init is installed"
elif ssh $VM_SSH_OPTS -o ConnectTimeout=5 root@10.0.0.248 "command -v cloud-init >/dev/null 2>&1" 2>/dev/null; then
    log_info "✅ cloud-init is installed (checked via DHCP IP)"
else
    log_warn "cloud-init may not be installed."
    log_info "From VM console (as root), run: curl -s https://raw.githubusercontent.com/shepner/asyla/master/d03/setup/bootstrap.sh | bash"
fi

# Step 15: Test SSH access
log_step "Step 15: Test SSH access"
log_info "Attempting SSH connection to d03..."
if ssh $VM_SSH_OPTS -o ConnectTimeout=10 "$VM_HOST" "echo 'SSH connection successful!'" 2>/dev/null; then
    log_info "✅ SSH access working!"
elif ssh $VM_SSH_OPTS -o ConnectTimeout=10 docker@10.0.0.248 "echo 'SSH connection successful!'" 2>/dev/null; then
    log_info "✅ SSH access working (via DHCP IP 10.0.0.248)"
    log_warn "⚠️  VM is using DHCP IP instead of static 10.0.0.62"
else
    log_warn "SSH not ready yet - cloud-init may still be processing"
    log_info "Check console or try: ssh d03 (or ssh root@10.0.0.248 if using DHCP)"
fi

# Step 16: Verify software deployment (hostname, scripts, Docker)
log_step "Step 16: Verify software deployment"
SSH_VERIFY="ssh $VM_SSH_OPTS -o ConnectTimeout=10 ${VM_HOST}"
if $SSH_VERIFY "echo ok" 2>/dev/null; then
  HOSTNAME=$($SSH_VERIFY "hostname -s" 2>/dev/null) || HOSTNAME=""
  HAS_SCRIPTS=$($SSH_VERIFY "test -f ~/scripts/d03/setup/docker.sh && echo y" 2>/dev/null) || true
  DOCKER_VER=$($SSH_VERIFY "docker --version 2>/dev/null" 2>/dev/null) || true
  if [ "$HOSTNAME" = "d03" ]; then
    log_info "✅ Hostname is d03 (update_scripts.sh can find d03/ in repo)"
  else
    log_warn "Hostname is '$HOSTNAME' (expected d03) - scripts may not have been installed"
  fi
  if [ "$HAS_SCRIPTS" = "y" ]; then
    log_info "✅ Setup scripts installed at ~/scripts/d03/setup/"
  else
    log_warn "Setup scripts not found at ~/scripts/d03/setup/ - update_scripts.sh may have failed"
  fi
  if [ -n "$DOCKER_VER" ]; then
    log_info "✅ Docker installed: $DOCKER_VER"
  else
    log_warn "Docker not found or not in PATH - run: newgrp docker, or log out and back in"
  fi
  # Verify NFS mounts are in place (auto-mounted by nfs.sh)
  NFS_COUNT=$($SSH_VERIFY "mount | grep -c nfs || true" 2>/dev/null) || NFS_COUNT=0
  if [ "${NFS_COUNT:-0}" -ge 2 ]; then
    log_info "✅ NFS mounts in place ($NFS_COUNT mounts)"
    $SSH_VERIFY "mount | grep nfs" 2>/dev/null | sed 's/^/  /' || true
  else
    log_warn "NFS mounts not yet present (expected 2; got ${NFS_COUNT:-0}). They may mount after network is ready, or run: sudo mount -a"
  fi
  # Full config dump if SSH works
  log_info "Configuration snapshot:"
  $SSH_VERIFY "id; groups; ls ~/scripts/d03/setup/ 2>/dev/null | head -15" 2>/dev/null || true
else
  log_warn "Could not verify - SSH not ready. Try: ssh d03"
fi

log_step "Build Complete!"
log_info "VM Status:"
ssh "root@$PROXMOX_HOST" "qm status $VMID"
echo ""

# If verification didn't run (SSH wasn't ready), wait 2 min and retry once
if ! ssh $VM_SSH_OPTS -o ConnectTimeout=5 "$VM_HOST" "echo ok" 2>/dev/null; then
  log_info "SSH not ready at end of build. Waiting 2 min then retrying verification..."
  sleep 120
  log_step "Retry: Verify software deployment"
  SSH_VERIFY="ssh $VM_SSH_OPTS -o ConnectTimeout=10 ${VM_HOST}"
  if $SSH_VERIFY "echo ok" 2>/dev/null; then
    HOSTNAME=$($SSH_VERIFY "hostname -s" 2>/dev/null) || HOSTNAME=""
    HAS_SCRIPTS=$($SSH_VERIFY "test -f ~/scripts/d03/setup/docker.sh && echo y" 2>/dev/null) || true
    DOCKER_VER=$($SSH_VERIFY "docker --version 2>/dev/null" 2>/dev/null) || true
    [ "$HOSTNAME" = "d03" ] && log_info "✅ Hostname is d03" || log_warn "Hostname is '$HOSTNAME' (expected d03)"
    [ "$HAS_SCRIPTS" = "y" ] && log_info "✅ Setup scripts at ~/scripts/d03/setup/" || log_warn "Setup scripts not found"
    [ -n "$DOCKER_VER" ] && log_info "✅ Docker: $DOCKER_VER" || log_warn "Docker not found"
    NFS_COUNT=$($SSH_VERIFY "mount | grep -c nfs || true" 2>/dev/null) || NFS_COUNT=0
    [ "${NFS_COUNT:-0}" -ge 2 ] && log_info "✅ NFS mounts: $NFS_COUNT" || log_warn "NFS mounts: ${NFS_COUNT:-0} (expected 2)"
    $SSH_VERIFY "ls ~/scripts/d03/setup/ 2>/dev/null | head -15" 2>/dev/null || true
  else
    log_warn "SSH still not ready. Try manually in a few min: ssh d03"
  fi
fi

# Step 17: Optional SMB credentials (prompt and push to VM, then mount)
log_step "Step 17: SMB credentials (optional)"
if ssh $VM_SSH_OPTS -o ConnectTimeout=5 "$VM_HOST" "test -d /home/docker" 2>/dev/null; then
  echo ""
  if [ -t 0 ]; then
    read -r -p "Configure SMB mount now? [y/N]: " DO_SMB
  else
    DO_SMB=""
    log_info "No TTY - skipping SMB prompt. To set later: ssh d03, run ~/setup_manual.sh"
  fi
  if echo "${DO_SMB}" | grep -qi '^y'; then
    read -r -p "SMB username: " SMB_USER
    read -r -p "SMB domain: " SMB_DOMAIN
    read -r -s -p "SMB password: " SMB_PASS
    echo ""
    if [ -n "$SMB_USER" ] && [ -n "$SMB_PASS" ]; then
      SMB_TMP=$(mktemp)
      trap 'rm -f "$SMB_TMP"' EXIT
      printf 'username=%s\npassword=%s\ndomain=%s\n' "$SMB_USER" "$SMB_PASS" "${SMB_DOMAIN:-}" > "$SMB_TMP"
      if scp -o StrictHostKeyChecking=no "$SMB_TMP" "${VM_HOST}:/tmp/smbcreds" 2>/dev/null; then
        ssh $VM_SSH_OPTS "$VM_HOST" "sudo mv /tmp/smbcreds /home/docker/.smbcredentials && sudo chown docker:asyla /home/docker/.smbcredentials && sudo chmod 600 /home/docker/.smbcredentials && sudo mount /mnt/nas/data1/media 2>/dev/null && echo 'SMB credentials set and mount successful' || echo 'SMB credentials set; mount may need: sudo mount /mnt/nas/data1/media'" 2>/dev/null && log_info "✅ SMB credentials configured and mount attempted"
      else
        log_warn "Could not copy credentials to VM (SSH/SCP failed). Set manually: ssh d03, run ~/setup_manual.sh"
      fi
      rm -f "$SMB_TMP"
    else
      log_info "Skipped (empty username or password). Set later on d03: ~/setup_manual.sh"
    fi
  else
    log_info "Skipped. To set later: ssh d03, run ~/setup_manual.sh"
  fi
else
  log_info "SSH not available; set SMB later: ssh d03, run ~/setup_manual.sh"
fi

echo ""
log_info "Next steps:"
echo "  1. SSH to VM: ssh d03"
echo "  2. Verify configuration: id docker && groups docker"
echo "  3. Copy SSH private key: scp ~/.ssh/docker_rsa d03:.ssh/docker_rsa"
echo "  4. Copy SSH config: scp ~/.ssh/config d03:.ssh/config"
echo "  5. Manual SMB + iSCSI: ~/setup_manual.sh"
