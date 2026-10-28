#!/bin/bash
# theOrg's ticketing on d06 (Vikunja, vikunja-mcp). Usage: ticketing.sh [switch ...]
# e.g. up|down|restart|backup|restore|verify|update|configure|logs. Switches can be combined.
# Loads ~/scripts/docker/common.env. No secret is in any file here: on d06 the workstation resolves
# the two Dex client values from OpenBao at deploy and hands them to this process's environment
# (TICKETING_DEPLOY_DEX_CLIENT_SECRET, TICKETING_MCP_DEX_CLIENT_SECRET; asyla hub, the d06 item).
# Data under /mnt/docker/Ticketing; backup = theOrg's one-shot backup image into
# /mnt/docker/Ticketing/backup, then a mirror of that to /mnt/nas/data1/docker/Ticketing/mirror.
# Start order and commands: theOrg ticketing DEPLOY.md (main 3318188, the #20 merge), "Start order".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
VAULT_FILE="$SCRIPT_DIR/compose.vault.yml"
SCREEN_APP="ticketing"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
# shellcheck source=/dev/null
. "$HOME/scripts/docker/backup_lib.sh"

DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"
APP_NAME="Ticketing"
APP_ROOT="$DOCKER_DL/Ticketing"
BACKUP_DIR="$DOCKER_D1/Ticketing/mirror"

# The theOrg ticketing commit whose images run here: one sha for every ticketing image
# (DEPLOY.md, Images). 3318188 is theOrg main, the #20 merge (configure `accounts`, the last
# step of converge; publish-images run 14817, all four images). Change it here, commit, then
# `backup update up verify`.
TICKETING_TAG="${TICKETING_TAG_OVERRIDE:-33181888dce924112e0b3f11e7c4e77f5f32caac}"
TICKETING_ROOT="$APP_ROOT"
REGISTRY="gitea.asyla.org"

# The host this folder belongs to. On any other host (test01 as a replica of d06) the stack runs
# in replica mode: compose.yml alone (never compose.vault.yml), vikunja only, nothing that reaches
# or writes the vault; Vikunja there starts with no JWT setting (sessions on a replica are disposable).
SERVING_HOST="d06"
SERVED_NAME="vikunja.asyla.org"

export DOCKER_DL DOCKER_D1 LOCAL_TZ TICKETING_TAG TICKETING_ROOT

is_replica() {
  [ "$(hostname -s)" != "$SERVING_HOST" ]
}

run_compose() {
  if is_replica; then
    docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
  else
    docker compose -f "$COMPOSE_FILE" -f "$VAULT_FILE" --project-directory "$SCRIPT_DIR" "$@"
  fi
}

# On d06, up, restart and configure start vault clients: refuse before anything is stopped unless
# both Dex values are in this process's environment. Checks presence only; never prints them.
require_dex() {
  is_replica && return 0
  if [ -z "${TICKETING_DEPLOY_DEX_CLIENT_SECRET:-}" ] || [ -z "${TICKETING_MCP_DEX_CLIENT_SECRET:-}" ]; then
    echo "[ERROR] the Dex client secrets come from OpenBao at deploy, in this process's environment (asyla hub d06 item); not starting" >&2
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$APP_ROOT/db" "$APP_ROOT/mcp-data" "$APP_ROOT/backup" "$APP_ROOT/vector"
}

# Pulls never log in and never write a credential: they run under a throwaway DOCKER_CONFIG whose
# config.json names only the credential helper beside this script (docker-credential-ticketing-env),
# which hands Docker TICKETING_REGISTRY_PULL_TOKEN from this process's environment (the workstation
# sends it at use; build_host.py pull_token_env). `docker compose` is a CLI plugin and Docker also
# looks for plugins in the system directories, not only in $DOCKER_CONFIG/cli-plugins: on the
# hosts (Docker's docker-compose-plugin package, /usr/libexec/docker/cli-plugins) it is still found
# (checked on Debian bookworm, 2026-10-18).
PULL_CONFIG=""
remove_pull_config() { if [ -n "$PULL_CONFIG" ]; then rm -rf "$PULL_CONFIG"; fi; }
trap remove_pull_config EXIT

pull_compose() {
  if [ -z "${TICKETING_REGISTRY_PULL_TOKEN:-}" ]; then
    echo "[ERROR] TICKETING_REGISTRY_PULL_TOKEN is not in this process's environment; the pull token comes from the workstation (build_host.py pulls before restore and apps)" >&2
    return 1
  fi
  if [ -z "$PULL_CONFIG" ]; then
    PULL_CONFIG="$(mktemp -d)" || return
    printf '{"credHelpers":{"%s":"ticketing-env"}}\n' "$REGISTRY" > "$PULL_CONFIG/config.json" || return
  fi
  ( export DOCKER_CONFIG="$PULL_CONFIG" PATH="$SCRIPT_DIR:$PATH"; run_compose "$@" )
}

do_pull() {
  pull_compose --profile ops pull || return
  if vector_wanted; then pull_compose --profile vector pull vector || return; fi
}

vector_wanted() {
  [ -n "${LOKI_ADDRESS:-}" ] && [ -n "${CHRONICLE_VECTOR_ADDRESS:-}" ]
}

# Pulls only images that are missing, so `up` on a running host does not move to a new image by
# itself (that is `update`).
pull_missing() {
  local img imgs missing=false
  # Not a process substitution: its failure would read as "nothing missing" and skip the pull.
  imgs="$(run_compose --profile ops config --images)" \
    || { echo "[ERROR] docker compose config failed; not pulling" >&2; return 1; }
  while read -r img; do
    [ -n "$img" ] || continue
    docker image inspect "$img" >/dev/null 2>&1 || missing=true
  done <<< "$imgs"
  $missing || return 0
  if [ -z "${TICKETING_REGISTRY_PULL_TOKEN:-}" ]; then
    echo "[ERROR] images missing; the pull token comes from the workstation (build_host.py pulls before restore and apps)" >&2
    return 1
  fi
  do_pull
}

do_up() {
  ensure_dirs
  pull_missing || return
  if is_replica; then
    echo "[INFO] Replica of $SERVING_HOST ($(hostname -s)): vikunja only, no JWT setting, no vault"
    run_compose up -d --no-deps vikunja
    return
  fi
  # DEPLOY.md, Start order 1-5. Each configure run is safe to repeat.
  run_compose --profile ops run --rm configure jwt-secret || return
  run_compose up -d vikunja || return
  run_compose --profile ops run --rm configure || return
  run_compose up -d vikunja-mcp || return
  if vector_wanted; then
    run_compose --profile vector up -d vector || return
  else
    echo "[WARN] vector not started (LOKI_ADDRESS and CHRONICLE_VECTOR_ADDRESS unset): chronicle episodes from ticketing are lost" >&2
  fi
}

do_configure() {
  if is_replica; then
    echo "[ERROR] configure writes to the vault; never on a replica" >&2
    return 1
  fi
  run_compose --profile ops run --rm configure
}

# Only the host that serves vikunja.asyla.org backs up to $BACKUP_DIR: a copy that is not the live
# ticketing (d06 before the cutover, a replica) would overwrite the live backup with its own data.
# The rule of d04's gitea.sh.
require_serving_host() {
  local addrs mine a m
  addrs="$(getent ahostsv4 "$SERVED_NAME" 2>/dev/null | awk '{print $1}' | sort -u)" || addrs=""
  if [ -z "$addrs" ]; then
    echo "[ERROR] $SERVED_NAME does not resolve here; not backing up (only the host that serves it backs up to $BACKUP_DIR)" >&2
    exit 1
  fi
  mine="$(hostname -I 2>/dev/null)" || mine=""
  for a in $addrs; do
    for m in $mine; do
      [ "$a" = "$m" ] && return 0
    done
  done
  echo "[ERROR] $SERVED_NAME resolves to ${addrs//$'\n'/ }, not to this host (${mine:-no address}); not backing up: $BACKUP_DIR belongs to the host that serves it" >&2
  exit 1
}

# theOrg's image makes one consistent copy while Vikunja runs (SQLite online backup) and writes
# STATUS last; verify re-checks it, scratch restore included. Only then is it mirrored.
do_backup() {
  ensure_dirs
  pull_missing || return
  run_compose --profile ops run --rm backup backup || return
  run_compose --profile ops run --rm backup verify || return
  case "$(head -1 "$APP_ROOT/backup/STATUS" 2>/dev/null)" in
    OK*) ;;
    *) echo "[ERROR] $APP_ROOT/backup/STATUS is not OK after a passing verify; not mirroring" >&2; return 1 ;;
  esac
  do_rsync_mirror_backup "$APP_ROOT/backup" "$BACKUP_DIR" -- --exclude=/.work/
}

# Rebuilt host only. Refuses when db/ holds data (build_host.py reads that as "data present").
# The staging copy in backup/ is only ever a copy, so it is overwritten; theOrg's restore runs
# verify first and refuses a copy that fails it.
# A seeded copy (backup/SEED, written last by the asyla hub's seed_ticketing.py: the Mini's data
# put straight into backup/) is restored as it stands, only when its STATUS is OK, and the NAS
# mirror is not read; SEED is removed after a passing restore, and the next backup writes the mirror.
do_restore() {
  if [ -d "$APP_ROOT/db" ] && [ -n "$(ls -A "$APP_ROOT/db" 2>/dev/null)" ]; then
    echo "[ERROR] $APP_ROOT/db is not empty; refusing to restore over it" >&2
    return 1
  fi
  if [ -n "$(run_compose ps -q vikunja 2>/dev/null)" ]; then
    echo "[ERROR] vikunja is running; stop it before a restore" >&2
    return 1
  fi
  ensure_dirs
  if [ -f "$APP_ROOT/backup/SEED" ]; then
    case "$(head -1 "$APP_ROOT/backup/STATUS" 2>/dev/null)" in
      OK*) ;;
      *) echo "[ERROR] seeded copy's STATUS is not OK; not restoring" >&2; return 1 ;;
    esac
    pull_missing || return
    run_compose --profile ops run --rm backup restore || return
    rm -f "$APP_ROOT/backup/SEED"
    echo "[INFO] restored from the seeded copy (SEED); the next backup writes the NAS mirror"
    return 0
  fi
  RESTORE_FORCE=1 do_rsync_mirror_restore "$BACKUP_DIR" "$APP_ROOT/backup" || return
  pull_missing || return
  run_compose --profile ops run --rm backup restore
}

# build_host.py's replica guard: pull what is missing (with the workstation's pull token), then print the
# images of the default services, one per line, on stdout only; each is probed for egress.
do_images() {
  pull_missing >&2 || return
  run_compose config --images
}

do_update() {
  echo "[INFO] Pulling images for tag $TICKETING_TAG (not starting; use up or restart)"
  do_pull
}

TICKETING_VERIFY_WAIT_S="${TICKETING_VERIFY_WAIT_S:-120}"
LOCAL_VIKUNJA="${TICKETING_LOCAL_VIKUNJA:-http://127.0.0.1:3456}"
PUBLIC_URL="${TICKETING_PUBLIC_URL:-https://vikunja.asyla.org}"

# Prints "METRICS MCP": the status of GET /metrics and of POST /mcp with no bearer (000: no answer).
MCP_PROBE='
import urllib.request, urllib.error
def status(req):
    try:
        return urllib.request.urlopen(req, timeout=10).status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return "000"
base = "http://127.0.0.1:8766"
ping = urllib.request.Request(base + "/mcp", data=b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}",
                              headers={"Content-Type": "application/json"}, method="POST")
print(status(base + "/metrics"), status(ping))
'

wait_ready() {
  local deadline
  deadline=$(( $(date +%s) + TICKETING_VERIFY_WAIT_S ))
  until curl -sf -o /dev/null --max-time 5 "$LOCAL_VIKUNJA/api/v1/info"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 2
  done
}

# DEPLOY.md, Health checks. Local checks are fatal. The public name reaches the Mini until the
# cutover, so it is reported, as d04's gitea.sh does, and fails only when it does not answer.
do_verify() {
  local rc=0 codes metrics mcp
  wait_ready || true
  if curl -sf -o /dev/null --max-time 15 "$LOCAL_VIKUNJA/api/v1/info"; then
    echo "[INFO] vikunja $LOCAL_VIKUNJA/api/v1/info OK"
  else
    echo "[ERROR] vikunja $LOCAL_VIKUNJA/api/v1/info failed" >&2
    rc=1
  fi
  if is_replica; then
    echo "[INFO] Replica: vikunja-mcp and $PUBLIC_URL not checked (not run here / production's name)"
    return "$rc"
  fi
  # vikunja-mcp is not published: checked from inside its container, with its own python.
  codes="$(run_compose exec -T vikunja-mcp python -c "$MCP_PROBE" 2>/dev/null)" || codes="000 000"
  read -r metrics mcp <<< "$codes"
  if [ "${metrics:-}" = "200" ]; then
    echo "[INFO] vikunja-mcp /metrics OK"
  else
    echo "[ERROR] vikunja-mcp /metrics answered ${metrics:-nothing}, not 200" >&2
    rc=1
  fi
  if [ "${mcp:-}" = "401" ]; then
    echo "[INFO] vikunja-mcp refuses a call with no bearer (401)"
  else
    echo "[ERROR] vikunja-mcp /mcp with no bearer answered ${mcp:-nothing}, not 401" >&2
    rc=1
  fi
  if curl -sf -o /dev/null --max-time 20 "$PUBLIC_URL/api/v1/info"; then
    echo "[INFO] $PUBLIC_URL OK"
  else
    echo "[ERROR] $PUBLIC_URL/api/v1/info failed" >&2
    rc=1
  fi
  return "$rc"
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)
      require_serving_host
      run_detached_if_interactive backup do_backup
      ;;
    _backup)
      require_serving_host
      do_backup
      ;;
    restore)
      do_restore
      ;;
    update)
      run_detached_if_interactive update do_update
      ;;
    _update)
      do_update
      ;;
    pull)
      do_pull
      ;;
    images)
      do_images
      ;;
    up)
      require_dex
      do_up
      ;;
    configure)
      require_dex
      do_configure
      ;;
    down)
      run_compose --profile vector down
      ;;
    restart)
      require_dex
      run_compose --profile vector down
      do_up
      ;;
    verify)
      do_verify
      ;;
    *)
      return 1
      ;;
  esac
}

usage() {
  echo "Usage: $0 [switch ...]" >&2
  echo "  Switches can be combined, e.g. update up verify" >&2
  echo "" >&2
  echo "  backup    - theOrg's backup image into $APP_ROOT/backup, verify, then mirror it to $BACKUP_DIR" >&2
  echo "              (screen if interactive); refused unless $SERVED_NAME resolves to this host" >&2
  echo "  restore   - $BACKUP_DIR into an empty $APP_ROOT/db through theOrg's restore (rebuilt host)" >&2
  echo "  update    - Pull the images for TICKETING_TAG (screen if interactive); use up/restart to start" >&2
  echo "  pull      - Pull the images now (inline)" >&2
  echo "  images    - Pull missing images, then list the default services' images (build_host.py's replica guard)" >&2
  echo "  up        - Start in DEPLOY.md's order (pulls missing images first; replica: vikunja only)" >&2
  echo "              on d06 refused unless TICKETING_DEPLOY_DEX_CLIENT_SECRET and TICKETING_MCP_DEX_CLIENT_SECRET" >&2
  echo "              are in the environment (from OpenBao at deploy; never in a file)" >&2
  echo "  configure - Run theOrg's configure converge alone (d06 only; same environment as up)" >&2
  echo "  down      - Stop and remove the containers" >&2
  echo "  restart   - Down then up (checks the environment first, as up)" >&2
  echo "  verify    - Vikunja on 127.0.0.1:3456 (fatal); on d06 also vikunja-mcp from inside its container" >&2
  echo "              (/metrics 200, /mcp with no bearer 401; fatal) and $PUBLIC_URL" >&2
  echo "  logs      - Follow logs (optionally for one service)" >&2
}

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    usage
    exit 1
  fi
done
