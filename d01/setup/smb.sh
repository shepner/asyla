#!/bin/bash
# Configure SMB/CIFS client for Debian 13 (Trixie)
# Sets up SMB mount for media storage with credentials file

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

log_info "Starting SMB/CIFS client configuration..."

apt update
log_info "Installing CIFS utilities..."
apt install -y cifs-utils

DOCKER_USER="docker"
DOCKER_HOME=$(getent passwd "$DOCKER_USER" | cut -d: -f6)
if [ -z "$DOCKER_HOME" ]; then
    log_error "User 'docker' does not exist. Please create the user first."
    exit 1
fi

CREDENTIALS_FILE="$DOCKER_HOME/.smbcredentials"
if [ -f "$CREDENTIALS_FILE" ]; then
    log_warn "Credentials file already exists at $CREDENTIALS_FILE"
else
    cat > "$CREDENTIALS_FILE" << 'EOF'
username=
password=
domain=
EOF
    chown "$DOCKER_USER:$DOCKER_USER" "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
    log_info "Created credentials file at $CREDENTIALS_FILE"
fi

mkdir -p /mnt/nas/data1/media
chown docker:asyla /mnt/nas/data1/media
chmod 755 /mnt/nas/data1/media

if ! grep -q "//nas/media" /etc/fstab; then
    log_info "Adding SMB mount to /etc/fstab..."
    echo "//nas/media /mnt/nas/data1/media cifs rw,uid=1003,gid=1000,credentials=$CREDENTIALS_FILE,noauto,user 0 0" >> /etc/fstab
fi

apt autoremove -y
apt autoclean

log_info "SMB/CIFS client configuration completed successfully!"
log_warn "Edit credentials: vi $CREDENTIALS_FILE ; Mount: mount /mnt/nas/data1/media"
