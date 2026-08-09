#!/usr/bin/env bash
# Generate DATA_DIR/config.yml from host apps.yml (config-file tunnel mode).
set -euo pipefail

HOST_DIR="${1:-}"
if [ -z "$HOST_DIR" ]; then
  echo "Usage: $0 <host-app-dir>" >&2
  exit 1
fi
HOST_DIR="$(cd "$HOST_DIR" && pwd)"
export APPS_YAML="${HOST_DIR}/apps.yml"
export DATA_DIR="${DATA_DIR:-${DOCKER_DL:-/mnt/docker}/cloudflared}"

exec python3 "$(dirname "$0")/generate_config.py"
