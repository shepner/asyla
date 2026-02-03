#!/bin/bash
# Copy credentials and API config from local TC_datalogger project to d03.
# Run from workstation (asyla repo). Creates remote config dirs if needed.
#
# Usage: ./d03/apps/TC_datalogger/copy_config_to_d03.sh [host]
#   host defaults to d03
#
# Set TC_DATALOGGER_SRC if your project is not at ../TornCity/TC_datalogger relative to asyla repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOST="${1:-d03}"

TC_DATALOGGER_SRC="${TC_DATALOGGER_SRC:-$REPO_ROOT/../TornCity/TC_datalogger}"
REMOTE_BASE="/mnt/docker/TC_datalogger"

SERVICES=(TC_faction_crimes TC_faction_members TC_items TC_user_events TC_faction_chains)

if [ ! -d "$TC_DATALOGGER_SRC" ]; then
  echo "[ERROR] TC_datalogger not found at $TC_DATALOGGER_SRC. Set TC_DATALOGGER_SRC." >&2
  exit 1
fi

echo "[INFO] Copying config from $TC_DATALOGGER_SRC to $HOST:$REMOTE_BASE"

for svc in "${SERVICES[@]}"; do
  local_dir="$TC_DATALOGGER_SRC/$svc/config"
  for f in credentials.json TC_API_config.json; do
    if [ -f "$local_dir/$f" ]; then
      ssh "$HOST" "mkdir -p $REMOTE_BASE/$svc/config"
      scp "$local_dir/$f" "$HOST:$REMOTE_BASE/$svc/config/"
      echo "[INFO] $svc/config/$f"
    else
      echo "[WARN] Skip $svc/config/$f (not found)"
    fi
  done
done

echo "[INFO] Done. On d03 start with: ~/scripts/d03/apps/TC_datalogger/tc_datalogger.sh up"
