#!/bin/bash
# theOrg's communications on d06 (NATS, chat-api and its message store, webhook-to-mq, vector, and
# the mail relay, asyla #657).
# Usage: communications.sh [switch ...], e.g. up|down|restart|backup|restore|verify|update|logs|relay-status;
# switches can be combined; `import PATH` stands alone (C4: another host's backup into the mirror,
# never restored by it), as does `relay-arm` (the heal's wrapping token on stdin, for the relay).
# Loads ~/scripts/docker/common.env. No file asyla writes, here or on the
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

# One tag for every communications image: the theOrg commit the hand-off names (beff7c55). The
# registry lost the bare-sha tag (asyla #1372), and theOrg republished the same commit as the dated
# tag below (publish-images run 28646, theOrg #1373; operator 2026-11-24 "Republish beff7c55,
# dated"). Pin another by hand with COMMS_TAG_OVERRIDE=<a published theOrg tag>, then
# `backup update up verify` with it.
COMMS_TAG="${COMMS_TAG_OVERRIDE:-beff7c55c9880facd23a1c289f667de5c1692795-20261126}"
REGISTRY="gitea.asyla.org"
# Where the theOrg images are named from. COMMS_REGISTRY_OVERRIDE is for a lab only (locally built
# images under another prefix: README.md, Lab); the deploy never sets it.
COMMS_REGISTRY="${COMMS_REGISTRY_OVERRIDE:-$REGISTRY/theorg}"
SERVED_NAME="theorg.asyla.org"

# The mail relay's own tag (asyla #657): theOrg communications aa1af97a, whose relay image
# publish-images pushed (theOrg #1097). Separate from COMMS_TAG, so moving one does not move the
# other. Pin another by hand with COMMS_RELAY_TAG_OVERRIDE=<a published theOrg sha>.
COMMS_RELAY_TAG="${COMMS_RELAY_TAG_OVERRIDE:-aa1af97aba037256eb10b0de16bd5b91bcab870e}"
# Found by its compose labels (no container_name); one container is expected.
RELAY_SERVICE="mail-relay"
RELAY_TLS_NAME="mail-relay.asyla.org"
# The relay's log lines (theOrg scripts/openbao.py BROKER_WAITING, mail-relay/relay.py:646).
RELAY_WAITING_LINE="wrapped token spent: waiting for the token broker"
RELAY_LISTENING_LINE="listening on 2587"
# Logged once the heal's wrapping token reached it, before its leaf (mail-relay/token_role.py:156).
RELAY_DELIVERED_LINE="token broker: wrapping token delivered and unwrapped"
# arm.py's user: not the relay's own uid 10001, which arm.py refuses (DEPLOY.md, Mail relay on d06).
RELAY_ARM_UID="10002"

# step-ca's root, "theOrg-v2 Root CA" (expires 2036-08-29), copied from internal-access
# hosts/d03/upstream-ca/theorg-v2-root.pem (1c4446c), byte-identical to
# d05/apps/identity-platform/theorg-v2-root.crt. Its SHA-256 in lower-case hex is compose.yml's
# MAIL_RELAY_STEPCA_ROOT_SHA256; a root rotation re-pins d05 and d06 together.
CA_SOURCE="$SCRIPT_DIR/theorg-v2-root.crt"
CA_FINGERPRINT="CD:39:1A:56:AE:00:0B:01:A4:43:3A:73:F2:2D:98:A3:73:E5:BB:08:E8:D7:75:31:DF:2D:B8:6A:4F:29:87:D3"
CA_DIR="$APP_ROOT/mail-relay-ca"
CA_FILE="$CA_DIR/root_ca.crt"

export DOCKER_DL DOCKER_D1 COMMS_ROOT COMMS_TAG COMMS_REGISTRY COMMS_RELAY_TAG

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

# The temp directory of this run: the pull config and the generated nats override. Removed at exit,
# as is the work directory of an import (IMPORT_WORK, a copy of the chat history).
RUN_TMP=""
IMPORT_WORK=""
remove_run_tmp() {
  if [ -n "$RUN_TMP" ]; then rm -rf "$RUN_TMP"; fi
  if [ -n "$IMPORT_WORK" ]; then rm -rf "$IMPORT_WORK"; fi
}
trap remove_run_tmp EXIT
run_tmp() {
  if [ -z "$RUN_TMP" ]; then RUN_TMP="$(mktemp -d)" || return; fi
}

# Set by prepare_nats: the override naming nats's NATS_PW_<i> (names only, no value).
NATS_OVERRIDE=""
# Set by do_up when ticketing's network is missing: webhook-to-mq-vikunja on communications_net only.
NO_TICKETING_OVERRIDE=""
# Vikunja's network (d06/apps/ticketing/compose.yml names it ticketing_net); compose.yml's ticketing.
TICKETING_NET="${COMMS_TICKETING_NET:-ticketing_net}"

run_compose() {
  local files=(-f "$COMPOSE_FILE")
  if [ -n "$NATS_OVERRIDE" ]; then files+=(-f "$NATS_OVERRIDE"); fi
  if [ -n "$NO_TICKETING_OVERRIDE" ]; then files+=(-f "$NO_TICKETING_OVERRIDE"); fi
  docker compose "${files[@]}" --project-directory "$SCRIPT_DIR" "$@"
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

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi
}

# The certificate's SHA-256 (of its DER) as upper-case colon pairs, for a file holding exactly one
# certificate; nothing otherwise. As d05/apps/identity-platform/identity-platform.sh.
ca_fingerprint() {
  local f="$1" n hex
  [ -f "$f" ] || return 0
  n="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$f" 2>/dev/null)" || n=0
  [ "$n" = 1 ] || return 0
  hex="$(awk '/-----BEGIN CERTIFICATE-----/{f=1;next} /-----END CERTIFICATE-----/{f=0} f' "$f" \
    | base64 -d 2>/dev/null | sha256_hex)" || return 0
  printf '%s' "$hex" | tr '[:lower:]' '[:upper:]' | sed -E 's/(..)/\1:/g; s/:$//'
}

# step-ca's public root for the relay: the committed copy is checked before it is placed (atomic,
# 0644), and the placed one after. Fails before anything is started or stopped.
place_ca() {
  local fp tmp
  fp="$(ca_fingerprint "$CA_SOURCE")"
  if [ "$fp" != "$CA_FINGERPRINT" ]; then
    echo "[ERROR] $CA_SOURCE does not hold one certificate with SHA-256 $CA_FINGERPRINT (got ${fp:-none}); not placing it, not starting" >&2
    return 1
  fi
  mkdir -p "$CA_DIR" || return
  if ! cmp -s "$CA_SOURCE" "$CA_FILE"; then
    tmp="$(mktemp "$CA_DIR/.root_ca.XXXXXX")" || return
    cp "$CA_SOURCE" "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$CA_FILE" || { rm -f "$tmp"; return 1; }
    echo "[INFO] placed step-ca's root CA at $CA_FILE"
  fi
  check_ca
}

check_ca() {
  local fp
  fp="$(ca_fingerprint "$CA_FILE")"
  if [ "$fp" = "$CA_FINGERPRINT" ]; then
    echo "[INFO] $CA_FILE: theOrg-v2 Root CA, SHA-256 $CA_FINGERPRINT"
  else
    echo "[ERROR] $CA_FILE does not match SHA-256 $CA_FINGERPRINT (got ${fp:-none})" >&2
    return 1
  fi
}

# Sets RELAY_CID to the one relay container, by its compose labels. Returns 1 when there is none,
# 2 when docker fails or there is more than one. Its stdin is /dev/null, so relay-arm's stdin is
# left for arm.py.
RELAY_CID=""
relay_find() {
  local ids n
  RELAY_CID=""
  ids="$(docker ps -aq --filter label=com.docker.compose.project=communications \
    --filter "label=com.docker.compose.service=$RELAY_SERVICE" </dev/null)" || {
    echo "[ERROR] docker ps failed: the mail-relay container is unknown" >&2
    return 2
  }
  n="$(grep -c . <<< "$ids")" || n=0
  case "$n" in
    0) return 1 ;;
    1) RELAY_CID="$ids" ;;
    *) echo "[ERROR] $n mail-relay containers in project communications, expected one" >&2; return 2 ;;
  esac
}

# Sets RELAY_STATE to one word: absent, waiting, armed, running, stopped or restarting. waiting:
# running, and its log since this start (docker logs --since its StartedAt, so a restart's wait
# counts afresh) holds the token wait's line with neither "listening on 2587" nor the broker's
# delivered line after it. armed: the delivered line follows the last wait, with no listening line
# after the wait and the container not healthy (no leaf yet: step-ca, the clock, the provisioner).
# Reads the container's State and that log only, never its Config (which holds its environment).
RELAY_STATE=""
relay_state() {
  local rc=0 st started logs w d l health
  RELAY_STATE=""
  relay_find || rc=$?
  if [ "$rc" = 1 ]; then RELAY_STATE="absent"; return 0; fi
  [ "$rc" = 0 ] || return 1
  st="$(docker inspect -f '{{.State.Status}} {{.State.StartedAt}}' "$RELAY_CID" </dev/null)" || {
    echo "[ERROR] docker inspect of the mail-relay container failed" >&2
    return 1
  }
  started="${st#* }"
  st="${st%% *}"
  case "$st" in
    running) ;;
    restarting) RELAY_STATE="restarting"; return 0 ;;
    *) RELAY_STATE="stopped"; return 0 ;;
  esac
  logs="$(docker logs --since "$started" "$RELAY_CID" 2>&1 </dev/null)" || {
    echo "[ERROR] docker logs of the mail-relay container failed" >&2
    return 1
  }
  w="$(grep -nF -- "$RELAY_WAITING_LINE" <<< "$logs" | tail -n 1 | cut -d: -f1)" || w=""
  d="$(grep -nF -- "$RELAY_DELIVERED_LINE" <<< "$logs" | tail -n 1 | cut -d: -f1)" || d=""
  l="$(grep -nF -- "$RELAY_LISTENING_LINE" <<< "$logs" | tail -n 1 | cut -d: -f1)" || l=""
  RELAY_STATE="running"
  if [ -z "$w" ] || { [ -n "$l" ] && [ "$l" -gt "$w" ]; }; then
    return 0
  fi
  if [ -z "$d" ] || [ "$d" -lt "$w" ]; then
    RELAY_STATE="waiting"
    return 0
  fi
  # Armed since the wait, not yet listening: running once healthy, else armed.
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$RELAY_CID" </dev/null 2>/dev/null)" || health=""
  [ "$health" = healthy ] || RELAY_STATE="armed"
}

# Prints the word. Exit 0, except armed: exit RELAY_ARMED_RC, so the heal (which arms on waiting
# only) neither judges nor re-arms a relay that already holds its token; 1 when it cannot be read.
RELAY_ARMED_RC=3
do_relay_status() {
  relay_state || return 1
  echo "$RELAY_STATE"
  [ "$RELAY_STATE" != armed ] || return "$RELAY_ARMED_RC"
}

# host-maintenance's heal (runner/heal.py) runs this over ssh with one line on stdin: a single-use
# wrapping token for the relay (never in argv, an environment or a file). This script reads nothing
# from stdin and never traces (no set -x), so ssh's stdin goes straight to arm.py, which runs as
# uid 10002 (the relay's PID 1 is 10001) and hands it to the relay on 127.0.0.1:9117 inside the
# container. arm.py's ok or fail, and its exit code, are this script's.
do_relay_arm() {
  local rc=0
  relay_find || rc=$?
  if [ "$rc" = 1 ]; then
    echo "[ERROR] no mail-relay container in project communications: nothing to arm" >&2
    exit 1
  fi
  [ "$rc" = 0 ] || exit 1
  exec docker exec -i -u "$RELAY_ARM_UID" "$RELAY_CID" python3 /app/arm.py
}

COMMS_RELAY_WAIT_S="${COMMS_RELAY_WAIT_S:-60}"

# verify's relay check. Waits up to COMMS_RELAY_WAIT_S for it to reach waiting (just started:
# not yet logged) or healthy. absent and waiting warn: the heal arms it, so a build's verify right
# after up passes. healthy: theOrg's STARTTLS probe, verified for mail-relay.asyla.org against
# step-ca's root (fatal). Anything else (armed but still not healthy, running but unhealthy,
# stopped, restarting) is fatal.
check_relay() {
  local health deadline
  deadline=$(( $(date +%s) + COMMS_RELAY_WAIT_S ))
  while :; do
    relay_state || { echo "[ERROR] mail-relay: its state could not be read" >&2; return 1; }
    health=""
    if [ "$RELAY_STATE" = running ]; then
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$RELAY_CID" </dev/null 2>/dev/null)" || health=""
    fi
    case "$RELAY_STATE:$health" in absent:*|waiting:*|running:healthy) break ;; esac
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 5
  done
  case "$RELAY_STATE:$health" in
    absent:*)
      echo "[WARN] mail-relay is not deployed (no container in project communications)" >&2 ;;
    waiting:*)
      echo "[WARN] mail-relay is running unarmed, waiting to be armed; host-maintenance's hourly heal arms it (runner/heal.py; a TASK=heal pipeline arms it now)" >&2 ;;
    armed:*)
      echo "[ERROR] mail-relay is armed (its wrapping token delivered) but not healthy after ${COMMS_RELAY_WAIT_S} s: no leaf certificate yet; check step-ca's reach, this host's clock, and the relay's provisioner record (the heal does not re-arm it)" >&2
      return 1 ;;
    running:healthy)
      if docker exec "$RELAY_CID" python3 /app/smoke.py probe --tls-name "$RELAY_TLS_NAME" </dev/null; then
        echo "[INFO] mail-relay healthy; smoke.py probe (STARTTLS, verified for $RELAY_TLS_NAME) OK"
      else
        echo "[ERROR] mail-relay smoke.py probe --tls-name $RELAY_TLS_NAME failed" >&2
        return 1
      fi ;;
    *)
      echo "[ERROR] mail-relay is $RELAY_STATE${health:+ ($health)}: neither waiting for its token nor healthy" >&2
      return 1 ;;
  esac
}

COMMS_WAIT_S="${COMMS_WAIT_S:-180}"

# DEPLOY.md, Start order 2-3, with the users written before nats starts (nats reads them, and
# their passwords, at start). nats is recreated when users.conf changed while it ran: a reload
# would re-read the file but not the environment that holds the passwords.
do_up() {
  local nats_was_running
  place_ca || return
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
  # Vikunja reaches webhook-to-mq over ticketing's network. Never created here (ticketing's compose
  # owns it): without it webhook-to-mq starts on communications_net alone, as vector below.
  if ! docker network inspect "$TICKETING_NET" >/dev/null 2>&1; then
    echo "[WARN] network $TICKETING_NET does not exist (d06/apps/ticketing down?): webhook-to-mq-vikunja starts on communications_net only, so Vikunja's webhooks cannot reach it; start ticketing, then run up again" >&2
    NO_TICKETING_OVERRIDE="$SCRIPT_DIR/compose.no-ticketing.yml"
  fi
  run_compose up -d --wait --wait-timeout "$COMMS_WAIT_S" webhook-to-mq-vikunja || return
  if docker network inspect "${COMMS_OBSERVABILITY_NET:-observability_observability-net}" >/dev/null 2>&1; then
    run_compose up -d vector || return
  else
    echo "[WARN] vector not started: network ${COMMS_OBSERVABILITY_NET:-observability_observability-net} does not exist (d06/apps/observability down?); communications' logs and chronicle episodes are lost" >&2
  fi
  # No --wait: the relay stays unhealthy until host-maintenance's heal arms it (relay-arm).
  run_compose up -d "$RELAY_SERVICE" || return
  if relay_state; then
    echo "[INFO] mail-relay container started (unarmed until the heal; relay-status says waiting once it waits for its token); now: $RELAY_STATE"
  else
    echo "[WARN] mail-relay started, but its state could not be read" >&2
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

# C4 P2: another host's copy of the message store (the Mini's final backup) into the mirror, where
# restore reads it. How it reaches d06: import_from_host.sh, run on the workstation, streams the
# four files from the source host over ssh, as a tar, into $IMPORT_DIR, then runs this (README.md,
# Import). `import PATH` takes that tar, or a directory holding the four files, already on this
# host. It checks the copy as theOrg's restore will (STATUS starts "OK "; manifest.sha256 lists
# exactly comms.dump and tables.tsv, each with its sha256; tables.tsv is schema<TAB>table<TAB>rows
# and names public.messages), owner-only in a work directory owned by this user (files 0600, the
# directory 0700: as the stage after a backup), then mirrors it with backup_lib's
# do_rsync_mirror_backup. Its .backup-status reads IN PROGRESS until the copy is complete and OK
# after, and restore takes only an OK mirror, so restore never sees a half copy. A mirror that
# already holds anything is refused unless IMPORT_FORCE=1 (the NAS snapshots keep the one it
# replaces). Needs no start value, no container and no compose call. Never restores: that is
# `RESTORE_FORCE=1 communications.sh restore`, its own approval.
IMPORT_DIR="$APP_ROOT/import"
IMPORT_FILES=(STATUS comms.dump tables.tsv manifest.sha256)

# cat as this user, or through sudo -n when the file is another user's owner-only (the image's 999).
read_file() {
  if [ -r "$1" ]; then cat -- "$1"; else as_root cat -- "$1"; fi
}

# theOrg's _read_status, _check_manifest, _read_tables and its expected public.messages
# (scripts/comms_backup.py at beff7c55). Sets IMPORT_STATUS and IMPORT_MESSAGES; prints one [ERROR]
# line on a failure.
check_backup_copy() {
  local d="$1" f line digest name got names=" " n=0 tables
  for f in "${IMPORT_FILES[@]}"; do
    if [ -L "$d/$f" ] || [ ! -f "$d/$f" ]; then
      echo "[ERROR] import: $f is missing or not a regular file" >&2
      return 1
    fi
  done
  IMPORT_STATUS="$(head -1 "$d/STATUS")"
  case "$IMPORT_STATUS" in
    "OK "*) ;;
    *) echo "[ERROR] import: STATUS does not start with \"OK \" (${IMPORT_STATUS:0:60}); not a completed backup" >&2; return 1 ;;
  esac
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    digest="${line%%  *}"
    name="${line#*  }"
    if [ "$digest" = "$line" ] || ! [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
      echo "[ERROR] import: manifest.sha256 line $n is malformed" >&2
      return 1
    fi
    case "$name" in
      comms.dump|tables.tsv) ;;
      *) echo "[ERROR] import: manifest.sha256 line $n names ${name:0:60}, not comms.dump or tables.tsv" >&2; return 1 ;;
    esac
    case "$names" in *" $name "*)
      echo "[ERROR] import: manifest.sha256 names $name twice" >&2
      return 1 ;;
    esac
    names="$names$name "
    got="$(sha256sum < "$d/$name")" || return
    if [ "${got%% *}" != "$digest" ]; then
      echo "[ERROR] import: sha256 mismatch: $name (a damaged or partial copy)" >&2
      return 1
    fi
  done < "$d/manifest.sha256"
  if [ "$n" -ne 2 ]; then
    echo "[ERROR] import: manifest.sha256 lists $n files, expected comms.dump and tables.tsv" >&2
    return 1
  fi
  tables="$(awk -F'\t' 'NF != 3 || $3 !~ /^[0-9]+$/ { print "bad " NR; exit }
    $1 == "public" && $2 == "messages" { m = $3 } END { if (m != "") print "messages " m; else print "none" }' "$d/tables.tsv")" || return
  case "$tables" in
    "messages "*) IMPORT_MESSAGES="${tables#messages }" ;;
    "bad "*) echo "[ERROR] import: tables.tsv line ${tables#bad } is malformed" >&2; return 1 ;;
    *) echo "[ERROR] import: tables.tsv does not name public.messages" >&2; return 1 ;;
  esac
}

import_copy() {
  local src="$1" f theirs="" their_mark="" newer=""
  if [ -L "$src" ] || { [ ! -f "$src" ] && [ ! -d "$src" ]; }; then
    echo "[ERROR] import: $src is not a file or a directory on this host (import_from_host.sh copies it here: README.md, Import)" >&2
    return 1
  fi
  mkdir -p "$IMPORT_DIR" || return
  chmod 0700 "$IMPORT_DIR" || return
  IMPORT_WORK="$(mktemp -d "$IMPORT_DIR/import.XXXXXX")" || return
  if [ -d "$src" ]; then
    for f in "${IMPORT_FILES[@]}"; do
      if [ -L "$src/$f" ] || [ ! -f "$src/$f" ]; then
        echo "[ERROR] import: $src/$f is missing or not a regular file" >&2
        return 1
      fi
      read_file "$src/$f" > "$IMPORT_WORK/$f" || return
    done
  else
    # Only the four names, at the top of the tar, as this user: no other member, owner or mode lands.
    if ! read_file "$src" | tar -xf - -C "$IMPORT_WORK" --no-same-owner --no-same-permissions "${IMPORT_FILES[@]}"; then
      echo "[ERROR] import: $src is not a tar holding ${IMPORT_FILES[*]} at its top (as import_from_host.sh writes it)" >&2
      return 1
    fi
    # Before the chmod below, which would follow a symlink member out of the work directory.
    for f in "${IMPORT_FILES[@]}"; do
      if [ -L "$IMPORT_WORK/$f" ] || [ ! -f "$IMPORT_WORK/$f" ]; then
        echo "[ERROR] import: $f in $src is not a regular file" >&2
        return 1
      fi
    done
  fi
  chmod 0600 "${IMPORT_FILES[@]/#/$IMPORT_WORK/}" || return
  chmod 0700 "$IMPORT_WORK" || return
  check_backup_copy "$IMPORT_WORK" || return
  echo "[INFO] import: manifest OK; STATUS $IMPORT_STATUS; public.messages $IMPORT_MESSAGES rows (tables.tsv)"
  if [ -e "$BACKUP_DIR" ] && [ -n "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
    theirs="$(head -1 "$BACKUP_DIR/STATUS" 2>/dev/null)" || theirs=""
    their_mark="$(head -1 "$BACKUP_DIR/.backup-status" 2>/dev/null)" || their_mark=""
    if [[ "$theirs" > "$IMPORT_STATUS" ]]; then newer=", newer than this import's"; fi
    if [ "${IMPORT_FORCE:-0}" != 1 ]; then
      echo "[ERROR] import: $BACKUP_DIR already holds a backup (STATUS ${theirs:-none}$newer; .backup-status ${their_mark:-none}); not overwriting it (IMPORT_FORCE=1 replaces it; the NAS snapshots keep the old one)" >&2
      return 1
    fi
    echo "[WARN] import: IMPORT_FORCE=1: replacing the backup in $BACKUP_DIR (STATUS ${theirs:-none}$newer)" >&2
  fi
  do_rsync_mirror_backup "$IMPORT_WORK" "$BACKUP_DIR" -- "${STAGE_EXCLUDES[@]}" || return
  case "$(head -1 "$BACKUP_DIR/.backup-status" 2>/dev/null)" in
    OK*) ;;
    *) echo "[ERROR] import: $BACKUP_DIR/.backup-status is not OK after the mirror" >&2; return 1 ;;
  esac
  echo "[INFO] import: in $BACKUP_DIR ($(head -1 "$BACKUP_DIR/.backup-status")); not restored: RESTORE_FORCE=1 $0 restore puts it into the live store (its own approval)"
}

# umask 077 for the import only, so no copy of the chat history is ever readable by another user.
do_import() {
  local um rc=0
  um="$(umask)"
  umask 077
  import_copy "$@" || rc=$?
  umask "$um"
  return "$rc"
}

# build_host.py's replica guard: pull what is missing (with the workstation's pull token), then
# print the images of the default services, one per line, on stdout only.
do_images() {
  pull_missing >&2 || return
  run_compose config --images
}

do_update() {
  echo "[INFO] Pulling images for tag $COMMS_TAG, the mail relay's for $COMMS_RELAY_TAG (not starting; use up or restart)"
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
  check_relay || rc=1
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
      place_ca || return
      run_compose down || return
      do_up
      ;;
    verify)
      do_verify
      ;;
    relay-status)
      do_relay_status || exit
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
  echo "  import PATH - alone: another host's backup (a tar from import_from_host.sh, or a directory of" >&2
  echo "             STATUS comms.dump tables.tsv manifest.sha256) already on this host, checked, into" >&2
  echo "             $BACKUP_DIR; refused over one there unless IMPORT_FORCE=1; never restores" >&2
  echo "  update   - Pull the images for COMMS_TAG (screen if interactive); use up/restart to start" >&2
  echo "  pull     - Pull the images now (inline)" >&2
  echo "  images   - Pull missing images, then list the default services' images (build_host.py's replica guard)" >&2
  echo "  up       - Place and check step-ca's root, write the NATS users, then start in DEPLOY.md's order" >&2
  echo "             (pulls missing images first), the mail relay last with no wait (unarmed until the heal);" >&2
  echo "             refused unless ${START_ENV[*]}" >&2
  echo "             are in the environment (from OpenBao at deploy; in no file asyla writes)" >&2
  echo "  down     - Stop and remove the containers" >&2
  echo "  restart  - Down then up (checks the environment first, as up)" >&2
  echo "  verify   - chat-api /health and chat_smoke.py, nats /healthz, anonymous refused on 4222 and 8080," >&2
  echo "             webhook-to-mq-vikunja /health (all fatal; waits up to COMMS_WAIT_S, 180 s, for chat-api);" >&2
  echo "             mail-relay: absent or waiting warns, healthy runs smoke.py probe (fatal), else fatal," >&2
  echo "             armed but not healthy included (waits up to COMMS_RELAY_WAIT_S, 60 s, for waiting or healthy)" >&2
  echo "  relay-status - one word for the mail relay: absent, waiting, armed, running, stopped or restarting;" >&2
  echo "             exit 0, armed exit $RELAY_ARMED_RC (token delivered, no leaf yet: the heal must not re-arm), 1 unreadable" >&2
  echo "  relay-arm - alone: the wrapping token on stdin to arm.py in the relay as uid $RELAY_ARM_UID" >&2
  echo "             (host-maintenance's heal sends it over ssh's stdin); prints arm.py's ok or fail" >&2
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

# import takes a path, so it combines with no other switch.
if [ "$1" = "import" ]; then
  if [ $# -ne 2 ] || [ -z "$2" ]; then
    usage
    exit 1
  fi
  do_import "$2" || exit 1
  exit 0
fi

# relay-arm takes ssh's stdin, so it combines with no other switch (none may read that stdin).
if [ "$1" = "relay-arm" ]; then
  if [ $# -ne 1 ]; then
    usage
    exit 1
  fi
  do_relay_arm
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    usage
    exit 1
  fi
done
