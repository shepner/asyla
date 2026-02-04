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

# Set system timezone to Central
log_info "Setting timezone to America/Chicago..."
timedatectl set-timezone America/Chicago 2>/dev/null || {
  echo "America/Chicago" > /etc/timezone
  dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true
}

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

# Ensure docker user's .ssh directory exists and has correct permissions
log_info "Ensuring docker user SSH directory is configured..."
if [ -d /home/docker ]; then
    mkdir -p /home/docker/.ssh
    chmod 700 /home/docker/.ssh
    chown -R docker:asyla /home/docker/.ssh 2>/dev/null || chown -R docker:docker /home/docker/.ssh 2>/dev/null || true
    
    # Ensure authorized_keys has correct permissions if it exists
    if [ -f /home/docker/.ssh/authorized_keys ]; then
        chmod 600 /home/docker/.ssh/authorized_keys
        chown docker:asyla /home/docker/.ssh/authorized_keys 2>/dev/null || chown docker:docker /home/docker/.ssh/authorized_keys 2>/dev/null || true
    fi
    log_info "✅ Docker user SSH directory configured"
else
    log_warn "⚠️  Docker user home directory not found - SSH keys should be configured manually"
fi

# Add rsync to sudoers for docker user (needed for migration script)
log_info "Configuring sudo access for rsync (needed for app migration)..."
if ! grep -q "^docker.*rsync" /etc/sudoers.d/docker-rsync 2>/dev/null; then
    mkdir -p /etc/sudoers.d
    echo "docker ALL=NOPASSWD:/usr/bin/rsync" > /etc/sudoers.d/docker-rsync
    chmod 440 /etc/sudoers.d/docker-rsync
    log_info "✅ Sudo access for rsync configured"
else
    log_info "✅ Sudo access for rsync already configured"
fi

log_info "System configuration completed successfully!"
log_info ""
log_info "Note: To enable app migration script, ensure SSH keys are configured:"
log_info "  Run: ~/scripts/d03/setup/setup_ssh_keys.sh"
log_info "  Or manually copy SSH keys from workstation (see d03/README.md)"

