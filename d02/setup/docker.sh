#!/bin/bash
# Install Docker and Docker Compose v2 for Debian 13 (Trixie)
# Uses official Docker repository method

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

log_info "Starting Docker installation..."

# Update package lists
log_info "Updating package lists..."
apt update

# Install prerequisites for Docker repository
log_info "Installing prerequisites..."
apt install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Add Docker's official GPG key
log_info "Adding Docker's official GPG key..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Set up Docker repository for Debian
log_info "Setting up Docker repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package lists again to include Docker repository
log_info "Updating package lists with Docker repository..."
apt update

# Install Docker Engine, CLI, and containerd
log_info "Installing Docker Engine, CLI, and containerd..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable and start Docker service
log_info "Enabling and starting Docker service..."
systemctl enable docker
systemctl start docker

# Add docker user to docker group (if user exists)
if id "docker" &>/dev/null; then
    log_info "Adding docker user to docker group..."
    usermod -aG docker docker
    log_info "User 'docker' added to docker group. User may need to log out and back in for changes to take effect."
else
    log_warn "User 'docker' does not exist. Please create the user first or add manually: usermod -aG docker <username>"
fi

# Verify Docker installation
log_info "Verifying Docker installation..."
docker --version
docker compose version

# Clean up package cache
log_info "Cleaning up package cache..."
apt autoremove -y
apt autoclean

log_info "Docker installation completed successfully!"
log_info "Docker version: $(docker --version)"
log_info "Docker Compose version: $(docker compose version)"

