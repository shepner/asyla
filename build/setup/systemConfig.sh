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

# journald: on disk, at most 1G. Left to its defaults the cap is 10% of the file system, worked out
# when journald starts (https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html):
# 282M on hosts that last started it on their first boot, before the root disk grew, and 3.2G-4G
# after a reboot (read on d01-ns02, 2026-10-20). At about 40M a day 1G keeps 3-4 weeks; the log
# platform keeps the long history. Operator, 2026-10-20 (asyla backlog
# 2026-10-20-hosts-observability-through-theorg, hygiene).
JOURNALD_CONF=/etc/systemd/journald.conf.d/50-asyla.conf
JOURNALD_WANT='[Journal]
Storage=persistent
SystemMaxUse=1G'
if [ "$(cat "$JOURNALD_CONF" 2>/dev/null)" != "$JOURNALD_WANT" ]; then
    log_info "Writing $JOURNALD_CONF (persistent, SystemMaxUse=1G) and restarting journald..."
    install -d -m 755 /etc/systemd/journald.conf.d
    printf '%s\n' "$JOURNALD_WANT" > "$JOURNALD_CONF"
    chmod 644 "$JOURNALD_CONF"
    install -d -m 2755 -g systemd-journal /var/log/journal
    systemctl restart systemd-journald
fi

# Update package lists
log_info "Updating package lists..."
apt update

# Install and start QEMU guest agent first (for Proxmox) so it's available before long upgrade.
# rsync is needed for the daily Plex (and other app) backup snapshots and for the
# app-migration script (sudoers for /usr/bin/rsync is configured below).
log_info "Installing QEMU guest agent and rsync..."
apt install -y qemu-guest-agent rsync
systemctl enable qemu-guest-agent
systemctl start qemu-guest-agent

# Perform system upgrade (non-interactive)
log_info "Upgrading system packages..."
DEBIAN_FRONTEND=noninteractive apt upgrade -y

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

