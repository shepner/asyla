#!/bin/bash
# Run manual storage setup: local /mnt/docker on root disk.
# Usage: ~/setup_manual.sh  (or sudo ~/setup_manual.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/setup_docker_local.sh" ] || SCRIPT_DIR="$HOME/scripts/ns01/setup"

echo "=============================================="
echo "  Manual storage setup (local /mnt/docker)"
echo "=============================================="
echo ""

sudo "$SCRIPT_DIR/setup_docker_local.sh"
echo ""
echo "Done. Local data dir: /mnt/docker"
