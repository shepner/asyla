#!/bin/bash
# theOrg's communications on d06 (NATS, chat-api and its message store, webhook-to-mq, vector).
# Usage: communications.sh [switch ...], e.g. up|down|restart|backup|restore|verify|update|logs;
# switches can be combined. Loads ~/scripts/docker/common.env. No file asyla writes, here or on the
# host, holds a secret: the workstation resolves the five values below from OpenBao at deploy and
# hands them to this process's environment (build_host.py [[app]] start_env); up and restart refuse
# without them.
# NATS users: this script writes users.conf with user names and $NATS_PW_<i> references only, and
# gives nats each password in its environment, pre-quoted as a NATS string (README.md, NATS users).
# Data under /mnt/docker/Communications; backup = theOrg's one-shot backup image into
# /mnt/docker/Communications/backup, then a mirror of it to /mnt/nas/data1/docker/Communications/mirror.
# From theOrg communications DEPLOY.md at beff7c55: Start order, Backup, restore and verify, After a restore.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
# Read by backup_lib.sh (run_detached_if_interactive names its screen session with it).
# shellcheck disable=SC2034
SCREEN_APP="communications"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
# shellcheck source=/dev/null
. "$HOME/scripts/docker/backup_lib.sh"

DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"
APP_ROOT="$DOCKER_DL/Communications"
COMMS_ROOT="$APP_ROOT"
BACKUP_DIR="$DOCKER_D1/Communications/mirror"
# The mirror's readable copy: backup/ is the image's (uid 999, owner-only), so the mirror is
# copied from here, a copy owned by this user with the same owner-only modes.
STAGE_DIR="$APP_ROOT/mirror-stage"

# One tag for every communications image: the theOrg commit the hand-off names (beff7c55, whose
# images publish-images pushed). Pin another by hand with COMMS_TAG_OVERRIDE=<a theOrg sha whose
# images are published>, then `backup update up verify` with it.
COMMS_TAG="${COMMS_TAG_OVERRIDE:-beff7c55c9880facd23a1c289f667de5c1692795}"
REGISTRY="gitea.asyla.org"
# Where the theOrg images are named from. COMMS_REGISTRY_OVERRIDE is for a lab only (locally built
# images under another prefix: README.md, Lab); the deploy never sets it.
COMMS_REGISTRY="${COMMS_REGISTRY_OVERRIDE:-$REGISTRY/theorg}"
SERVED_NAME="theorg.asyla.org"

export DOCKER_DL DOCKER_D1 COMMS_ROOT COMMS_TAG COMMS_REGISTRY

# The values the start needs, from OpenBao at deploy (d06/host.toml start_env).
START_ENV=(COMMS_POSTGRES_PASSWORD COMMS_NATS_WEBHOOK_MQ_USERNAME COMMS_NATS_WEBHOOK_MQ_PASSWORD
  COMMS_CHAT_API_TOKEN COMMS_VIKUNJA_WEBHOOK_SECRET)

# Refuse before anything is stopped unless each named value is in this process's environment.
# Checks presence only; never prints a value.
require_env() {
  local n missing=()
  for n in "$@"; do
    [ -n "${!n:-}" ] || missing+=("$n")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "[ERROR] ${missing[*]} not in this process's environment: the workstation resolves them from OpenBao at deploy (build_host.py start_env); not starting" >&2
    exit 1
  fi
}

# sudo -n when this user is not root (d06's docker user has it); directly as root (a lab).
as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi
}

ensure_dirs() {
  mkdir -p "$APP_ROOT/nats-data" "$APP_ROOT/nats-runtime" "$APP_ROOT/pg-data" \
    "$APP_ROOT/webhook-buffer" "$APP_ROOT/vector" "$APP_ROOT/backup" || return
  # The backup image runs as uid 999 and writes owner-only files (DEPLOY.md, COMMS_BACKUP_DIR).
  if [ "$(stat -c '%u %g %a' "$APP_ROOT/backup")" != "999 999 700" ]; then
    as_root install -d -o 999 -g 999 -m 0700 "$APP_ROOT/backup"
  fi
}

# The temp directory of this run: the pull config and the generated nats override. Removed at exit.
RUN_TMP=""
remove_run_tmp() { if [ -n "$RUN_TMP" ]; then rm -rf "$RUN_TMP"; fi; }
trap remove_run_tmp EXIT
run_tmp() {
  if [ -z "$RUN_TMP" ]; then RUN_TMP="$(mktemp -d)" || return; fi
}

# Set by prepare_nats: the override naming nats's NATS_PW_<i> (names only, no value).
NATS_OVERRIDE=""

run_compose() {
  if [ -n "$NATS_OVERRIDE" ]; then
    docker compose -f "$COMPOSE_FILE" -f "$NATS_OVERRIDE" --project-directory "$SCRIPT_DIR" "$@"
  else
    docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
  fi
}

# The value as nats reads it from its environment: a double-quoted NATS string, \ and " escaped
# (theOrg's _esc). Unquoted, nats parses the value as config: `-abc` or `10k` is not a string.
# Sets the variable named $1 to it (printf -v: no subshell, no argv).
nats_quote() {
  local v="$2"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf -v "$1" '"%s"' "$v"
}

# The NATS users, as prefixes of <PREFIX>_USERNAME/_PASSWORD pairs in this environment: webhook-mq
# (chat-api's and webhook-to-mq's principal) first, then each COMMS_MQ_USER_<X> (the Staff workers'
# mq-users, start_env_optional), sorted by name. A half pair is refused.
nats_user_prefixes() {
  local n x other all
  NATS_PREFIXES=(COMMS_NATS_WEBHOOK_MQ)
  all="$(compgen -e | grep -E '^COMMS_MQ_USER_[A-Z0-9_]+_(USERNAME|PASSWORD)$' | sort -u || true)"
  for n in $all; do
    case "$n" in
      *_USERNAME) x="${n%_USERNAME}"; other="${x}_PASSWORD" ;;
      *) x="${n%_PASSWORD}"; other="${x}_USERNAME" ;;
    esac
    if [ -z "${!other+set}" ]; then
      echo "[ERROR] $n is set without $other; not writing NATS users" >&2
      return 1
    fi
    case "$n" in *_USERNAME) NATS_PREFIXES+=("$x") ;; esac
  done
}

# Refuses, before anything is written or stopped: no user, an empty user name or password, a
# repeated name, a control character, a `#` or `/` in a user name (theOrg's nats-entrypoint.sh
# effective() cuts a line at `#` or `//` before it looks for users, so such a name would read as
# no user), and a webhook-mq name or password outside A-Z a-z 0-9 _ - (chat-api percent-encodes
# both into its NATS URL and nats-py does not decode them: theOrg 1d961052). Prints no value.
check_nats_users() {
  local p un pn user pw seen=" "
  nats_user_prefixes || return
  for p in "${NATS_PREFIXES[@]}"; do
    un="${p}_USERNAME"; pn="${p}_PASSWORD"
    user="${!un:-}"; pw="${!pn:-}"
    if [ -z "$user" ] || [ -z "$pw" ]; then
      echo "[ERROR] NATS user $p: ${un} or ${pn} is empty; not writing NATS users" >&2
      return 1
    fi
    if [[ "$user$pw" == *[[:cntrl:]]* ]]; then
      echo "[ERROR] NATS user $p: a control character in ${un} or ${pn}; not writing NATS users" >&2
      return 1
    fi
    if [[ "$user" == *[#/]* ]]; then
      echo "[ERROR] NATS user $p: ${un} holds a # or a /, which theOrg's nats-entrypoint.sh reads as a comment; not writing NATS users" >&2
      return 1
    fi
    if [ "$p" = COMMS_NATS_WEBHOOK_MQ ] && ! [[ "$user" =~ ^[A-Za-z0-9_-]+$ && "$pw" =~ ^[A-Za-z0-9_-]+$ ]]; then
      echo "[ERROR] NATS user $p: ${un} or ${pn} holds a character outside A-Z a-z 0-9 _ -; chat-api percent-encodes it into its NATS URL and nats-py does not decode it (theOrg 1d961052); not writing NATS users" >&2
      return 1
    fi
    case "$seen" in *" $user "*)
      echo "[ERROR] NATS user $p: the user name of an earlier pair again; not writing NATS users" >&2
      return 1 ;;
    esac
    seen="$seen$user "
  done
  pw=""
  if [ "${#NATS_PREFIXES[@]}" -eq 0 ]; then
    echo "[ERROR] no NATS user; not writing users.conf (nats would run open after a reload)" >&2
    return 1
  fi
}

# Writes $APP_ROOT/nats-runtime/users.conf (atomically: a temp file in the same directory, then a
# rename) and the override, and exports NATS_PW_<i>. USERS_CHANGED=true when users.conf changed.
# check_nats_users refuses first.
prepare_nats() {
  local rt="$APP_ROOT/nats-runtime" users tmp i=0 p un pn q_user body=""
  local override_env=""
  check_nats_users || return
  for p in "${NATS_PREFIXES[@]}"; do
    un="${p}_USERNAME"; pn="${p}_PASSWORD"
    nats_quote q_user "${!un}"
    body="$body    { user: $q_user, password: \$NATS_PW_$i }"$'\n'
    nats_quote "NATS_PW_$i" "${!pn}"
    export "NATS_PW_$i"
    override_env="$override_env      - NATS_PW_$i"$'\n'
    i=$((i + 1))
  done
  mkdir -p "$rt" || return
  users="$rt/users.conf"
  tmp="$rt/users.conf.tmp.asyla.$$"
  # The $NATS_PW_<i> in the text is literal: nats resolves it from its environment.
  # shellcheck disable=SC2016
  printf '# Written by asyla-hosts d06/apps/communications/communications.sh. No password here: each\n# $NATS_PW_<i> is in the nats container'"'"'s environment (README.md, NATS users).\nauthorization {\n  users = [\n%s  ]\n}\n' "$body" > "$tmp" \
    || { rm -f "$tmp"; return 1; }
  if [ -f "$users" ] && cmp -s "$tmp" "$users"; then
    rm -f "$tmp"
    USERS_CHANGED=false
  else
    chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$users" || { rm -f "$tmp"; return 1; }
    USERS_CHANGED=true
  fi
  run_tmp || return
  NATS_OVERRIDE="$RUN_TMP/nats-users.override.yml"
  printf '# Generated by communications.sh: environment names only, the values are in its process.\nservices:\n  nats:\n    environment:\n%s' "$override_env" > "$NATS_OVERRIDE" || return
  echo "[INFO] NATS users: $i (users.conf $( $USERS_CHANGED && echo changed || echo unchanged))"
}

# Pulls never log in and never write a credential: they run under a throwaway DOCKER_CONFIG whose
# config.json names only the credential helper beside this script (docker-credential-communications-env),
# which hands Docker COMMUNICATIONS_REGISTRY_PULL_TOKEN from this process's environment (the
# workstation sends it at use; build_host.py pull_token_env). As ticketing.sh.
pull_compose() {
  if [ -z "${COMMUNICATIONS_REGISTRY_PULL_TOKEN:-}" ]; then
    echo "[ERROR] COMMUNICATIONS_REGISTRY_PULL_TOKEN is not in this process's environment; the pull token comes from the workstation (build_host.py pull_token_env)" >&2
    return 1
  fi
  run_tmp || return
  mkdir -p "$RUN_TMP/docker" || return
  printf '{"credHelpers":{"%s":"communications-env"}}\n' "$REGISTRY" > "$RUN_TMP/docker/config.json" || return
  ( export DOCKER_CONFIG="$RUN_TMP/docker" PATH="$SCRIPT_DIR:$PATH"; run_compose "$@" )
}

do_pull() {
  pull_compose --profile ops pull
}

# Pulls only images that are missing, so `up` on a running host does not move to a new image by
# itself (that is `update`).
pull_missing() {
  local img imgs need_pull=false
  # Not a process substitution: its failure would read as "nothing missing" and skip the pull.
  imgs="$(run_compose --profile ops config --images)" \
    || { echo "[ERROR] docker compose config failed; not pulling" >&2; return 1; }
  while read -r img; do
    [ -n "$img" ] || continue
    docker image inspect "$img" >/dev/null 2>&1 || need_pull=true
  done <<< "$imgs"
  $need_pull || return 0
  if [ -z "${COMMUNICATIONS_REGISTRY_PULL_TOKEN:-}" ]; then
    echo "[ERROR] images missing; the pull token comes from the workstation (build_host.py pull_token_env)" >&2
    return 1
  fi
  do_pull
}

COMMS_WAIT_S="${COMMS_WAIT_S:-180}"

# DEPLOY.md, Start order 2-3, with the users written before nats starts (nats reads them, and
# their passwords, at start). nats is recreated when users.conf changed while it ran: a reload
# would re-read the file but not the environment that holds the passwords.
do_up() {
  local nats_was_running
  ensure_dirs || return
  pull_missing || return
  prepare_nats || return
  nats_was_running="$(run_compose ps -q --status running nats 2>/dev/null)" || nats_was_running=""
  if $USERS_CHANGED && [ -n "$nats_was_running" ]; then
    echo "[INFO] users.conf changed while nats ran: recreating nats"
    run_compose up -d --wait --wait-timeout "$COMMS_WAIT_S" --force-recreate nats || return
  else
    run_compose up -d --wait --wait-timeout "$COMMS_WAIT_S" nats || return
  fi
  run_compose up -d nats-exporter || return
  run_compose up -d --wait --wait-timeout "$COMMS_WAIT_S" comms-postgres || return
  run_compose up -d --wait --wait-timeout "$COMMS_WAIT_S" chat-api || return
  run_compose up -d --wait --wait-timeout "$COMMS_WAIT_S" webhook-to-mq-vikunja || return
  if docker network inspect "${COMMS_OBSERVABILITY_NET:-observability_observability-net}" >/dev/null 2>&1; then
    run_compose up -d vector || return
  else
    echo "[WARN] vector not started: network ${COMMS_OBSERVABILITY_NET:-observability_observability-net} does not exist (d06/apps/observability down?); communications' logs and chronicle episodes are lost" >&2
  fi
}

# Only the host that serves theorg.asyla.org backs up to $BACKUP_DIR: a copy that is not the live
# chat (d06 before the cutover, while the name still reaches the Mini) would overwrite the live
# backup with its own data. ticketing.sh's rule.
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

# The message store's password for backup and restore: this process's COMMS_POSTGRES_PASSWORD (a
# deploy sends it), else the running comms-postgres container's own POSTGRES_PASSWORD, since
# build_host.py's restore phase and host-maintenance's nightly `backup` send none. docker inspect's
# template matches that one key and emits nothing else; the value lands in this process only
# (never printed, never on argv) and reaches theOrg's backup image as COMMS_POSTGRES_PASSWORD, the
# name compose.yml gives it. The docker group can read it there already (dockerd's config.v2.json,
# README.md, Secrets), so nothing new is exposed. Refuses when comms-postgres is not running.
pg_password() {
  local id v
  [ -z "${COMMS_POSTGRES_PASSWORD:-}" ] || return 0
  id="$(run_compose ps -q --status running comms-postgres 2>/dev/null)" || id=""
  id="${id%%$'\n'*}"
  if [ -z "$id" ]; then
    echo "[ERROR] COMMS_POSTGRES_PASSWORD is not in this process's environment and comms-postgres is not running to take it from; start the stack (up, from a deploy) or run with the value from OpenBao" >&2
    return 1
  fi
  v="$(docker inspect -f '{{range .Config.Env}}{{if eq (index (split . "=") 0) "POSTGRES_PASSWORD"}}{{.}}{{end}}{{end}}' "$id" 2>/dev/null)" || v=""
  v="${v#*=}"
  if [ -z "$v" ]; then
    echo "[ERROR] COMMS_POSTGRES_PASSWORD is not in this process's environment and the running comms-postgres has none to take" >&2
    return 1
  fi
  COMMS_POSTGRES_PASSWORD="$v"
  v=""
  export COMMS_POSTGRES_PASSWORD
  echo "[INFO] COMMS_POSTGRES_PASSWORD taken from the running comms-postgres container (not printed)"
}

# What no copy between backup/, the stage and the mirror carries or deletes: theOrg's .lock, the
# .work/ of a running backup, and the .pre-restore-<UTC time>/ safety copies its restore leaves in
# backup/ (DEPLOY.md: the deployer prunes them; they stay on this host, out of the mirror).
STAGE_EXCLUDES=(--exclude=/.work/ --exclude=/.lock --exclude='/.pre-restore-*/')

# theOrg's image makes one consistent copy while chat-api runs and writes STATUS last; verify
# re-checks it (scratch restore included). Then a readable copy is checked for STATUS OK and
# mirrored.
do_backup() {
  ensure_dirs || return
  pg_password || return
  pull_missing || return
  run_compose --profile ops run --rm backup backup || return
  run_compose --profile ops run --rm backup verify || return
  as_root rsync -a --delete "${STAGE_EXCLUDES[@]}" "$APP_ROOT/backup/" "$STAGE_DIR/" || return
  as_root chown -R "$(id -u):$(id -g)" "$STAGE_DIR" || return
  case "$(head -1 "$STAGE_DIR/STATUS" 2>/dev/null)" in
    OK*) ;;
    *) echo "[ERROR] $APP_ROOT/backup/STATUS is not OK after a passing verify; not mirroring" >&2; return 1 ;;
  esac
  do_rsync_mirror_backup "$STAGE_DIR" "$BACKUP_DIR" -- "${STAGE_EXCLUDES[@]}"
}

# Rebuilt host: refuses when pg-data holds data (build_host.py reads that as "data present"); a
# pg-data this user cannot list is comms-postgres's (initialised), so it holds data too.
# RESTORE_FORCE=1 restores over it (C4: the Mini's final copy into the running stack): theOrg's
# restore replaces the live database only while no other session is connected, and keeps the one
# it replaced in backup/.pre-restore-<UTC time>/ (DEPLOY.md, Undo a restore). The mirror goes back
# into backup/ through the stage (a stage a killed backup left owned by 999 is taken back first),
# comms-postgres starts or keeps running, chat-api is stopped, theOrg's restore runs (it verifies
# the copy first), and a chat-api that was running is started again (DEPLOY.md, After a restore).
do_restore() {
  local pg="$APP_ROOT/pg-data" chat_was_running
  if [ "${RESTORE_FORCE:-0}" != 1 ] && [ -d "$pg" ] \
      && { [ ! -r "$pg" ] || [ ! -x "$pg" ] || [ -n "$(ls -A "$pg" 2>/dev/null)" ]; }; then
    echo "[ERROR] $pg is not empty; refusing to restore over it (RESTORE_FORCE=1 replaces the live database: README.md, Data, backup and restore)" >&2
    return 1
  fi
  pg_password || return
  ensure_dirs || return
  if [ -e "$STAGE_DIR" ]; then as_root chown -R "$(id -u):$(id -g)" "$STAGE_DIR" || return; fi
  RESTORE_FORCE=1 do_rsync_mirror_restore "$BACKUP_DIR" "$STAGE_DIR" -- "${STAGE_EXCLUDES[@]}" || return
  as_root rsync -a --delete "${STAGE_EXCLUDES[@]}" "$STAGE_DIR/" "$APP_ROOT/backup/" || return
  as_root chown -R 999:999 "$APP_ROOT/backup" || return
  as_root chmod 0700 "$APP_ROOT/backup" || return
  pull_missing || return
  run_compose up -d --wait --wait-timeout "$COMMS_WAIT_S" comms-postgres || return
  chat_was_running="$(run_compose ps -q --status running chat-api 2>/dev/null)" || chat_was_running=""
  run_compose stop chat-api || return
  if ! run_compose --profile ops run --rm backup restore; then
    echo "[ERROR] theOrg's restore failed (its line above says why); chat-api is left stopped" >&2
    return 1
  fi
  if [ -n "$chat_was_running" ]; then
    run_compose start chat-api || return
    echo "[INFO] chat-api started again; run verify"
  fi
}

# build_host.py's replica guard: pull what is missing (with the workstation's pull token), then
# print the images of the default services, one per line, on stdout only.
do_images() {
  pull_missing >&2 || return
  run_compose config --images
}

do_update() {
  echo "[INFO] Pulling images for tag $COMMS_TAG (not starting; use up or restart)"
  do_pull
}

LOCAL_CHAT="${COMMS_LOCAL_CHAT:-http://127.0.0.1:9098}"
LOCAL_NATS_MON="${COMMS_LOCAL_NATS_MON:-http://127.0.0.1:8222}"

# GET http://127.0.0.1:<port>/health from inside a container with its own python: the status code.
HEALTH_PROBE='
import sys, urllib.request, urllib.error
try:
    print(urllib.request.urlopen("http://127.0.0.1:%s/health" % sys.argv[1], timeout=10).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print("000")
'

wait_chat() {
  local deadline
  deadline=$(( $(date +%s) + COMMS_WAIT_S ))
  until curl -sf -o /dev/null --max-time 5 "$LOCAL_CHAT/health"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 2
  done
}

# DEPLOY.md, After a restore, checks 1-4. Each is fatal. theorg.asyla.org is not checked: until
# the cutover it reaches the Mini.
do_verify() {
  local rc=0 code
  wait_chat || true
  if curl -sf -o /dev/null --max-time 15 "$LOCAL_CHAT/health"; then
    echo "[INFO] chat-api $LOCAL_CHAT/health OK"
  else
    echo "[ERROR] chat-api $LOCAL_CHAT/health failed" >&2
    rc=1
  fi
  if run_compose exec -T chat-api python /app/chat_smoke.py; then
    echo "[INFO] chat_smoke.py inside chat-api OK"
  else
    echo "[ERROR] chat_smoke.py inside chat-api failed" >&2
    rc=1
  fi
  if curl -sf --max-time 10 "$LOCAL_NATS_MON/healthz" | grep -q '"ok"'; then
    echo "[INFO] nats $LOCAL_NATS_MON/healthz ok"
  else
    echo "[ERROR] nats $LOCAL_NATS_MON/healthz is not ok" >&2
    rc=1
  fi
  # theOrg's check, vendored unchanged (theorg/): an anonymous connect refused on 4222 and 8080,
  # probed from inside communications_net with the chat-api image (already on the host).
  if NATS_CONTAINER=communications-nats-1 NATS_PROBE_IMAGE="$COMMS_REGISTRY/communications-chat-api:$COMMS_TAG" \
      bash "$SCRIPT_DIR/theorg/check_nats_refuses_anonymous.sh"; then
    echo "[INFO] nats refuses anonymous clients on 4222 and 8080"
  else
    echo "[ERROR] nats took an anonymous client, or the probe got no verdict; keep wss://nats.asyla.org off" >&2
    rc=1
  fi
  code="$(run_compose exec -T webhook-to-mq-vikunja python -c "$HEALTH_PROBE" 9092 2>/dev/null)" || code="000"
  if [ "$code" = "200" ]; then
    echo "[INFO] webhook-to-mq-vikunja /health OK (inside its container)"
  else
    echo "[ERROR] webhook-to-mq-vikunja /health answered ${code:-nothing}, not 200" >&2
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
      require_env "${START_ENV[@]}"
      do_up
      ;;
    down)
      run_compose down
      ;;
    restart)
      require_env "${START_ENV[@]}"
      check_nats_users || return
      run_compose down || return
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
  echo "  backup   - theOrg's backup image into $APP_ROOT/backup, verify, then mirror it to $BACKUP_DIR" >&2
  echo "             (screen if interactive); refused unless $SERVED_NAME resolves to this host;" >&2
  echo "             COMMS_POSTGRES_PASSWORD from the environment, else from the running comms-postgres" >&2
  echo "  restore  - $BACKUP_DIR into an empty $APP_ROOT/pg-data through theOrg's restore (rebuilt host);" >&2
  echo "             RESTORE_FORCE=1 replaces the live database (theOrg keeps it in backup/.pre-restore-*);" >&2
  echo "             the password as for backup" >&2
  echo "  update   - Pull the images for COMMS_TAG (screen if interactive); use up/restart to start" >&2
  echo "  pull     - Pull the images now (inline)" >&2
  echo "  images   - Pull missing images, then list the default services' images (build_host.py's replica guard)" >&2
  echo "  up       - Write the NATS users, then start in DEPLOY.md's order (pulls missing images first);" >&2
  echo "             refused unless ${START_ENV[*]}" >&2
  echo "             are in the environment (from OpenBao at deploy; in no file asyla writes)" >&2
  echo "  down     - Stop and remove the containers" >&2
  echo "  restart  - Down then up (checks the environment first, as up)" >&2
  echo "  verify   - chat-api /health and chat_smoke.py, nats /healthz, anonymous refused on 4222 and 8080," >&2
  echo "             webhook-to-mq-vikunja /health (all fatal; waits up to COMMS_WAIT_S, 180 s, for chat-api)" >&2
  echo "  logs     - Follow logs (optionally for one service)" >&2
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
