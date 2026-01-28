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

# Configuration
VMID=103
VM_NAME="d03"
PROXMOX_HOST="vmh02"
IMAGE_PATH="/mnt/nas/data1/iso/template/iso/debian-13-nocloud-amd64.qcow2"
CLOUD_INIT_FILE="d03/setup/cloud-init-userdata.yml"
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

# Step 5: Verify cloud image exists
log_step "Step 5: Verify cloud image exists"
ssh "root@$PROXMOX_HOST" "
if [ ! -f \"$IMAGE_PATH\" ]; then
  echo 'ERROR: Cloud image not found at $IMAGE_PATH'
  echo 'Searching for file...'
  find /mnt -name 'debian-13-nocloud-amd64.qcow2' 2>/dev/null | head -5
  exit 1
fi
echo 'Cloud image found: $IMAGE_PATH'
" || {
    log_error "Cloud image not found"
    exit 1
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

# Step 8: Configure VGA
log_step "Step 8: Configure VGA display"
ssh "root@$PROXMOX_HOST" "qm set $VMID --vga std" || {
    log_error "Failed to configure VGA"
    exit 1
}
log_info "VGA configured for console access"

# Step 9: Configure cloud-init with custom user-data
log_step "Step 9: Configure cloud-init with custom user-data"
ssh "root@$PROXMOX_HOST" "
qm set $VMID --cicustom user=local:snippets/d03-cloud-init.yml && \
qm cloudinit update $VMID
" || {
    log_error "Failed to configure cloud-init"
    exit 1
}
log_info "Cloud-init configured with custom user-data"

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

# Step 13: Wait for cloud-init
log_step "Step 13: Wait for cloud-init to complete"
log_info "Waiting 60 seconds for cloud-init to complete..."
sleep 60

# Step 14: Test SSH access
log_step "Step 14: Test SSH access"
log_info "Attempting SSH connection to docker@10.0.0.62..."
if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no docker@10.0.0.62 "echo 'SSH connection successful!'" 2>/dev/null; then
    log_info "✅ SSH access working!"
else
    log_warn "SSH not ready yet, may need more time for cloud-init"
    log_info "Try manually: ssh docker@10.0.0.62"
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
