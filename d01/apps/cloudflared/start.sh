#!/bin/bash
# Convenience: run cloudflared.sh up (same management as other apps)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/cloudflared.sh" up
