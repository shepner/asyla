#!/bin/bash
# Serve d03 bootstrap over HTTP so you can run it from the VM console by typing a short command.
# Proxmox console often does not support paste; this avoids pasting.
#
# Usage:
#   1. On your workstation (or Proxmox host), from repo root: ./d03/setup/serve_bootstrap.sh
#   2. Note the HOST_IP printed (or use the IP of this machine on the VM network).
#   3. In the Proxmox VM console, as root, type only: curl http://HOST_IP:8888/b | bash
#   4. Stop the server with Ctrl+C when bootstrap has started.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Prefer interface with 10.0.0.x; fallback to first non-loopback
HOST_IP=""
if command -v ip &>/dev/null; then
    HOST_IP=$(ip -o -4 addr show scope global 2>/dev/null | awk -v want="10.0.0." '$4 ~ want {gsub(/\/.*/,"",$4); print $4; exit}')
fi
if [ -z "$HOST_IP" ] && command -v ip &>/dev/null; then
    HOST_IP=$(ip -o -4 addr show scope global 2>/dev/null | awk '{gsub(/\/.*/,"",$4); print $4; exit}')
fi
if [ -z "$HOST_IP" ]; then
    HOST_IP="YOUR_HOST_IP"
fi

echo "Serving d03/setup on port 8888 (Ctrl+C to stop)."
echo ""
echo "From the VM console (as root), type this (replace with your host IP if needed):"
echo ""
echo "  curl http://${HOST_IP}:8888/b | bash"
echo ""
echo "Short filename 'b' keeps typing minimal when paste is not available."
echo ""

exec python3 -m http.server 8888
