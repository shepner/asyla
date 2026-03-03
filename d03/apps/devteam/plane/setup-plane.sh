#!/bin/bash
# Set up Plane workspace, project, and agent user accounts.
# Requires: Plane is running and healthy, EA account already created via web UI.
# Stores per-role API keys in OpenBao.
#
# Idempotent: checks if workspace/project/users exist before creating.

set -euo pipefail

# Plane API must be reached via Docker network (plane-proxy is not published to host).
# We use a helper container on plane_net to make API calls.
PLANE_API_BASE="http://plane-proxy:80"
OPENBAO_ADDR="${OPENBAO_ADDR:-http://127.0.0.1:8200}"

# Wrapper: run curl inside a container on plane_net so we can reach plane-proxy directly.
plane_curl() {
  docker run --rm --network plane_net curlimages/curl -s "$@"
}
# Match the existing Plane workspace + project you created in the UI.
WORKSPACE_SLUG="asyla"
PROJECT_NAME="asyla"
PROJECT_ID="ASYLA"

AGENT_ROLES=(
  "product-manager"
  "security-architect"
  "dev-manager"
  "worker"
  "qa"
  "testing-agent"
  "system"
)

echo "=== Plane Setup ==="
echo ""
echo "Before continuing, you must:"
echo "  1. Open https://plane.asyla.org in your browser"
echo "  2. Create the first admin account (EA): shepner@asyla.org"
echo "  3. Complete the initial workspace setup in the UI"
echo "  4. Go to Profile Settings -> API Tokens -> Generate a token"
echo "  5. Copy the API token"
echo ""
read -rsp "Paste your EA API token here: " EA_API_KEY && echo
echo ""

# Verify API access
echo "[INFO] Verifying API access..."
VERIFY_RESPONSE=$(plane_curl -o /dev/null -w "%{http_code}" \
  -H "X-API-Key: $EA_API_KEY" \
  "${PLANE_API_BASE}/api/v1/users/me/")

if [ "$VERIFY_RESPONSE" != "200" ]; then
  echo "[ERROR] API returned HTTP $VERIFY_RESPONSE. Check your API key and that Plane is running."
  exit 1
fi
echo "[INFO] API access verified."

# Store EA API key in OpenBao
echo "[INFO] Storing EA API key in OpenBao..."
read -rsp "Enter OpenBao root token: " BAO_TOKEN && echo
docker exec -e BAO_ADDR="$OPENBAO_ADDR" -e BAO_TOKEN="$BAO_TOKEN" \
  openbao bao kv put secret/devteam/plane/ea api_key="$EA_API_KEY"

# Check workspace / project only when not in --store-keys mode.
if [ "${1:-}" != "--store-keys" ]; then
  echo "[INFO] Checking workspace '$WORKSPACE_SLUG'..."
  WS_CHECK=$(plane_curl -H "X-API-Key: $EA_API_KEY" \
    "${PLANE_API_BASE}/api/v1/workspaces/${WORKSPACE_SLUG}/" || true)

  if echo "$WS_CHECK" | grep -q '"slug"'; then
    echo "[INFO] Workspace '$WORKSPACE_SLUG' already exists."
  else
    echo "[WARN] Workspace '$WORKSPACE_SLUG' not found via API (Plane CE may manage this via UI only)."
  fi

  echo "[INFO] Checking project '$PROJECT_ID'..."
  PROJ_CHECK=$(plane_curl -H "X-API-Key: $EA_API_KEY" \
    "${PLANE_API_BASE}/api/v1/workspaces/${WORKSPACE_SLUG}/projects/" || true)

  if echo "$PROJ_CHECK" | grep -q "\"identifier\":\"$PROJECT_ID\""; then
    echo "[INFO] Project '$PROJECT_ID' already exists."
  else
    echo "[WARN] Project '$PROJECT_ID' not found via API. Ensure the UI project matches this ID."
  fi
fi

# Invite agent users
echo ""
echo "[INFO] Agent user accounts need to be created via the Plane UI."
echo "       Plane Community Edition requires email invitation for new users."
echo ""
echo "       For each of the following roles, invite them in Plane UI"
echo "       (Workspace Settings -> Members -> Invite):"
echo ""
for role in "${AGENT_ROLES[@]}"; do
  echo "         ${role}@devteam.local"
done
echo ""
echo "       After inviting, each user needs to:"
echo "         1. Accept the invitation (or use Django manage.py to activate)"
echo "         2. Generate an API token in Profile Settings"
echo ""
echo "       Then run this script again with --store-keys to store them in OpenBao."
echo ""

if [ "${1:-}" = "--store-keys" ]; then
  echo "[INFO] Storing per-role API keys in OpenBao..."
  for role in "${AGENT_ROLES[@]}"; do
    read -rsp "API key for $role (or Enter to skip): " KEY
    echo ""
    if [ -n "$KEY" ]; then
      docker exec -e BAO_ADDR="$OPENBAO_ADDR" -e BAO_TOKEN="$BAO_TOKEN" \
        openbao bao kv put "secret/devteam/plane/$role" api_key="$KEY"
      echo "[INFO] Stored key for $role"
    else
      echo "[SKIP] $role"
    fi
  done
fi

echo ""
echo "[INFO] Plane setup complete."
echo "       Workspace: $WORKSPACE_SLUG"
echo "       Project: $PROJECT_NAME ($PROJECT_ID)"
