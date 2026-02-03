#!/bin/bash
# Complete bootstrap script for d03 VM
# This script handles everything including installing cloud-init if needed
# Can be run manually or via Proxmox cloud-init runcmd

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

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

log_step "Starting Complete Bootstrap for d03 VM"

# Step 1: Install cloud-init if not present
log_step "Step 1: Install cloud-init"
if ! command -v cloud-init >/dev/null 2>&1; then
    log_info "cloud-init not found, installing..."
    apt-get update
    apt-get install -y cloud-init
    log_info "cloud-init installed successfully"
else
    log_info "cloud-init already installed: $(cloud-init --version)"
fi

# Step 2: Fetch our full cloud-init user-data
log_step "Step 2: Fetch cloud-init user-data"
mkdir -p /var/lib/cloud/seed/nocloud
log_info "Downloading user-data from GitHub..."
curl -s https://raw.githubusercontent.com/shepner/asyla/master/d03/setup/cloud-init-userdata.yml > /var/lib/cloud/seed/nocloud/user-data || {
    log_error "Failed to download user-data"
    exit 1
}
log_info "User-data downloaded successfully"

# Step 3: Process cloud-init user-data
log_step "Step 3: Process cloud-init user-data"
log_info "Resetting cloud-init state..."
cloud-init clean -s || true

log_info "Running cloud-init..."
cloud-init init --local
cloud-init init
cloud-init modules --mode config
cloud-init modules --mode final

# Step 4: Verify setup
log_step "Step 4: Verify Setup"
log_info "Checking docker user..."
if id docker >/dev/null 2>&1; then
    log_info "✅ Docker user exists: $(id docker)"
else
    log_error "❌ Docker user not created"
    exit 1
fi

log_info "Checking SSH service..."
if systemctl is-active --quiet ssh || systemctl is-active --quiet sshd; then
    log_info "✅ SSH service is running"
else
    log_warn "⚠️  SSH service not running, starting..."
    systemctl start ssh || systemctl start sshd || true
fi

log_info "Checking network..."
if ip addr show ens18 | grep -q "10.0.0.62"; then
    log_info "✅ Network configured correctly (10.0.0.62)"
else
    CURRENT_IP=$(ip addr show ens18 | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    log_warn "⚠️  Network IP is $CURRENT_IP (expected 10.0.0.62)"
    log_info "Network may need manual configuration or reboot"
fi

log_step "Bootstrap Complete!"
log_info "Next steps:"
log_info "  1. SSH to VM: ssh docker@10.0.0.62"
log_info "  2. Copy SSH private key: scp ~/.ssh/docker_rsa d03:.ssh/docker_rsa"
log_info "  3. Copy SSH config: scp ~/.ssh/config d03:.ssh/config"
log_info "  4. Run setup scripts: ~/scripts/d03/setup/*.sh"
