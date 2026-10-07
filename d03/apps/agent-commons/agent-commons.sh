#!/bin/bash
# agent-commons on d03. Usage: agent-commons.sh [switch ...] e.g. build <ref>|rehearse [ref]|backup|update|refresh|up|down|restart|verify|logs
# Switches can be combined (e.g. down _backup up verify). Run from anywhere; loads ~/scripts/docker/common.env when present.
# Data: /mnt/docker/agent-commons (SQLite agent_commons.db). Backups: rsync mirror under /mnt/nas/data1/docker/agent-commons
#
# Image: built on this host, never pulled. `build <ref>` takes a git archive of <ref> from the bare repo
# inside the Gitea container (asyla/agent-commons; no checkout, no token on d03) and tags it
# agent-commons:<sha7> with AGENT_COMMONS_APP_VERSION=<sha7>. The deployed revision is the image pinned
# in compose.yml (tracked); .env AGENT_COMMONS_IMAGE overrides it only for a rollback.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="agent-commons"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
# shellcheck source=/dev/null
. "$HOME/scripts/docker/backup_lib.sh"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/.env"
  set +a
fi
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"

APP_NAME="agent-commons"
APP_ROOT="$DOCKER_DL/$APP_NAME"
BACKUP_DIR="$DOCKER_D1/$APP_NAME/mirror"
CONTAINER="agent-commons"
IMAGE_REPO="agent-commons"
SOURCE_URL="https://gitea.asyla.org/asyla/agent-commons"
GIT_CONTAINER="${AGENT_COMMONS_GIT_CONTAINER:-gitea}"
GIT_DIR="${AGENT_COMMONS_GIT_DIR:-/data/git/repositories/asyla/agent-commons.git}"

# Rehearsal: a copy of the live DB, served by the candidate image on loopback only.
REHEARSE_CONTAINER="agent-commons-rehearse"
REHEARSE_DIR="$DOCKER_DL/$APP_NAME-rehearse"
REHEARSE_WEB_PORT=18765
REHEARSE_MCP_PORT=18766

export DOCKER_DL
export DOCKER_D1

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

# The image compose.yml pins (tracked), ignoring any .env override.
pinned_image() {
  sed -n 's/.*\${AGENT_COMMONS_IMAGE:-\([^}]*\)}.*/\1/p' "$COMPOSE_FILE"
}

# The image compose will run: the .env override if set, else the pin.
configured_image() {
  printf '%s' "${AGENT_COMMONS_IMAGE:-$(pinned_image)}"
}

src_git() {
  docker exec -u git "$GIT_CONTAINER" git --git-dir="$GIT_DIR" "$@"
}

# resolve_ref <ref> -> full commit SHA from the Gitea repo
resolve_ref() {
  local sha
  if ! sha="$(src_git rev-parse --verify --quiet "$1^{commit}")"; then
    echo "[ERROR] '$1' is not a commit in $GIT_CONTAINER:$GIT_DIR (pushed to Gitea?)" >&2
    return 1
  fi
  printf '%s' "$sha"
}

# image_for <ref-or-image> -> image name. An argument with ':' is an image; anything else is a ref.
image_for() {
  local sha
  if [[ "$1" == *:* ]]; then
    printf '%s' "$1"
  else
    sha="$(resolve_ref "$1")" || return 1
    printf '%s:%s' "$IMAGE_REPO" "${sha:0:7}"
  fi
}

# build [ref]: default ref is the pinned revision. Always builds (--pull picks up base-image
# security fixes); if that replaces an existing image under the tag, the old one stays as <tag>-prev.
do_build() {
  local ref="${1:-}" sha short tag old new context
  if [ -z "$ref" ]; then
    ref="$(pinned_image)"
    ref="${ref#"$IMAGE_REPO":}"
  fi
  sha="$(resolve_ref "$ref")"
  short="${sha:0:7}"
  tag="$IMAGE_REPO:$short"
  old="$(docker image inspect -f '{{.Id}}' "$tag" 2>/dev/null || true)"
  # Tag the current image before the build moves $tag: with the containerd image store an image
  # whose last tag moved can no longer be looked up by ID, so tagging it afterwards fails.
  if [ -n "$old" ]; then
    docker image tag "$tag" "$tag-prev"
  fi
  echo "[INFO] Building $tag from '$ref' (git archive in $GIT_CONTAINER)"
  # Archive to a file first: a truncated stream piped into docker build could still be tagged.
  context="$(mktemp)"
  if ! src_git archive --format=tar "$sha" >"$context"; then
    rm -f "$context"
    echo "[ERROR] git archive of $sha failed" >&2
    return 1
  fi
  if ! docker build --pull \
    --build-arg "AGENT_COMMONS_APP_VERSION=$short" \
    --label "org.opencontainers.image.revision=$sha" \
    --label "org.opencontainers.image.source=$SOURCE_URL" \
    -t "$tag" - <"$context"; then
    rm -f "$context"
    echo "[ERROR] docker build of $tag failed" >&2
    return 1
  fi
  rm -f "$context"
  new="$(docker image inspect -f '{{.Id}}' "$tag")"
  if [ -n "$old" ] && [ "$old" != "$new" ]; then
    echo "[INFO] The image previously tagged $tag is kept as $tag-prev"
  elif [ -n "$old" ]; then
    docker image rm "$tag-prev" >/dev/null  # unchanged build: drop the extra tag only
  fi
  echo "[INFO] Built $tag (app_version $short)"
}

do_backup() {
  do_rsync_mirror_backup "$APP_ROOT" "$BACKUP_DIR"
}

# update: make sure the configured image exists, building the pinned revision if it is missing.
# Never starts or restarts anything (update_all.sh calls this unattended).
do_update() {
  local img
  img="$(configured_image)"
  if docker image inspect "$img" &>/dev/null; then
    echo "[INFO] $img is present (nothing to build; use build <ref> to rebuild)"
    return 0
  fi
  if [[ "$img" =~ ^$IMAGE_REPO:[0-9a-f]{7}$ ]]; then
    do_build "${img#"$IMAGE_REPO":}"
  else
    echo "[ERROR] $img is missing and is not an $IMAGE_REPO:<sha7> tag this script can build" >&2
    return 1
  fi
}

# check_service <container> <expected app_version> <wait seconds>
# Inside the container: /api/v1/health answers with that app_version, and MCP on :8766 answers initialize.
check_service() {
  docker exec -i "$1" python - "$2" "$3" <<'PY'
import json, sys, time, urllib.error, urllib.request

expected, deadline = sys.argv[1], time.time() + int(sys.argv[2])

def mcp_initialize():
    body = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-03-26", "capabilities": {},
                       "clientInfo": {"name": "agent-commons.sh", "version": "1"}}}
    req = urllib.request.Request("http://127.0.0.1:8766/mcp", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json",
                                          "Accept": "application/json, text/event-stream"})
    with urllib.request.urlopen(req, timeout=15) as r:
        sid, text = r.headers.get("mcp-session-id"), r.read().decode()
    msgs = [json.loads(l[5:]) for l in text.splitlines() if l.startswith("data:")] or [json.loads(text)]
    info = next((m["result"]["serverInfo"] for m in msgs if "result" in m), None)
    if sid:  # end the session we opened
        try:
            urllib.request.urlopen(urllib.request.Request(
                "http://127.0.0.1:8766/mcp", method="DELETE", headers={"mcp-session-id": sid}), timeout=5)
        except Exception:
            pass
    return info

while True:
    try:
        health = json.load(urllib.request.urlopen("http://127.0.0.1:8765/api/v1/health", timeout=10))
        info = mcp_initialize()
        break
    except (urllib.error.URLError, ConnectionError, OSError) as e:
        if time.time() > deadline:
            sys.exit(f"[ERROR] not answering: {e}")
        time.sleep(3)

if health.get("status") != "ok":
    sys.exit(f"[ERROR] health status {health.get('status')!r}")
if health.get("app_version") != expected:
    sys.exit(f"[ERROR] app_version {health.get('app_version')!r}, expected {expected!r}")
if not info:
    sys.exit("[ERROR] MCP initialize returned no serverInfo")
print(f"[INFO] health ok, app_version {health['app_version']}, situations {health.get('situations')}")
print(f"[INFO] MCP initialize ok: {info.get('name')} {info.get('version', '')}".rstrip())
PY
}

# The app_version baked into an image (its AGENT_COMMONS_APP_VERSION).
image_app_version() {
  docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" |
    sed -n 's/^AGENT_COMMONS_APP_VERSION=//p'
}

do_verify() {
  local img pin running want version
  img="$(configured_image)"
  pin="$(pinned_image)"
  if [ "$img" != "$pin" ]; then
    echo "[WARN] .env AGENT_COMMONS_IMAGE=$img overrides the tracked pin $pin (compose.yml)" >&2
  fi
  running="$(docker inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null)" || {
    echo "[ERROR] Container $CONTAINER is not running" >&2
    return 1
  }
  want="$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null)" || {
    echo "[ERROR] Configured image $img does not exist on this host" >&2
    return 1
  }
  if [ "$running" != "$want" ]; then
    echo "[ERROR] $CONTAINER runs a different image than $img (run up to apply it)" >&2
    return 1
  fi
  version="$(image_app_version "$img")"
  if [[ "$img" =~ ^$IMAGE_REPO:([0-9a-f]{7})$ ]] && [ "$version" != "${BASH_REMATCH[1]}" ]; then
    echo "[ERROR] $img carries app_version '$version', not ${BASH_REMATCH[1]}" >&2
    return 1
  fi
  echo "[INFO] $CONTAINER runs $img"
  check_service "$CONTAINER" "$version" 60
}

# rehearse [ref-or-image]: run the candidate (default: the configured image) against a copy of the
# live DB on 127.0.0.1:18765/18766, check it, then remove it. The live service is only read.
# AGENT_COMMONS_REHEARSE_KEEP=1 leaves the rehearsal container and copy for inspection.
do_rehearse() {
  local img version rc=0 errors
  img="$(image_for "${1:-$(configured_image)}")"
  docker image inspect "$img" &>/dev/null || {
    echo "[ERROR] $img does not exist; run build first" >&2
    return 1
  }
  version="$(image_app_version "$img")"
  docker rm -f "$REHEARSE_CONTAINER" &>/dev/null || true
  rm -rf "$REHEARSE_DIR"
  mkdir -p "$REHEARSE_DIR"

  echo "[INFO] Copying the live DB with the SQLite backup API (inside $CONTAINER)"
  docker exec -i "$CONTAINER" python - <<'PY'
import sqlite3
src, dst = sqlite3.connect("/data/agent_commons.db"), sqlite3.connect("/tmp/rehearse.db")
src.backup(dst)
dst.close(); src.close()
PY
  docker cp -q "$CONTAINER:/tmp/rehearse.db" "$REHEARSE_DIR/agent_commons.db"
  docker exec "$CONTAINER" rm -f /tmp/rehearse.db

  echo "[INFO] Starting $img as $REHEARSE_CONTAINER on 127.0.0.1:$REHEARSE_WEB_PORT/$REHEARSE_MCP_PORT"
  docker run -d --name "$REHEARSE_CONTAINER" \
    -p "127.0.0.1:$REHEARSE_WEB_PORT:8765" -p "127.0.0.1:$REHEARSE_MCP_PORT:8766" \
    -v "$REHEARSE_DIR:/data" "$img" >/dev/null

  check_service "$REHEARSE_CONTAINER" "$version" 180 || rc=1
  if [ "$rc" = 0 ]; then
    if docker exec "$REHEARSE_CONTAINER" curl -sf -o /dev/null "http://127.0.0.1:8765/api/v1/situations?q=agent&limit=1"; then
      echo "[INFO] search ok"
    else
      echo "[ERROR] search failed" >&2
      rc=1
    fi
  fi
  errors="$(docker logs "$REHEARSE_CONTAINER" 2>&1 | grep -cE 'Traceback|ERROR|CRITICAL' || true)"
  if [ "$errors" != 0 ]; then
    echo "[ERROR] $errors error line(s) in the rehearsal log (docker logs $REHEARSE_CONTAINER)" >&2
    rc=1
  fi

  if [ "${AGENT_COMMONS_REHEARSE_KEEP:-0}" = 1 ]; then
    echo "[INFO] Kept $REHEARSE_CONTAINER and $REHEARSE_DIR (remove: docker rm -f $REHEARSE_CONTAINER; rm -rf $REHEARSE_DIR)"
  else
    docker rm -f "$REHEARSE_CONTAINER" >/dev/null
    rm -rf "$REHEARSE_DIR"
  fi
  if [ "$rc" = 0 ]; then
    echo "[INFO] Rehearsal of $img passed"
  else
    echo "[ERROR] Rehearsal of $img failed" >&2
  fi
  return "$rc"
}

is_switch() {
  case "$1" in
    build|rehearse|backup|_backup|update|_update|refresh|up|down|restart|verify|logs) return 0 ;;
    *) return 1 ;;
  esac
}

run_cmd() {
  local cmd="$1" arg="${2:-}"
  case "$cmd" in
    build)
      do_build "$arg"
      ;;
    rehearse)
      do_rehearse "$arg"
      ;;
    backup)
      run_detached_if_interactive backup do_backup
      ;;
    _backup)
      do_backup
      ;;
    update)
      run_detached_if_interactive update do_update
      ;;
    _update)
      do_update
      ;;
    refresh)
      do_update
      run_compose up -d
      ;;
    up)
      run_compose up -d
      ;;
    down)
      run_compose down
      ;;
    restart)
      run_compose down
      run_compose up -d
      ;;
    verify)
      do_verify
      ;;
    logs)
      run_compose logs -f
      ;;
  esac
}

usage() {
  echo "Usage: $0 [switch ...]" >&2
  echo "  Switches can be combined, e.g. down _backup up verify" >&2
  echo "" >&2
  echo "  build [ref]     - Build agent-commons:<sha7> from <ref> of Gitea asyla/agent-commons (default: the compose.yml pin)" >&2
  echo "  rehearse [ref]  - Run that image on a copy of the live DB (127.0.0.1:$REHEARSE_WEB_PORT/$REHEARSE_MCP_PORT), check it, remove it" >&2
  echo "  backup   - rsync mirror of $APP_ROOT to $BACKUP_DIR; history: nas01 ZFS snapshots (screen if interactive)" >&2
  echo "  update   - Build the configured image only if it is missing; never starts anything" >&2
  echo "  refresh  - update, then up" >&2
  echo "  up       - Start containers (recreates the container if the configured image changed)" >&2
  echo "  down     - Stop containers" >&2
  echo "  restart  - Down then up" >&2
  echo "  verify   - Running image is the configured one; health app_version matches it; MCP initialize on :8766" >&2
  echo "  logs     - Follow logs" >&2
  echo "" >&2
  echo "  Pinned in compose.yml: $(pinned_image)" >&2
  echo "  APP_ROOT: $APP_ROOT" >&2
}

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

# Parse everything first, so a typo fails before any switch runs. build and rehearse take an
# optional argument: the next word, unless it is itself a switch.
CMDS=()
ARGS=()
while [ $# -gt 0 ]; do
  if ! is_switch "$1"; then
    echo "[ERROR] Unknown switch: $1" >&2
    usage
    exit 1
  fi
  cmd="$1"
  shift
  arg=""
  if { [ "$cmd" = build ] || [ "$cmd" = rehearse ]; } && [ $# -gt 0 ] && ! is_switch "$1"; then
    arg="$1"
    shift
  fi
  CMDS+=("$cmd")
  ARGS+=("$arg")
done

# Called plainly (not under if/||) so set -e stops at the first failing step.
for i in "${!CMDS[@]}"; do
  run_cmd "${CMDS[$i]}" "${ARGS[$i]}"
done
