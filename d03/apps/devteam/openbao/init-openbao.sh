#!/bin/bash
# Initialize and unseal OpenBao on d03.
# Idempotent: skips if already initialized.
# Run after openbao.sh up.
#
# Outputs root token and unseal keys to stdout — user must save to Bitwarden.

set -euo pipefail

CONTAINER="openbao"
BAO="docker exec -e BAO_ADDR=http://127.0.0.1:8200 $CONTAINER bao"

echo "=== OpenBao Init ==="

# Check if already initialized
if $BAO status 2>/dev/null | grep -q "Initialized.*true"; then
  echo "[INFO] OpenBao is already initialized."
  if $BAO status 2>/dev/null | grep -q "Sealed.*true"; then
    echo "[WARN] OpenBao is sealed. Unsealing..."
    for i in 1 2 3; do
      read -rsp "Enter unseal key $i: " KEY && echo
      $BAO operator unseal "$KEY"
    done
  fi
  echo "[INFO] OpenBao is initialized and unsealed."
  exit 0
fi

echo "[INFO] Initializing OpenBao (key-shares=5, key-threshold=3)..."
INIT_OUTPUT=$($BAO operator init -key-shares=5 -key-threshold=3 2>&1)
echo "$INIT_OUTPUT"

echo ""
echo "=========================================="
echo "  SAVE THE ABOVE KEYS TO BITWARDEN NOW"
echo "=========================================="
read -rp "Press Enter after you have saved the root token and unseal keys to Bitwarden..."

# Extract unseal keys from init output
KEYS=()
while IFS= read -r line; do
  if [[ "$line" =~ Unseal\ Key\ [0-9]+:\ (.+) ]]; then
    KEYS+=("${BASH_REMATCH[1]}")
  fi
done <<< "$INIT_OUTPUT"

# Extract root token
ROOT_TOKEN=""
while IFS= read -r line; do
  if [[ "$line" =~ Initial\ Root\ Token:\ (.+) ]]; then
    ROOT_TOKEN="${BASH_REMATCH[1]}"
  fi
done <<< "$INIT_OUTPUT"

if [ ${#KEYS[@]} -lt 3 ]; then
  echo "[ERROR] Could not parse unseal keys from init output. Unseal manually."
  exit 1
fi

echo "[INFO] Unsealing with first 3 keys..."
for i in 0 1 2; do
  $BAO operator unseal "${KEYS[$i]}"
done

echo "[INFO] Enabling kv-v2 secrets engine..."
if [ -n "$ROOT_TOKEN" ]; then
  docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="$ROOT_TOKEN" \
    $CONTAINER bao secrets enable -path=secret kv-v2 2>/dev/null || \
    echo "[INFO] kv-v2 engine already enabled at secret/"
else
  echo "[WARN] Could not parse root token. Enable kv-v2 manually:"
  echo "  docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN=<root_token> openbao bao secrets enable -path=secret kv-v2"
fi

echo "[INFO] OpenBao initialized, unsealed, and kv-v2 enabled."
echo ""
echo "Root token: ${ROOT_TOKEN:-<see init output above>}"
