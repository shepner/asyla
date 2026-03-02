#!/bin/bash
# Generate Plane .env from .env.example with secure random values.
# Idempotent: skips if .env already exists.
# Run from the plane/ directory (or anywhere — uses SCRIPT_DIR).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
TEMPLATE="$SCRIPT_DIR/.env.example"

if [ -f "$ENV_FILE" ]; then
  echo "[INFO] $ENV_FILE already exists. Skipping generation."
  echo "       To regenerate, remove it first: rm $ENV_FILE"
  exit 0
fi

if [ ! -f "$TEMPLATE" ]; then
  echo "[ERROR] Template not found: $TEMPLATE"
  exit 1
fi

echo "[INFO] Generating $ENV_FILE from template..."

PG_PASS=$(openssl rand -hex 16)
MQ_PASS=$(openssl rand -hex 16)
MINIO_ACCESS=$(openssl rand -hex 16)
MINIO_SECRET=$(openssl rand -hex 16)
SECRET_KEY=$(openssl rand -hex 32)
LIVE_KEY=$(openssl rand -hex 16)

sed \
  -e "s/CHANGE_ME_DB_PASSWORD/$PG_PASS/" \
  -e "s/CHANGE_ME_MQ_PASSWORD/$MQ_PASS/" \
  -e "s/CHANGE_ME_MINIO_ACCESS/$MINIO_ACCESS/" \
  -e "s/CHANGE_ME_MINIO_SECRET/$MINIO_SECRET/" \
  -e "s/CHANGE_ME_DJANGO_SECRET_KEY/$SECRET_KEY/" \
  -e "s/CHANGE_ME_LIVE_SECRET/$LIVE_KEY/" \
  "$TEMPLATE" > "$ENV_FILE"

echo "[INFO] Generated $ENV_FILE with secure random values."
echo "[INFO] Passwords are NOT displayed. They are only in $ENV_FILE."
