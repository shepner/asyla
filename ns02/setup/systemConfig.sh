#!/bin/bash
# Configure the system for Debian 13 (Trixie)
# This script performs basic system configuration including updates and QEMU guest agent

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

log_info "Starting system configuration..."

log_info "Setting timezone to America/Chicago..."
timedatectl set-timezone America/Chicago 2>/dev/null || {
  echo "America/Chicago" > /etc/timezone
  dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true
}

log_info "Updating package lists..."
apt update

log_info "Upgrading system packages..."
DEBIAN_FRONTEND=noninteractive apt upgrade -y

log_info "Installing QEMU guest agent..."
apt install -y qemu-guest-agent

log_info "Enabling QEMU guest agent service..."
systemctl enable qemu-guest-agent
systemctl start qemu-guest-agent

log_info "Configuring automatic security updates..."
apt install -y unattended-upgrades

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

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

log_info "Cleaning up package cache and removing unused packages..."
apt autoremove -y
apt autoclean

log_info "System configuration complete!"

log_info "QEMU guest agent status:"
systemctl status qemu-guest-agent --no-pager -l || true

log_info "Automatic updates status:"
systemctl status unattended-upgrades --no-pager -l || true

log_info "Ensuring docker user SSH directory is configured..."
if [ -d /home/docker ]; then
    mkdir -p /home/docker/.ssh
    chmod 700 /home/docker/.ssh
    chown -R docker:asyla /home/docker/.ssh 2>/dev/null || chown -R docker:docker /home/docker/.ssh 2>/dev/null || true
    if [ -f /home/docker/.ssh/authorized_keys ]; then
        chmod 600 /home/docker/.ssh/authorized_keys
        chown docker:asyla /home/docker/.ssh/authorized_keys 2>/dev/null || chown docker:docker /home/docker/.ssh/authorized_keys 2>/dev/null || true
    fi
    log_info "✅ Docker user SSH directory configured"
else
    log_warn "⚠️  Docker user home directory not found"
fi

log_info "Configuring sudo access for rsync (needed for app migration)..."
if ! grep -q "^docker.*rsync" /etc/sudoers.d/docker-rsync 2>/dev/null; then
    mkdir -p /etc/sudoers.d
    echo "docker ALL=NOPASSWD:/usr/bin/rsync" > /etc/sudoers.d/docker-rsync
    chmod 440 /etc/sudoers.d/docker-rsync
    log_info "✅ Sudo access for rsync configured"
else
    log_info "✅ Sudo access for rsync already configured"
fi

# Free port 53 for Pi-hole (host network): no host service must bind to 53
log_info "Ensuring port 53 is free for Pi-hole container..."
# 1. Disable systemd-resolved stub listener (it uses 127.0.0.53:53)
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  mkdir -p /etc/systemd/resolved.conf.d
  if [ ! -f /etc/systemd/resolved.conf.d/no-stub.conf ]; then
    printf '%s\n' '[Resolve]' 'DNSStubListener=no' > /etc/systemd/resolved.conf.d/no-stub.conf
    log_info "✅ Created /etc/systemd/resolved.conf.d/no-stub.conf"
  fi
  if [ -L /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true
  fi
  systemctl restart systemd-resolved 2>/dev/null || true
fi
# 2. Stop/disable host dnsmasq if present (would bind 0.0.0.0:53)
if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^dnsmasq\.service'; then
  systemctl stop dnsmasq 2>/dev/null || true
  systemctl disable dnsmasq 2>/dev/null || true
  log_info "✅ Disabled host dnsmasq.service"
fi
log_info "✅ Port 53 ready for Pi-hole"

log_info "System configuration completed successfully!"
log_info ""
log_info "Note: To enable app migration script, ensure SSH keys are configured:"
log_info "  Run: ~/scripts/ns02/setup/setup_ssh_keys.sh"
log_info "  Or manually copy SSH keys from workstation (see ns02/README.md)"
