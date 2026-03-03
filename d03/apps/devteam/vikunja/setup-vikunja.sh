#!/bin/bash
# Set up Vikunja project, workflow labels, and API token for the devteam dispatcher.
# Idempotent: safe to re-run; skips steps already completed.
#
# What this does:
#   1. Wait for Vikunja to be healthy
#   2. Register the admin (EA) user (registration must be enabled in .env)
#   3. Log in to get a session token
#   4. Create the devteam project
#   5. Create workflow labels: ready, in-progress, blocked, review
#   6. Create a long-lived API token (no expiry)
#   7. Store API token + project ID in OpenBao
#   8. Print next steps (disable registration via .env)
#
# Usage:
#   ./setup-vikunja.sh
#
# Pre-requisites:
#   - Vikunja is running (vikunja.sh up)
#   - .env has ENABLE_REGISTRATION=true (temporarily)
#   - OpenBao is running and unsealed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIKUNJA_INTERNAL="http://vikunja:3456"
OPENBAO_ADDR="${OPENBAO_ADDR:-http://127.0.0.1:8200}"

# Admin account for the EA (human operator)
EA_USERNAME="${EA_USERNAME:-ea}"
EA_EMAIL="${EA_EMAIL:-ea@devteam.local}"

PROJECT_TITLE="asyla"
WORKFLOW_LABELS=("ready" "in-progress" "blocked" "review")

# Run curl inside vikunja_net to reach the container directly.
vk_curl() {
  docker run --rm --network vikunja_net curlimages/curl -s "$@"
}

echo "=== Vikunja Setup ==="
echo ""

# ─── Step 1: Wait for health ──────────────────────────────────────────────────
echo "[1/7] Waiting for Vikunja to become healthy..."
ATTEMPTS=0
MAX_ATTEMPTS=60
until vk_curl -sf "${VIKUNJA_INTERNAL}/api/v1/info" > /dev/null 2>&1; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    echo "[ERROR] Vikunja did not respond after ${MAX_ATTEMPTS} attempts."
    echo "        Check: ~/scripts/d03/apps/devteam/vikunja/vikunja.sh logs"
    exit 1
  fi
  printf "."
  sleep 3
done
echo ""
echo "[OK] Vikunja is healthy."

# ─── Step 2: Register admin user ─────────────────────────────────────────────
echo ""
echo "[2/7] Registering EA admin user..."
echo "      Username: $EA_USERNAME"
echo "      Email:    $EA_EMAIL"
read -rsp "      Password: " EA_PASSWORD && echo

REGISTER_RESP=$(vk_curl -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$EA_USERNAME\",\"email\":\"$EA_EMAIL\",\"password\":\"$EA_PASSWORD\"}" \
  "${VIKUNJA_INTERNAL}/api/v1/register" 2>/dev/null)
REGISTER_BODY=$(echo "$REGISTER_RESP" | head -n -1)
REGISTER_CODE=$(echo "$REGISTER_RESP" | tail -n 1)

if [ "$REGISTER_CODE" = "200" ] || [ "$REGISTER_CODE" = "201" ]; then
  echo "[OK] Admin user registered."
elif echo "$REGISTER_BODY" | grep -qi "already"; then
  echo "[INFO] Admin user already exists — continuing."
else
  echo "[WARN] Registration returned HTTP $REGISTER_CODE: $REGISTER_BODY"
  echo "       Continuing (user may already exist)."
fi

# ─── Step 3: Login to get JWT ─────────────────────────────────────────────────
echo ""
echo "[3/7] Logging in to get session token..."
LOGIN_RESP=$(vk_curl -X POST \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$EA_USERNAME\",\"password\":\"$EA_PASSWORD\",\"long_token\":false}" \
  "${VIKUNJA_INTERNAL}/api/v1/user/login")

JWT=$(echo "$LOGIN_RESP" | grep -o '"token":"[^"]*"' | head -1 | sed 's/"token":"//;s/"//')
if [ -z "$JWT" ]; then
  echo "[ERROR] Could not extract JWT from login response: $LOGIN_RESP"
  exit 1
fi
echo "[OK] Got session token."

# ─── Step 4: Create project ───────────────────────────────────────────────────
echo ""
echo "[4/7] Creating project '$PROJECT_TITLE'..."

# Check if project already exists
PROJECTS_RESP=$(vk_curl -H "Authorization: Bearer $JWT" \
  "${VIKUNJA_INTERNAL}/api/v1/projects")
EXISTING_PROJECT_ID=$(echo "$PROJECTS_RESP" | grep -o '"id":[0-9]*,"title":"'"$PROJECT_TITLE"'"' | grep -o '"id":[0-9]*' | head -1 | tr -d '"id:')

if [ -n "$EXISTING_PROJECT_ID" ] && [ "$EXISTING_PROJECT_ID" != "0" ]; then
  PROJECT_ID="$EXISTING_PROJECT_ID"
  echo "[INFO] Project '$PROJECT_TITLE' already exists (id=$PROJECT_ID)."
else
  CREATE_PROJ_RESP=$(vk_curl -X PUT \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"$PROJECT_TITLE\",\"description\":\"DevTeam work items for the asyla project\"}" \
    "${VIKUNJA_INTERNAL}/api/v1/projects")
  PROJECT_ID=$(echo "$CREATE_PROJ_RESP" | grep -o '"id":[0-9]*' | head -1 | tr -d '"id:')
  if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "0" ]; then
    echo "[ERROR] Could not create project: $CREATE_PROJ_RESP"
    exit 1
  fi
  echo "[OK] Project created (id=$PROJECT_ID)."
fi

# ─── Step 5: Create workflow labels ──────────────────────────────────────────
echo ""
echo "[5/7] Creating workflow labels..."
declare -A LABEL_COLORS
LABEL_COLORS["ready"]="#27ae60"
LABEL_COLORS["in-progress"]="#2980b9"
LABEL_COLORS["blocked"]="#e74c3c"
LABEL_COLORS["review"]="#8e44ad"

for label in "${WORKFLOW_LABELS[@]}"; do
  color="${LABEL_COLORS[$label]}"
  LABEL_RESP=$(vk_curl -X PUT \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"$label\",\"hex_color\":\"$color\"}" \
    "${VIKUNJA_INTERNAL}/api/v1/labels" 2>/dev/null || echo '{}')
  LABEL_ID=$(echo "$LABEL_RESP" | grep -o '"id":[0-9]*' | head -1 | tr -d '"id:')
  if [ -n "$LABEL_ID" ] && [ "$LABEL_ID" != "0" ]; then
    echo "  [OK] Label '$label' (id=$LABEL_ID)"
  else
    echo "  [WARN] Could not create label '$label' (may already exist): $LABEL_RESP"
  fi
done

# ─── Step 6: Create API token ─────────────────────────────────────────────────
echo ""
echo "[6/7] Creating long-lived API token..."
TOKEN_RESP=$(vk_curl -X PUT \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"devteam-dispatcher\",\"permissions\":{\"projects\":{\"read\":true,\"create\":true,\"update\":true,\"delete\":false},\"tasks\":{\"read\":true,\"create\":true,\"update\":true,\"delete\":false}}}" \
  "${VIKUNJA_INTERNAL}/api/v1/tokens" 2>/dev/null || echo '{}')

# Vikunja returns the plaintext token only on creation
API_TOKEN=$(echo "$TOKEN_RESP" | grep -o '"token":"[^"]*"' | head -1 | sed 's/"token":"//;s/"//')
if [ -z "$API_TOKEN" ]; then
  echo "[ERROR] Could not create API token: $TOKEN_RESP"
  echo "        You can create one manually in Settings -> API Tokens."
  echo "        Then run this script with: VIKUNJA_API_TOKEN=<token> ./setup-vikunja.sh --store-keys"
  API_TOKEN="${VIKUNJA_API_TOKEN:-}"
fi

if [ -n "$API_TOKEN" ]; then
  echo "[OK] API token created."
fi

# ─── Step 7: Store in OpenBao ────────────────────────────────────────────────
echo ""
echo "[7/7] Storing credentials in OpenBao..."
read -rsp "Enter OpenBao root token: " BAO_TOKEN && echo

if [ -n "$API_TOKEN" ]; then
  docker exec -e BAO_ADDR="$OPENBAO_ADDR" -e BAO_TOKEN="$BAO_TOKEN" \
    openbao bao kv put secret/devteam/vikunja/api-token value="$API_TOKEN"
  echo "[OK] Vikunja API token stored."
fi

docker exec -e BAO_ADDR="$OPENBAO_ADDR" -e BAO_TOKEN="$BAO_TOKEN" \
  openbao bao kv put secret/devteam/vikunja/project-id value="$PROJECT_ID"
echo "[OK] Vikunja project ID ($PROJECT_ID) stored."

echo ""
echo "============================================"
echo "  Vikunja setup complete!"
echo "============================================"
echo ""
echo "  Project:  $PROJECT_TITLE (id=$PROJECT_ID)"
echo "  URL:      https://vikunja.asyla.org"
echo ""
echo "NEXT STEPS:"
echo "  1. Disable user registration:"
echo "       Edit ~/scripts/d03/apps/devteam/vikunja/.env"
echo "       Set ENABLE_REGISTRATION=false"
echo "       Then: ~/scripts/d03/apps/devteam/vikunja/vikunja.sh restart"
echo ""
echo "  2. Verify dispatcher connectivity:"
echo "       cd ~/scripts/knowledge-hub"
echo "       python3 .cursor/helpers/dispatch_agent.py --ticket 1 --project . --dry-run"
