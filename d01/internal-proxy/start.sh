#!/bin/bash
# Start internal proxy with network creation
# Ensures d01_internal and media_net exist before starting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "[INFO] Ensuring networks exist..."
docker network create d01_internal 2>/dev/null || true
docker network create media_net 2>/dev/null || true

echo "[INFO] Starting internal proxy"
docker compose up -d
