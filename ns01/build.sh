#!/bin/bash
# Full build script for ns01 VM
#
# Purpose: Destroy and recreate VM 300 on Proxmox (vmh01), import Debian cloud image,
#          configure cloud-init (vendor runs install), and verify SSH and software.
# Usage:   ./ns01/build.sh   (from repo root or ns01/)
# Requires: SSH access to root@vmh01, ns01 in ~/.ssh/config (HostName 10.0.0.10, User docker),
#           and ~/.ssh/docker_rsa.pub for cloud-init.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step() { echo -e "\n${BLUE}=== $1 ===${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMID=300
VM_NAME="ns01"
PROXMOX_HOST="vmh01"
IMAGE_PATH="/mnt/nas/data1/iso/template/iso/debian-13-generic-amd64.qcow2"
IMAGE_PATH_FALLBACK="/mnt/nas/data1/iso/template/iso/debian-13-nocloud-amd64.qcow2"
CLOUD_INIT_FILE="$SCRIPT_DIR/setup/cloud-init-userdata.yml"
CLOUD_INIT_VENDOR_FILE="$SCRIPT_DIR/setup/cloud-init-vendor.yml"
SNIPPETS_PATH="/var/lib/vz/snippets/ns01-cloud-init.yml"
VM_HOST="ns01"
VM_SSH_OPTS="-o StrictHostKeyChecking=no"

log_step "Starting Full Build for ns01 VM"

log_step "Step 1: Verify cloud-init user-data file"
[ -f "$CLOUD_INIT_FILE" ] || { log_error "Cloud-init user-data file not found: $CLOUD_INIT_FILE"; exit 1; }
log_info "Cloud-init user-data file found"

log_step "Step 2: Copy cloud-init files to Proxmox"
scp "$CLOUD_INIT_FILE" "root@$PROXMOX_HOST:$SNIPPETS_PATH" || { log_error "Failed to copy cloud-init user-data file"; exit 1; }
log_info "Cloud-init user-data file copied successfully"

log_step "Step 3: Clean up existing VM (if any)"
ssh "root@$PROXMOX_HOST" "qm stop $VMID 2>/dev/null || true" && sleep 2
ssh "root@$PROXMOX_HOST" "qm destroy $VMID --purge 2>/dev/null || true"
log_info "Existing VM cleaned up (if it existed)"

log_step "Step 4: Create new VM"
ssh "root@$PROXMOX_HOST" "qm create $VMID \
  --name $VM_NAME \
  --sockets 2 \
  --cores 2 \
  --memory 2048 \
  --ostype l26 \
  --scsihw virtio-scsi-pci \
  --net0 virtio,bridge=vmbr1,firewall=1,tag=100 \
  --onboot 1 \
  --numa 0 \
  --agent 1,fstrim_cloned_disks=1" || { log_error "Failed to create VM"; exit 1; }
log_info "VM created successfully"

log_step "Step 5: Verify cloud image exists"
IMAGE_DIR=$(dirname "$IMAGE_PATH")
FINAL_IMAGE_PATH=$(ssh "root@$PROXMOX_HOST" "
set -e
if [ -f \"$IMAGE_PATH\" ]; then echo \"$IMAGE_PATH\"; exit 0; fi
if [ -d \"$IMAGE_DIR\" ]; then
  wget -q -O \"$IMAGE_PATH\" https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2 && echo \"$IMAGE_PATH\" && exit 0
  rm -f \"$IMAGE_PATH\" 2>/dev/null || true
fi
if [ -f \"$IMAGE_PATH_FALLBACK\" ]; then echo \"$IMAGE_PATH_FALLBACK\"; exit 0; fi
echo 'ERROR: No cloud image found'; exit 1
") || { log_error "Could not obtain cloud image"; exit 1; }
echo "$FINAL_IMAGE_PATH" | grep -q "ERROR" && { log_error "Cloud image not found"; exit 1; }
[ "$FINAL_IMAGE_PATH" = "$IMAGE_PATH_FALLBACK" ] && log_warn "Using nocloud image; VM may need manual bootstrap if cloud-init is missing"
log_info "Using cloud image: $FINAL_IMAGE_PATH"
IMAGE_PATH="$FINAL_IMAGE_PATH"

log_step "Step 6: Import Debian cloud image"
ssh "root@$PROXMOX_HOST" "qm disk import $VMID \"$IMAGE_PATH\" nas-data1-vm --format qcow2" || { log_error "Failed to import cloud image"; exit 1; }
log_info "Cloud image imported successfully"

log_step "Step 7: Configure disk"
ssh "root@$PROXMOX_HOST" "qm set $VMID --scsi0 nas-data1-vm:$VMID/vm-$VMID-disk-0.qcow2,discard=on,ssd=1 && qm resize $VMID scsi0 64G" || { log_error "Failed to configure disk"; exit 1; }
log_info "Disk configured and resized to 64GB"

log_step "Step 7b: Add cloud-init drive"
ssh "root@$PROXMOX_HOST" "qm set $VMID --scsi1 nas-data1-vm:cloudinit" || { log_error "Failed to add cloud-init drive"; exit 1; }
log_info "Cloud-init drive added (scsi1)"

log_step "Step 8: Configure VGA"
ssh "root@$PROXMOX_HOST" "qm set $VMID --vga std" || { log_error "Failed to configure VGA"; exit 1; }

log_step "Step 9: Configure cloud-init"
scp "$CLOUD_INIT_VENDOR_FILE" "root@$PROXMOX_HOST:/var/lib/vz/snippets/ns01-cloud-init-vendor.yml" || { log_error "Failed to copy vendor file"; exit 1; }
SSH_PUB_KEY="$HOME/.ssh/docker_rsa.pub"
[ -f "$SSH_PUB_KEY" ] || { log_error "SSH public key not found: $SSH_PUB_KEY"; exit 1; }
scp "$SSH_PUB_KEY" "root@$PROXMOX_HOST:/tmp/docker_rsa.pub" || { log_error "Failed to copy SSH public key"; exit 1; }
ssh "root@$PROXMOX_HOST" "
qm set $VMID --ciuser docker && \
qm set $VMID --cipassword \$(openssl passwd -6 TempPassword123!) && \
qm set $VMID --sshkeys /tmp/docker_rsa.pub && \
qm set $VMID --ipconfig0 ip=10.0.0.10/24,gw=10.0.0.1 && \
qm set $VMID --nameserver '10.0.0.10 10.0.0.11' && \
qm set $VMID --searchdomain asyla.org && \
qm set $VMID --cicustom vendor=local:snippets/ns01-cloud-init-vendor.yml && \
qm cloudinit update $VMID && rm -f /tmp/docker_rsa.pub
" || { log_error "Failed to configure cloud-init"; exit 1; }
log_info "Cloud-init configured"

log_step "Step 10: Set boot order"
ssh "root@$PROXMOX_HOST" "qm set $VMID --boot order=scsi0" || { log_error "Failed to set boot order"; exit 1; }

log_step "Step 11: Start VM"
ssh "root@$PROXMOX_HOST" "qm start $VMID" || { log_error "Failed to start VM"; exit 1; }
log_info "VM started successfully"

log_step "Step 12: Wait for VM to boot"
log_info "Waiting for SSH (ns01) - checking once per minute, max 20 min..."
for i in $(seq 1 20); do
  if ssh $VM_SSH_OPTS -o ConnectTimeout=5 "$VM_HOST" "echo ok" 2>/dev/null; then log_info "SSH ready after ~${i} min"; break; fi
  [ "$i" -eq 20 ] && log_warn "SSH not ready after 20 min"
  sleep 60
done

log_step "Step 13: Wait for cloud-init to complete"
SOFTWARE_READY=""
for i in $(seq 1 18); do
  if ssh $VM_SSH_OPTS -o ConnectTimeout=10 "$VM_HOST" "test -f ~/scripts/ns01/setup/docker.sh && command -v docker >/dev/null 2>&1" 2>/dev/null; then
    log_info "Scripts and Docker ready after ~$((i + 2)) min total"; SOFTWARE_READY=1; break
  fi
  sleep 60
done
[ -z "${SOFTWARE_READY:-}" ] && log_warn "Scripts/Docker not ready after 18 min - run deploy_software.sh if needed"

log_step "Step 14: Test SSH access"
ssh $VM_SSH_OPTS -o ConnectTimeout=10 "$VM_HOST" "echo 'SSH connection successful!'" 2>/dev/null && log_info "✅ SSH access working!" || log_warn "SSH not ready yet - try: ssh ns01"

log_step "Step 15: Verify software deployment"
SSH_VERIFY="ssh $VM_SSH_OPTS -o ConnectTimeout=10 ${VM_HOST}"
SOFTWARE_MISSING=""
if $SSH_VERIFY "echo ok" 2>/dev/null; then
  HOSTNAME=$($SSH_VERIFY "hostname -s" 2>/dev/null) || HOSTNAME=""
  [ "$HOSTNAME" = "ns01" ] && log_info "✅ Hostname is ns01" || log_warn "Hostname is '$HOSTNAME' (expected ns01)"
  if ! $SSH_VERIFY "test -f ~/scripts/ns01/setup/docker.sh" 2>/dev/null; then
    log_warn "Setup scripts not found"
    SOFTWARE_MISSING=1
  else
    log_info "✅ Setup scripts at ~/scripts/ns01/setup/"
  fi
  if ! $SSH_VERIFY "docker --version" 2>/dev/null; then
    log_warn "Docker not found"
    SOFTWARE_MISSING=1
  else
    log_info "✅ Docker installed"
  fi
  NFS_COUNT=$($SSH_VERIFY "mount | grep -c nfs || true" 2>/dev/null) || NFS_COUNT=0
  [ "${NFS_COUNT:-0}" -ge 2 ] && log_info "✅ NFS mounts in place ($NFS_COUNT)" || log_warn "NFS mounts: ${NFS_COUNT:-0}"
else
  log_warn "Could not verify - SSH not ready. Try: ssh ns01"
  SOFTWARE_MISSING=1
fi

if [ -n "${SOFTWARE_MISSING:-}" ]; then
  log_step "Step 15b: Deploy software from local repo (cloud-init may have failed e.g. private GitHub)"
  REPO_NS01="$SCRIPT_DIR"
  if [ ! -f "$REPO_NS01/setup/docker.sh" ]; then
    log_error "Local ns01/setup/docker.sh not found at $REPO_NS01 - cannot deploy"
  else
    log_info "Copying ns01 tree to VM..."
    $SSH_VERIFY "mkdir -p ~/scripts" 2>/dev/null || true
    scp $VM_SSH_OPTS -o ConnectTimeout=10 -r "$REPO_NS01" "${VM_HOST}:~/scripts/ns01" 2>/dev/null || { log_error "Failed to SCP ns01 to VM"; exit 1; }
    log_info "Installing update scripts and setting permissions..."
    $SSH_VERIFY "cp ~/scripts/ns01/update.sh ~/scripts/ns01/update_scripts.sh ~/scripts/ns01/update_all.sh ~/ 2>/dev/null; chmod +x ~/scripts/ns01/setup/*.sh ~/scripts/ns01/apps/pihole/pihole.sh ~/scripts/ns01/*.sh 2>/dev/null" 2>/dev/null || true
    log_info "Running systemConfig.sh..."
    $SSH_VERIFY "sudo ~/scripts/ns01/setup/systemConfig.sh" 2>/dev/null || log_warn "systemConfig.sh had warnings"
    log_info "Running nfs.sh..."
    $SSH_VERIFY "sudo ~/scripts/ns01/setup/nfs.sh" 2>/dev/null || log_warn "nfs.sh had warnings"
    log_info "Running iscsi_install.sh..."
    $SSH_VERIFY "sudo ~/scripts/ns01/setup/iscsi_install.sh" 2>/dev/null || log_warn "iscsi_install.sh had warnings"
    log_info "Running docker.sh..."
    $SSH_VERIFY "sudo ~/scripts/ns01/setup/docker.sh" 2>/dev/null || { log_error "docker.sh failed"; exit 1; }
    log_info "Ensuring /mnt/docker exists for Pi-hole..."
    $SSH_VERIFY "sudo mkdir -p /mnt/docker && sudo chown docker:asyla /mnt/docker 2>/dev/null || sudo chown docker:docker /mnt/docker; sudo chmod 755 /mnt/docker" 2>/dev/null || true
    log_info "Linking setup_manual.sh..."
    $SSH_VERIFY "ln -sf ~/scripts/ns01/setup/setup_manual.sh ~/setup_manual.sh" 2>/dev/null || true
    log_info "✅ Software deployed from local repo"
  fi
fi

log_step "Step 16: Copy SSH keys to VM"
SSH_PRIV_KEY="$HOME/.ssh/docker_rsa"
if [ -f "$SSH_PRIV_KEY" ] && $SSH_VERIFY "mkdir -p ~/.ssh && echo ok" 2>/dev/null; then
  if scp $VM_SSH_OPTS -o ConnectTimeout=10 "$SSH_PRIV_KEY" "${VM_HOST}:.ssh/docker_rsa" 2>/dev/null && \
     scp $VM_SSH_OPTS -o ConnectTimeout=10 "$HOME/.ssh/docker_rsa.pub" "${VM_HOST}:.ssh/docker_rsa.pub" 2>/dev/null && \
     ( [ -f "$HOME/.ssh/config" ] && scp $VM_SSH_OPTS -o ConnectTimeout=10 "$HOME/.ssh/config" "${VM_HOST}:.ssh/config" 2>/dev/null || true ); then
    $SSH_VERIFY "chmod 600 ~/.ssh/docker_rsa 2>/dev/null; chmod 644 ~/.ssh/docker_rsa.pub 2>/dev/null; chmod 600 ~/.ssh/config 2>/dev/null; chmod 700 ~/.ssh" 2>/dev/null && log_info "✅ SSH keys and config copied to ns01"
  else
    log_warn "Could not copy SSH keys. Copy manually - see next steps."
  fi
else
  [ ! -f "$SSH_PRIV_KEY" ] && log_warn "Private key not found at $SSH_PRIV_KEY" || log_warn "SSH not ready - copy keys manually once VM is up."
fi

log_step "Step 17: Run setup_ssh_keys and start Pi-hole"
if $SSH_VERIFY "test -f ~/scripts/ns01/setup/setup_ssh_keys.sh" 2>/dev/null; then
  $SSH_VERIFY "~/scripts/ns01/setup/setup_ssh_keys.sh" 2>/dev/null || log_warn "setup_ssh_keys.sh had warnings (e.g. d01/d02/d03 not reachable)"
  if $SSH_VERIFY "test -f ~/scripts/ns01/apps/pihole/pihole.sh" 2>/dev/null; then
    log_info "Starting Pi-hole..."
    $SSH_VERIFY "~/scripts/ns01/apps/pihole/pihole.sh up" 2>/dev/null && log_info "✅ Pi-hole started" || log_warn "Pi-hole start had warnings"
  fi
else
  log_warn "Setup scripts not present - skip setup_ssh_keys and Pi-hole"
fi

log_step "Build Complete!"
ssh "root@$PROXMOX_HOST" "qm status $VMID"
echo ""
log_info "Next steps:"
echo "  1. SSH to VM: ssh ns01"
if $SSH_VERIFY "docker ps --format '{{.Names}}' 2>/dev/null | grep -q pihole-ns01" 2>/dev/null; then
  echo "  2. Pi-hole is running at http://10.0.0.10/admin"
  echo "  3. iSCSI (optional): ~/setup_manual.sh (after adding initiator to TrueNAS for target nas01:ns01:01)"
else
  echo "  2. Start Pi-hole: ~/scripts/ns01/apps/pihole/pihole.sh up"
  echo "  3. iSCSI: ~/setup_manual.sh (after adding initiator to TrueNAS for iSCSI target nas01:ns01:01)"
fi
echo ""
