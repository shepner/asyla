#!/bin/bash
# Full build script for d03 VM
# This script performs a complete build test from scratch

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

log_step "Starting Full Build Test for d03 VM"

# Step 1: Verify cloud-init user-data file exists locally
log_step "Step 1: Verify cloud-init user-data file"
if [ ! -f "$CLOUD_INIT_FILE" ]; then
    log_error "Cloud-init user-data file not found: $CLOUD_INIT_FILE"
    exit 1
fi
log_info "Cloud-init user-data file found: $CLOUD_INIT_FILE"

# Step 2: Copy cloud-init user-data to Proxmox host
log_step "Step 2: Copy cloud-init user-data to Proxmox"
log_info "Copying $CLOUD_INIT_FILE to root@$PROXMOX_HOST:$SNIPPETS_PATH"
scp "$CLOUD_INIT_FILE" "root@$PROXMOX_HOST:$SNIPPETS_PATH" || {
    log_error "Failed to copy cloud-init user-data file"
    exit 1
}
log_info "Cloud-init user-data file copied successfully"

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

# Step 13: Wait for VM to boot and cloud-init to finish
log_step "Step 13: Wait for VM to boot"
log_info "Waiting for SSH (docker@10.0.0.62) - cloud-init may take 90–180s..."
for i in $(seq 1 24); do
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no docker@10.0.0.62 "echo ok" 2>/dev/null; then
    log_info "SSH ready after ~$((i*10))s"
    break
  fi
  [ "$i" -eq 24 ] && log_warn "SSH not ready after 240s - check console"
  sleep 10
done

# Step 14: Check if cloud-init is installed (via console if SSH not available)
log_step "Step 14: Verify cloud-init installation"
log_info "Checking if cloud-init is installed and working..."

# Try to check via SSH if possible, otherwise provide console instructions
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@10.0.0.62 "command -v cloud-init >/dev/null 2>&1" 2>/dev/null; then
    log_info "✅ cloud-init is installed"
elif ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@10.0.0.248 "command -v cloud-init >/dev/null 2>&1" 2>/dev/null; then
    log_info "✅ cloud-init is installed (checked via DHCP IP)"
else
    log_warn "⚠️  cloud-init may not be installed"
    log_info "If cloud-init is missing, run from console:"
    echo ""
    echo "  apt-get update && apt-get install -y cloud-init"
    echo "  mkdir -p /var/lib/cloud/seed/nocloud"
    echo "  curl -s https://raw.githubusercontent.com/shepner/asyla/master/d03/setup/cloud-init-userdata.yml > /var/lib/cloud/seed/nocloud/user-data"
    echo "  cloud-init clean && cloud-init init --local && cloud-init init && cloud-init modules --mode config && cloud-init modules --mode final"
    echo ""
    log_info "Or use the automated bootstrap script:"
    echo "  curl -s https://raw.githubusercontent.com/shepner/asyla/master/d03/setup/bootstrap_complete.sh | bash"
    echo ""
fi

# Step 15: Test SSH access
log_step "Step 15: Test SSH access"
log_info "Attempting SSH connection to docker@10.0.0.62..."
if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no docker@10.0.0.62 "echo 'SSH connection successful!'" 2>/dev/null; then
    log_info "✅ SSH access working!"
elif ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no docker@10.0.0.248 "echo 'SSH connection successful!'" 2>/dev/null; then
    log_info "✅ SSH access working (via DHCP IP 10.0.0.248)"
    log_warn "⚠️  VM is using DHCP IP instead of static 10.0.0.62"
else
    log_warn "SSH not ready yet - cloud-init may still be processing"
    log_info "Check console or try: ssh docker@10.0.0.62 (or ssh root@10.0.0.248 if using DHCP)"
fi

# Step 15: Verify configuration on VM
log_step "Step 15: Verify VM configuration"
log_info "Checking docker user configuration..."
ssh -o ConnectTimeout=10 docker@10.0.0.62 "
echo '=== Docker User Info ==='
id docker
echo ''
echo '=== Groups ==='
groups docker
echo ''
echo '=== Network Configuration ==='
ip addr show | grep 'inet ' | grep -v '127.0.0.1'
ip route show | grep default
cat /etc/resolv.conf
echo ''
echo '=== Setup Scripts ==='
ls -la ~/scripts/d03/setup/ 2>/dev/null | head -10 || echo 'Scripts directory not found yet'
" 2>/dev/null || {
    log_warn "Could not verify configuration - VM may still be initializing"
    log_info "Wait a bit longer and try: ssh docker@10.0.0.62"
}

log_step "Build Complete!"
log_info "VM Status:"
ssh "root@$PROXMOX_HOST" "qm status $VMID"
echo ""
log_info "Next steps:"
echo "  1. SSH to VM: ssh docker@10.0.0.62"
echo "  2. Verify configuration: id docker && groups docker"
echo "  3. Copy SSH private key: scp ~/.ssh/docker_rsa d03:.ssh/docker_rsa"
echo "  4. Copy SSH config: scp ~/.ssh/config d03:.ssh/config"
echo "  5. Run setup scripts: ~/scripts/d03/setup/*.sh"
