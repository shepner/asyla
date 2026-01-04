#!/bin/bash
# Configure the system for Debian 13 (Trixie)
# This script performs basic system configuration including updates and QEMU guest agent

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

log_info "Starting system configuration..."

# Update package lists
log_info "Updating package lists..."
apt update

# Perform system upgrade (non-interactive)
log_info "Upgrading system packages..."
DEBIAN_FRONTEND=noninteractive apt upgrade -y

# Install QEMU guest agent for Proxmox integration
log_info "Installing QEMU guest agent..."
apt install -y qemu-guest-agent

# Enable and start QEMU guest agent
log_info "Enabling QEMU guest agent service..."
systemctl enable qemu-guest-agent
systemctl start qemu-guest-agent

# Configure automatic security updates (unattended-upgrades)
log_info "Configuring automatic security updates..."
apt install -y unattended-upgrades

# Configure unattended-upgrades to automatically install security updates
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

# Enable automatic updates
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Clean up package cache and remove unused packages
log_info "Cleaning up package cache and removing unused packages..."
apt autoremove -y
apt autoclean

# Disable any unnecessary services that may have been installed
log_info "Checking for unnecessary services to disable..."

# List of services to check and potentially disable (add as needed)
# Example: systemctl disable <service-name> 2>/dev/null || true

log_info "System configuration complete!"

# Display status
log_info "QEMU guest agent status:"
systemctl status qemu-guest-agent --no-pager -l || true

log_info "Automatic updates status:"
systemctl status unattended-upgrades --no-pager -l || true

log_info "System configuration completed successfully!"

