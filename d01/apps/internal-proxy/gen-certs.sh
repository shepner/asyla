#!/usr/bin/env bash
# Generate a private CA and server cert for d01 internal-proxy hostnames.
# Certs are written to DATA_DIR/certs (/mnt/docker/internal-proxy/certs) so they
# survive update_scripts.sh. Run automatically by internal-proxy.sh if certs are missing.
# Requires: openssl
#
# One-time workstation step: trust certs/ca.crt in your system keychain so browsers
# accept all d01 app hostnames without warnings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$HOME/scripts/docker/common.env" ] && . "$HOME/scripts/docker/common.env" || true
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DATA_DIR="${DOCKER_DL}/internal-proxy"
CERTS_DIR="${DATA_DIR}/certs"

mkdir -p "$CERTS_DIR"

# Hostnames that Caddy serves (must match Caddyfile)
SANS="DNS:sonarr.asyla.org,DNS:radarr.asyla.org,DNS:overseerr.asyla.org,DNS:jackett.asyla.org,DNS:transmission.asyla.org,DNS:calibre.asyla.org,DNS:homebridge.asyla.org,DNS:cameraui.asyla.org,DNS:duplicati.asyla.org"

CA_KEY="${CERTS_DIR}/ca.key"
CA_CRT="${CERTS_DIR}/ca.crt"
SERVER_KEY="${CERTS_DIR}/key.pem"
SERVER_CRT="${CERTS_DIR}/fullchain.pem"
EXT_FILE="${CERTS_DIR}/cert.ext"

if [ -f "$CA_CRT" ] && [ -f "$SERVER_CRT" ]; then
  echo "[INFO] Certs already exist in $CERTS_DIR. Remove them to regenerate."
  exit 0
fi

echo "[INFO] Generating CA..."
openssl genrsa -out "$CA_KEY" 4096
openssl req -new -x509 -days 3650 -key "$CA_KEY" -out "$CA_CRT" \
  -subj "/CN=asyla d01 internal CA"

echo "[INFO] Generating server key and cert..."
openssl genrsa -out "$SERVER_KEY" 2048
cat > "$EXT_FILE" << EOF
subjectAltName = $SANS
extendedKeyUsage = serverAuth
EOF
openssl req -new -key "$SERVER_KEY" -out "${CERTS_DIR}/server.csr" \
  -subj "/CN=internal-proxy.asyla.org"
openssl x509 -req -in "${CERTS_DIR}/server.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$SERVER_CRT" -days 730 -extfile "$EXT_FILE"

rm -f "${CERTS_DIR}/server.csr" "$EXT_FILE" "${CERTS_DIR}/ca.srl" 2>/dev/null || true
chmod 644 "$CA_CRT" "$SERVER_CRT"
chmod 600 "$CA_KEY" "$SERVER_KEY" 2>/dev/null || true

echo "[INFO] Done. Certificates in $CERTS_DIR"
echo "  Trust $CA_CRT on your workstation so browsers accept all d01 app hostnames."
echo "  macOS: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CA_CRT"
