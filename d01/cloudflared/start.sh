#!/bin/bash
# Start cloudflared with network creation
# Ensures d01_internal and media_net exist before starting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "[INFO] Ensuring networks exist..."
docker network create d01_internal 2>/dev/null || true
docker network create media_net 2>/dev/null || true

# Check if config.yml exists (config mode) or use token mode
if [ -f "config.yml" ] && [ -f "credentials.json" ]; then
  echo "[INFO] Using config file mode (automated hostnames)"
  docker compose -f docker-compose.yml -f docker-compose.config.yml up -d
else
  echo "[INFO] Using token mode (manual hostnames in dashboard)"
  docker compose up -d
fi
