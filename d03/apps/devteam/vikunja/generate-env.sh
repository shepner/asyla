#!/bin/bash
# Generate Vikunja .env from .env.example with random secrets.
# Safe to re-run — will not overwrite an existing .env.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
EXAMPLE_FILE="$SCRIPT_DIR/.env.example"

if [ -f "$ENV_FILE" ]; then
  echo "[INFO] $ENV_FILE already exists. Delete it to regenerate."
  exit 0
fi

POSTGRES_PASSWORD=$(openssl rand -hex 16)
JWT_SECRET=$(openssl rand -hex 32)

sed \
  -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${POSTGRES_PASSWORD}/" \
  -e "s/^JWT_SECRET=.*/JWT_SECRET=${JWT_SECRET}/" \
  "$EXAMPLE_FILE" > "$ENV_FILE"

echo "[INFO] Generated $ENV_FILE"
echo "  POSTGRES_PASSWORD and JWT_SECRET are random — store them safely."
