#!/bin/bash
# Update Docker scripts from repository
# Uses sparse git checkout to get only needed files

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

# Re-run as root if needed
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

REPO="shepner/asyla"
HOSTNAME=$(hostname -s)
TARGET_USER="docker"
TARGET_HOME="/home/$TARGET_USER"
TARGET_SCRIPTS="$TARGET_HOME/scripts"
# Use a temp dir for clone so we never wipe the real scripts dir
WORKDIR=$(mktemp -d)

log_info "Updating scripts from repository..."

# Sparse git checkout - only get what we need
log_info "Cloning repository (sparse checkout)..."
git clone --depth 1 --no-checkout --filter=blob:none "https://github.com/$REPO.git" "$WORKDIR"

cd "$WORKDIR"

# Checkout host-specific and docker trees
log_info "Checking out host-specific scripts ($HOSTNAME)..."
git checkout master -- "$HOSTNAME" || log_warn "No $HOSTNAME directory found in repository"

log_info "Checking out docker scripts..."
git checkout master -- docker || log_warn "No docker directory found in repository"

# Install into docker user's home: ~/scripts/d03/ and ~/update*.sh
log_info "Installing scripts to $TARGET_SCRIPTS and $TARGET_HOME..."
mkdir -p "$TARGET_SCRIPTS"
if [ -d "$WORKDIR/$HOSTNAME" ]; then
    cp -r "$WORKDIR/$HOSTNAME" "$TARGET_SCRIPTS/"
    # Copy update scripts to home so ~/update.sh works
    for f in update.sh update_scripts.sh update_all.sh; do
        if [ -f "$TARGET_SCRIPTS/$HOSTNAME/$f" ]; then
            cp "$TARGET_SCRIPTS/$HOSTNAME/$f" "$TARGET_HOME/"
        fi
    done
fi

# Set ownership so docker user can run scripts
if getent passwd "$TARGET_USER" >/dev/null 2>&1; then
    chown -R "$TARGET_USER:" "$TARGET_SCRIPTS" "$TARGET_HOME"/update.sh "$TARGET_HOME"/update_scripts.sh "$TARGET_HOME"/update_all.sh 2>/dev/null || true
fi
find "$TARGET_SCRIPTS" -name "*.sh" -exec chmod 744 {} \;
chmod 744 "$TARGET_HOME"/update.sh "$TARGET_HOME"/update_scripts.sh "$TARGET_HOME"/update_all.sh 2>/dev/null || true

# Link unified manual setup script into docker user's home
if [ -f "$TARGET_SCRIPTS/$HOSTNAME/setup/setup_manual.sh" ]; then
    ln -sf "$TARGET_SCRIPTS/$HOSTNAME/setup/setup_manual.sh" "$TARGET_HOME/setup_manual.sh"
    chown -h "$TARGET_USER:" "$TARGET_HOME/setup_manual.sh" 2>/dev/null || true
fi

# Ensure docker user's .bashrc sources history-search and completion (doskey-like)
if [ -f "$TARGET_SCRIPTS/$HOSTNAME/setup/docker_bashrc_additions.sh" ]; then
    BASHRC="$TARGET_HOME/.bashrc"
    touch "$BASHRC"
    if ! grep -q 'docker_bashrc_additions.sh' "$BASHRC" 2>/dev/null; then
        echo "" >> "$BASHRC"
        echo "# History search (Up/Down by prefix) and completion - asyla d03" >> "$BASHRC"
        echo '[ -f "$HOME/scripts/d03/setup/docker_bashrc_additions.sh" ] && . "$HOME/scripts/d03/setup/docker_bashrc_additions.sh"' >> "$BASHRC"
        log_info "Added history-search and completion to $BASHRC"
    fi
    chown "$TARGET_USER:" "$BASHRC" 2>/dev/null || true
fi

# Clean up temporary clone
log_info "Cleaning up temporary files..."
cd /
rm -rf "$WORKDIR"

log_info "Scripts updated successfully! Setup scripts are in $TARGET_SCRIPTS/$HOSTNAME/setup/"

