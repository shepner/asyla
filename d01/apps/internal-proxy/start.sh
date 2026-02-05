#!/bin/bash
# Convenience: run internal-proxy.sh up (same management as other apps)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/internal-proxy.sh" up
