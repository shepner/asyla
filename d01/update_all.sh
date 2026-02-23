#!/bin/bash
# Comprehensive maintenance for this host: update scripts, OS, then backup and upgrade
# each Docker app found under ~/scripts/<host>/apps/ (host = hostname -s, e.g. d01).
# Detects apps automatically
# so no ongoing maintenance when new apps are added.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Re-run as root if needed (for update_scripts.sh and update.sh)
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

if [ -n "${SUDO_USER:-}" ]; then
    HOME_DIR=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    HOME_DIR="$HOME"
fi
HOME_DIR="${HOME_DIR:-/home/docker}"

# Host from hostname so apps path is correct even when script is run via symlink (e.g. ~/update_all.sh)
HOST="$(hostname -s)"
APPS_DIR="$HOME_DIR/scripts/$HOST/apps"

log_info "Starting comprehensive system maintenance (host: $HOST)..."

# Step 1: Update scripts from repository
log_info "Step 1: Updating scripts from repository..."
"$HOME_DIR/update_scripts.sh"

# Step 2: Update OS
log_info "Step 2: Updating operating system..."
"$HOME_DIR/update.sh"

# Step 3: Backup and upgrade each Docker app (run as SUDO_USER so docker compose works)
if [ ! -d "$APPS_DIR" ]; then
    log_warn "No apps directory at $APPS_DIR, skipping app backup/upgrade."
else
    log_info "Step 3: Backing up and upgrading Docker apps..."
    run_as_user() {
        if [ -n "${SUDO_USER:-}" ]; then
            su - "$SUDO_USER" -c "$1"
        else
            bash -c "$1"
        fi
    }

    for app_dir in "$APPS_DIR"/*/; do
        [ -d "$app_dir" ] || continue
        app=$(basename "$app_dir")
        main_script=""
        for f in "$app_dir"*.sh; do
            [ -f "$f" ] || continue
            b=$(basename "$f")
            [[ "$b" == gen-* ]] && continue
            [[ "$b" == generate-* ]] && continue
            [[ "$b" == copy_* ]] && continue
            [[ "$b" == provision* ]] && continue
            main_script="$f"
            break
        done
        [ -n "$main_script" ] || continue

        log_info "  App: $app"
        run_as_user "'$main_script' backup" 2>/dev/null || log_warn "    Backup skipped or failed (not all apps support backup)"
        if run_as_user "'$main_script' update" 2>/dev/null; then
            :
        elif run_as_user "'$main_script' refresh" 2>/dev/null; then
            :
        else
            log_warn "    Update/refresh failed or not supported for $app"
        fi
    done
fi

log_info "Comprehensive maintenance completed successfully!"
