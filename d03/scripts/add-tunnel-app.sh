#!/bin/bash
# Add a new application to Cloudflare Tunnel on d03
#
# Usage: ./add-tunnel-app.sh <app-name> <hostname> <service> <port> [access]
#
# Example:
#   ./add-tunnel-app.sh tc_datalogger tc-datalogger tc-dashboard 8080 true
#
# This script:
# 1. Adds entry to apps.yml config file
# 2. Ensures app compose file has {app}_net network
# 3. Updates cloudflared compose to include app network
# 4. Outputs Cloudflare dashboard steps (or calls API if configured)
#
# Requires: apps.yml, cloudflared docker-compose.yml, app compose file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D03_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLOUDFLARED_DIR="${D03_DIR}/apps/cloudflared"
APPS_YML="${CLOUDFLARED_DIR}/apps.yml"
CLOUDFLARED_COMPOSE="${CLOUDFLARED_DIR}/docker-compose.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error() {
    echo -e "${RED}Error:${NC} $1" >&2
    exit 1
}

info() {
    echo -e "${GREEN}Info:${NC} $1"
}

warn() {
    echo -e "${YELLOW}Warning:${NC} $1"
}

# Check arguments
if [ $# -lt 4 ]; then
    error "Usage: $0 <app-name> <hostname> <service> <port> [access=true]"
    error "Example: $0 tc_datalogger tc-datalogger tc-dashboard 8080 true"
    exit 1
fi

APP_NAME="$1"
HOSTNAME="$2"
SERVICE="$3"
PORT="$4"
ACCESS="${5:-true}"

# Validate app name (lowercase, underscores only)
if [[ ! "$APP_NAME" =~ ^[a-z0-9_]+$ ]]; then
    error "App name must be lowercase letters, numbers, and underscores only"
fi

# Validate port is a number
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
    error "Port must be a number"
fi

# Check if apps.yml exists
if [ ! -f "$APPS_YML" ]; then
    error "apps.yml not found at ${APPS_YML}"
fi

# Check if app already exists in config
if grep -q "app: ${APP_NAME}" "$APPS_YML"; then
    warn "App ${APP_NAME} already exists in apps.yml"
    read -p "Update existing entry? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
    # Remove existing entry (simple approach - remove lines between app entry)
    # This is a basic implementation - could be improved with yq or similar
    warn "Please manually update apps.yml to modify existing entry"
    exit 1
fi

info "Adding app to config: ${APP_NAME}"

# Add entry to apps.yml (simple append - assumes YAML structure)
cat >> "$APPS_YML" <<EOF
  - app: ${APP_NAME}
    hostname: ${HOSTNAME}
    service: ${SERVICE}
    port: ${PORT}
    access: ${ACCESS}
EOF

info "Added entry to ${APPS_YML}"

# Check if cloudflared compose needs network update
NETWORK_NAME="${APP_NAME}_net"
if ! grep -q "${NETWORK_NAME}" "$CLOUDFLARED_COMPOSE"; then
    info "Adding ${NETWORK_NAME} to cloudflared compose"
    
    # Add network to services.cloudflared.networks
    if grep -q "networks:" "$CLOUDFLARED_COMPOSE" && grep -A 10 "networks:" "$CLOUDFLARED_COMPOSE" | grep -q "tc_datalogger_net"; then
        # Insert after existing network entry
        sed -i "/tc_datalogger_net/a\      - ${NETWORK_NAME}" "$CLOUDFLARED_COMPOSE"
    else
        warn "Could not auto-update cloudflared compose networks section"
        warn "Please manually add '${NETWORK_NAME}' to cloudflared service networks"
    fi
    
    # Add network definition at bottom
    if ! grep -q "${NETWORK_NAME}:" "$CLOUDFLARED_COMPOSE"; then
        cat >> "$CLOUDFLARED_COMPOSE" <<EOF

  ${NETWORK_NAME}:
    external: true
    name: ${NETWORK_NAME}
EOF
        info "Added network definition to cloudflared compose"
    fi
else
    info "Network ${NETWORK_NAME} already in cloudflared compose"
fi

# Output Cloudflare dashboard steps
echo
info "=== Cloudflare Dashboard Steps ==="
echo
echo "1. Go to: Cloudflare Zero Trust → Networks → Tunnels → d03"
echo "2. Add Public Hostname:"
echo "   - Subdomain: ${HOSTNAME}"
echo "   - Domain: $(grep '^domain:' "$APPS_YML" | awk '{print $2}')"
echo "   - Service: HTTP"
echo "   - URL: http://${SERVICE}:${PORT}"
echo
if [ "$ACCESS" = "true" ]; then
    echo "3. Create Access Application:"
    echo "   - Go to: Zero Trust → Access → Applications"
    echo "   - Add application: ${HOSTNAME}.$(grep '^domain:' "$APPS_YML" | awk '{print $2}')"
    echo "   - Configure Access policies (who can access)"
else
    echo "3. Access: Skipped (access=false)"
fi
echo
echo "4. DNS: Cloudflare should auto-create CNAME, or create manually:"
echo "   - Type: CNAME"
echo "   - Name: ${HOSTNAME}"
echo "   - Target: <tunnel-id>.cfargotunnel.com"
echo
info "After Cloudflare setup, restart cloudflared:"
echo "  ${CLOUDFLARED_DIR}/cloudflared.sh restart"
echo
