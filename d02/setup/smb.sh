#!/bin/bash
# Configure SMB/CIFS client for Debian 13 (Trixie)
# Sets up SMB mount for media storage with credentials file

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

log_info "Starting SMB/CIFS client configuration..."

# Update package lists
log_info "Updating package lists..."
apt update

# Install CIFS utilities
log_info "Installing CIFS utilities..."
apt install -y cifs-utils

# Get docker user home directory
DOCKER_USER="docker"
DOCKER_HOME=$(getent passwd "$DOCKER_USER" | cut -d: -f6)

if [ -z "$DOCKER_HOME" ]; then
    log_error "User 'docker' does not exist. Please create the user first."
    exit 1
fi

# Create SMB credentials file with placeholders (NO ACTUAL CREDENTIALS)
log_info "Creating SMB credentials file with placeholders..."
CREDENTIALS_FILE="$DOCKER_HOME/.smbcredentials"

# Check if credentials file already exists
if [ -f "$CREDENTIALS_FILE" ]; then
    log_warn "Credentials file already exists at $CREDENTIALS_FILE"
    log_warn "Skipping creation to preserve existing credentials"
else
    # Create credentials file with empty placeholders
    cat > "$CREDENTIALS_FILE" << 'EOF'
username=
password=
domain=
EOF
    
    # Set proper ownership and permissions
    chown "$DOCKER_USER:$DOCKER_USER" "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
    
    log_info "Created credentials file at $CREDENTIALS_FILE"
fi

# Create mount point
log_info "Creating SMB mount point..."
mkdir -p /mnt/nas/data1/media

# Set proper ownership and permissions on mount point
chown docker:asyla /mnt/nas/data1/media
chmod 755 /mnt/nas/data1/media

# Check if fstab entry already exists
if grep -q "//nas/media" /etc/fstab; then
    log_warn "SMB mount for //nas/media already exists in /etc/fstab, skipping..."
else
    log_info "Adding SMB mount to /etc/fstab..."
    echo "//nas/media /mnt/nas/data1/media cifs rw,uid=1003,gid=1000,credentials=$CREDENTIALS_FILE,noauto,user 0 0" >> /etc/fstab
fi

# Clean up package cache
log_info "Cleaning up package cache..."
apt autoremove -y
apt autoclean

log_info "SMB/CIFS client configuration completed successfully!"
log_warn "============================================================"
log_warn "⚠️  SECURITY: You MUST edit the credentials file manually!"
log_warn "Run: vi $CREDENTIALS_FILE"
log_warn "Add your actual username, password, and domain"
log_warn "============================================================"
log_info "Credentials file location: $CREDENTIALS_FILE"
log_info "Mount point: /mnt/nas/data1/media"
log_info "To mount manually: mount /mnt/nas/data1/media"

