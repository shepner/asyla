#!/usr/bin/env bash
# Generate a private CA and server cert for d01 internal-proxy hostnames.
# Run once on d01 (or any machine); trust certs/ca.crt on each workstation to avoid browser warnings.
# Requires: openssl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/certs"
mkdir -p "$CERTS_DIR"
cd "$CERTS_DIR"

# Hostnames that Caddy serves (must match Caddyfile)
SANS="DNS:sonarr.asyla.org,DNS:radarr.asyla.org,DNS:overseerr.asyla.org,DNS:jackett.asyla.org,DNS:transmission.asyla.org,DNS:calibre.asyla.org,DNS:homebridge.asyla.org,DNS:cameraui.asyla.org,DNS:duplicati.asyla.org"

CA_KEY="ca.key"
CA_CRT="ca.crt"
SERVER_KEY="key.pem"
SERVER_CRT="fullchain.pem"
EXT_FILE="cert.ext"

if [ -f "$CA_CRT" ] && [ -f "$SERVER_CRT" ]; then
  echo "[INFO] certs already exist in $CERTS_DIR. Remove them to regenerate."
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
openssl req -new -key "$SERVER_KEY" -out server.csr \
  -subj "/CN=internal-proxy.asyla.org"
openssl x509 -req -in server.csr -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$SERVER_CRT" -days 730 -extfile "$EXT_FILE"

rm -f server.csr "$EXT_FILE" ca.srl 2>/dev/null || true
chmod 644 "$CA_CRT" "$SERVER_CRT"
chmod 600 "$CA_KEY" "$SERVER_KEY" 2>/dev/null || true

echo "[INFO] Done. Certificates in $CERTS_DIR"
echo "  - Trust $CA_CRT on your workstation (see README) so browsers accept all d01 app hostnames."
echo "  - Restart internal-proxy so Caddy uses the new cert: internal-proxy.sh restart"
