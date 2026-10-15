#!/bin/bash
# Install the docker user's bash additions (history search, completion) from this build folder.
# Run as root by the build (build_host.py setup phase). Idempotent: the file is replaced, and the
# source line is added to ~docker/.bashrc only when no line names the file yet.
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "[ERROR] run as root" >&2; exit 1; }
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docker_bashrc_additions.sh"
DEST=/usr/local/share/asyla/docker_bashrc_additions.sh
USER_NAME=docker
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
[ -n "$HOME_DIR" ] || { echo "[ERROR] no user $USER_NAME" >&2; exit 1; }

install -d -m 755 "$(dirname "$DEST")"
install -m 644 "$SRC" "$DEST"
BASHRC="$HOME_DIR/.bashrc"
if ! grep -qF "$DEST" "$BASHRC" 2>/dev/null; then
    printf '\n# History search (Up/Down by prefix) and completion - asyla\n[ -f %s ] && . %s\n' "$DEST" "$DEST" >> "$BASHRC"
    chown "$USER_NAME:" "$BASHRC"
    echo "[INFO] $BASHRC sources $DEST"
fi
echo "[INFO] bash additions installed: $DEST"
