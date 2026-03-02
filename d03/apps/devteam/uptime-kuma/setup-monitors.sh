#!/bin/bash
# Set up Uptime Kuma monitors for devteam services.
# Requires: Uptime Kuma is running, admin account created via UI.
#
# Uptime Kuma uses Socket.IO (no REST API). This script uses the
# uptime-kuma-api Python package to create monitors programmatically.
#
# If the Python package is not available, prints manual instructions instead.

set -euo pipefail

KUMA_URL="${KUMA_URL:-http://localhost:3001}"

echo "=== Uptime Kuma Monitor Setup ==="
echo ""
echo "Before continuing:"
echo "  1. Open https://status.asyla.org (or http://<d03-ip>:3001)"
echo "  2. Create an admin account"
echo "  3. Note your username and password"
echo ""

# Try Python-based setup first
if python3 -c "import uptime_kuma_api" 2>/dev/null; then
  read -rp "Uptime Kuma username: " KUMA_USER
  read -rsp "Uptime Kuma password: " KUMA_PASS && echo

  python3 - "$KUMA_URL" "$KUMA_USER" "$KUMA_PASS" << 'PYEOF'
import sys
from uptime_kuma_api import UptimeKumaApi, MonitorType

url, user, password = sys.argv[1], sys.argv[2], sys.argv[3]
api = UptimeKumaApi(url)
api.login(user, password)

existing = {m["name"] for m in api.get_monitors()}

monitors = [
    {
        "type": MonitorType.HTTP,
        "name": "Plane API Health",
        "url": "http://plane-proxy:80/api/health",
        "interval": 60,
        "maxretries": 3,
        "retryInterval": 30,
    },
    {
        "type": MonitorType.HTTP,
        "name": "OpenBao Health",
        "url": "http://openbao:8200/v1/sys/health",
        "interval": 60,
        "maxretries": 3,
        "retryInterval": 30,
    },
    {
        "type": MonitorType.PUSH,
        "name": "Dispatcher Heartbeat",
        "interval": 3600,
        "maxretries": 3,
        "retryInterval": 60,
    },
]

for m in monitors:
    if m["name"] in existing:
        print(f"[INFO] Monitor '{m['name']}' already exists. Skipping.")
        continue
    result = api.add_monitor(**m)
    print(f"[INFO] Created monitor: {m['name']} (id: {result['monitorID']})")
    if m["type"] == MonitorType.PUSH:
        mon = api.get_monitor(result["monitorID"])
        push_token = mon.get("pushToken", "unknown")
        print(f"       Push URL: {url}/api/push/{push_token}?status=up&msg=OK")

api.disconnect()
print("[INFO] Monitor setup complete.")
PYEOF

else
  echo "[WARN] Python package 'uptime-kuma-api' not found."
  echo "       Install it:  pip3 install uptime-kuma-api"
  echo ""
  echo "       Or create monitors manually in the Uptime Kuma UI:"
  echo ""
  echo "       1. HTTP Monitor: 'Plane API Health'"
  echo "          URL: http://plane-proxy:80/api/health"
  echo "          Interval: 60s"
  echo ""
  echo "       2. HTTP Monitor: 'OpenBao Health'"
  echo "          URL: http://openbao:8200/v1/sys/health"
  echo "          Interval: 60s"
  echo ""
  echo "       3. Push Monitor: 'Dispatcher Heartbeat'"
  echo "          Interval: 3600s (1 hour)"
  echo "          (Copy the push URL for use in dispatch_agent.py config)"
  echo ""
  read -rp "Press Enter when monitors are created..."
fi

echo "[INFO] Done."
