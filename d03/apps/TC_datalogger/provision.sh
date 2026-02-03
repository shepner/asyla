#!/bin/bash
# Provision TC_datalogger on d03: clone app repo and create working dirs under /mnt/docker/TC_datalogger.
# Run once on d03 (after /mnt/docker is available). Then add credentials and run tc_datalogger.sh up.
# Usage: run as docker user; source ~/scripts/docker/common.env first or script will source it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load DOCKER_DL and DOCKER_D1 if not set
if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi

APP_NAME="TC_datalogger"
APP_REPO="${TC_DATALOGGER_REPO:-https://github.com/shepner/TC_datalogger.git}"
APP_ROOT="${DOCKER_DL:?}/$APP_NAME"
REPO_DIR="$APP_ROOT/repo"
SERVICES=(TC_faction_crimes TC_faction_members TC_items TC_user_events TC_faction_chains TC_dashboard)

echo "[INFO] Provisioning $APP_NAME under $APP_ROOT"

if [ ! -d "${DOCKER_DL}" ]; then
  echo "[ERROR] ${DOCKER_DL} not found. Mount iSCSI and run setup_manual.sh if needed." >&2
  exit 1
fi

mkdir -p "$APP_ROOT"
cd "$APP_ROOT"

if [ ! -d "$REPO_DIR/.git" ]; then
  echo "[INFO] Cloning $APP_REPO into $REPO_DIR"
  git clone --depth 1 "$APP_REPO" repo
else
  echo "[INFO] Repo already present at $REPO_DIR (run update to pull)"
fi

for svc in "${SERVICES[@]}"; do
  mkdir -p "$APP_ROOT/$svc/config" "$APP_ROOT/$svc/logs"
done

echo "[INFO] Add credentials and API config into each service's config/:"
for svc in "${SERVICES[@]}"; do
  echo "  - $APP_ROOT/$svc/config/credentials.json"
  echo "  - $APP_ROOT/$svc/config/TC_API_config.json"
done
echo "[INFO] Then run: $SCRIPT_DIR/tc_datalogger.sh up   (or backup/update/refresh/rebuild)"
