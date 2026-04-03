#!/bin/bash
# Update Docker scripts from repository
# Uses sparse git checkout (GitHub shepner/asyla) plus overlay from GitLab asyla/pihole
# (hosts/<hostname>/), for migrating nameserver trees to the Pi-hole GitLab project.

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
    exec sudo "$0" "$@"
fi

REPO="shepner/asyla"
HOSTNAME=$(hostname -s)
TARGET_USER="docker"
TARGET_HOME="/home/$TARGET_USER"
TARGET_SCRIPTS="$TARGET_HOME/scripts"
WORKDIR=$(mktemp -d)

log_info "Updating scripts from repository..."

log_info "Cloning repository (sparse checkout)..."
git clone --depth 1 --no-checkout --filter=blob:none "https://github.com/$REPO.git" "$WORKDIR"

cd "$WORKDIR"

log_info "Checking out host-specific scripts ($HOSTNAME)..."
git checkout master -- "$HOSTNAME" || log_warn "No $HOSTNAME directory found in repository"

log_info "Checking out docker scripts..."
git checkout master -- docker || log_warn "No docker directory found in repository"

log_info "Installing scripts to $TARGET_SCRIPTS and $TARGET_HOME..."
mkdir -p "$TARGET_SCRIPTS"
if [ -d "$WORKDIR/$HOSTNAME" ]; then
    cp -r "$WORKDIR/$HOSTNAME" "$TARGET_SCRIPTS/"
    for f in update.sh update_scripts.sh update_all.sh; do
        if [ -f "$TARGET_SCRIPTS/$HOSTNAME/$f" ]; then
            cp "$TARGET_SCRIPTS/$HOSTNAME/$f" "$TARGET_HOME/"
        fi
    done
fi

# Overlay from GitLab asyla/pihole: hosts/<hostname>/ mirrors this nameserver (private repo
# returns HTTP 404 without auth — set GITLAB_TOKEN or ~/.config/asyla/gitlab_token).
PIHOLE_GITLAB_REPO="${PIHOLE_GITLAB_REPO:-https://gitlab.com/asyla/pihole.git}"
if [ -z "${GITLAB_TOKEN:-}" ] && [ -f "$TARGET_HOME/.config/asyla/gitlab_token" ]; then
    GITLAB_TOKEN="$(head -1 "$TARGET_HOME/.config/asyla/gitlab_token" | tr -d '\r\n')"
fi
PIHOLE_WORK=$(mktemp -d)
PIHOLE_CLONE_URL="$PIHOLE_GITLAB_REPO"
if [ -n "${GITLAB_TOKEN:-}" ]; then
    if command -v python3 >/dev/null 2>&1; then
        _enc="$(printf '%s' "$GITLAB_TOKEN" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(), safe=''))")"
        PIHOLE_CLONE_URL="https://oauth2:${_enc}@gitlab.com/asyla/pihole.git"
    else
        PIHOLE_CLONE_URL="https://oauth2:${GITLAB_TOKEN}@gitlab.com/asyla/pihole.git"
    fi
fi
if GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$PIHOLE_CLONE_URL" "$PIHOLE_WORK/pihole" 2>/dev/null; then
    if [ -d "$PIHOLE_WORK/pihole/hosts/$HOSTNAME" ]; then
        log_info "Overlaying from GitLab asyla/pihole (hosts/$HOSTNAME/)..."
        mkdir -p "$TARGET_SCRIPTS/$HOSTNAME"
        rsync -a "$PIHOLE_WORK/pihole/hosts/$HOSTNAME/" "$TARGET_SCRIPTS/$HOSTNAME/"
    else
        log_warn "GitLab pihole clone has no hosts/$HOSTNAME/; skipping overlay."
    fi
else
    if [ -z "${GITLAB_TOKEN:-}" ]; then
        log_warn "GitLab pihole clone failed (set GITLAB_TOKEN or $TARGET_HOME/.config/asyla/gitlab_token for private repo)."
    else
        log_warn "GitLab pihole clone failed; keeping GitHub-only tree."
    fi
fi
rm -rf "$PIHOLE_WORK"

if getent passwd "$TARGET_USER" >/dev/null 2>&1; then
    chown -R "$TARGET_USER:" "$TARGET_SCRIPTS" "$TARGET_HOME"/update.sh "$TARGET_HOME"/update_scripts.sh "$TARGET_HOME"/update_all.sh 2>/dev/null || true
fi
find "$TARGET_SCRIPTS" -name "*.sh" -exec chmod 744 {} \;
chmod 744 "$TARGET_HOME"/update.sh "$TARGET_HOME"/update_scripts.sh "$TARGET_HOME"/update_all.sh 2>/dev/null || true

if [ -f "$TARGET_SCRIPTS/$HOSTNAME/setup/setup_manual.sh" ]; then
    ln -sf "$TARGET_SCRIPTS/$HOSTNAME/setup/setup_manual.sh" "$TARGET_HOME/setup_manual.sh"
    chown -h "$TARGET_USER:" "$TARGET_HOME/setup_manual.sh" 2>/dev/null || true
fi

if [ -f "$TARGET_SCRIPTS/$HOSTNAME/setup/docker_bashrc_additions.sh" ]; then
    BASHRC="$TARGET_HOME/.bashrc"
    touch "$BASHRC"
    if ! grep -q 'docker_bashrc_additions.sh' "$BASHRC" 2>/dev/null; then
        echo "" >> "$BASHRC"
        echo "# History search (Up/Down by prefix) and completion - asyla ns02" >> "$BASHRC"
        echo '[ -f "$HOME/scripts/ns02/setup/docker_bashrc_additions.sh" ] && . "$HOME/scripts/ns02/setup/docker_bashrc_additions.sh"' >> "$BASHRC"
        log_info "Added history-search and completion to $BASHRC"
    fi
    chown "$TARGET_USER:" "$BASHRC" 2>/dev/null || true
fi

log_info "Cleaning up temporary files..."
cd /
rm -rf "$WORKDIR"

log_info "Scripts updated successfully! Setup scripts are in $TARGET_SCRIPTS/$HOSTNAME/setup/"
