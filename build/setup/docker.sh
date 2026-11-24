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
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
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

# Container logs: the `local` driver, which rotates (json-file, Docker's default, never does:
# https://docs.docker.com/engine/logging/drivers/json-file/). 20m x 5 files, compressed, are the
# driver's own defaults, written out (https://docs.docker.com/engine/logging/drivers/local/).
# `docker logs` and a log shipper that reads through the Docker API (Vector's docker_logs) read it;
# nothing may tail the files on disk. Operator, 2026-10-20 (asyla backlog
# 2026-10-20-hosts-observability-through-theorg, hygiene). Written before Docker is installed, so
# a new host's daemon starts with it. dockerd reads it only at start, and only containers created
# after that take it: on a host that already has containers this step writes nothing and stops,
# since applying it there restarts dockerd (operator approval per host).
DAEMON_JSON=/etc/docker/daemon.json
DAEMON_JSON_WANT='{
  "log-driver": "local",
  "log-opts": { "max-size": "20m", "max-file": "5", "compress": "true" }
}'
if [ "$(cat "$DAEMON_JSON" 2>/dev/null)" != "$DAEMON_JSON_WANT" ]; then
    if command -v docker >/dev/null && [ -n "$(docker ps -aq 2>/dev/null)" ]; then
        log_error "$DAEMON_JSON differs from this build's and the host has containers. Applying it restarts dockerd, so it is not done here: ask the operator (per host), then write it and restart docker."
        exit 1
    fi
    log_info "Writing $DAEMON_JSON (log driver local, 20m x 5)..."
    install -d -m 755 /etc/docker
    printf '%s\n' "$DAEMON_JSON_WANT" > "$DAEMON_JSON"
    chmod 644 "$DAEMON_JSON"
    if systemctl is-active -q docker 2>/dev/null; then
        systemctl restart docker
    fi
fi

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
driver=$(docker info --format '{{.LoggingDriver}}')
if [ "$driver" != "local" ]; then
    log_error "Docker's log driver is $driver, not local ($DAEMON_JSON)"
    exit 1
fi
log_info "✅ Log driver: $driver"

# Clean up package cache
log_info "Cleaning up package cache..."
apt autoremove -y
apt autoclean

log_info "Docker installation completed successfully!"
log_info "Docker version: $(docker --version)"
log_info "Docker Compose version: $(docker compose version)"

