#!/bin/bash
# theOrg's observability stack on d06 (Loki without its gateway, Prometheus, the trends Prometheus,
# Alertmanager, alert-relay, emporia-collector, scrape-proxy, Vector and the probes). Usage:
# observability.sh [switch ...], e.g. up|down|restart|verify|update|pull|images|logs|status;
# switches can be combined. Loads ~/scripts/docker/common.env. From theOrg observability DEPLOY.md
# at main 64a2bf35c19275dadc577cdb37f9434064cf0842 (README.md here says what asyla changed).
#
# No secret is in any file or volume, here or on the host, on disk or in memory (asyla SEC-5 and
# SEC-7; the operator, 2026-11-03: secrets live only in OpenBao). Nothing here writes a value
# anywhere. Values reach this process only as named environment variables that the workstation
# sends at use over SSH stdin (build_host.py, d06/host.toml):
# - OBSERVABILITY_REGISTRY_PULL_TOKEN (pull_token_env), for the image pulls, answered by the
#   credential helper beside this script under a throwaway DOCKER_CONFIG;
# - ALERT_RELAY_, EMPORIA_ and SCRAPE_PROXY_OPENBAO_WRAPPED_TOKEN (start_env_optional): each a
#   single-use wrapping token that deploy_role.py mints from the observability-d06 token role.
#   Its container unwraps it once at start and holds the real token in memory, so what Docker
#   keeps in the container's config is spent. A wrapping token lapses 300 s after it is minted, so
#   `up` never pulls while one is here (the deploy runs `images` first).
# A tokened service starts only when its token is here; without it, it is left as it is (VAULT_READERS).
# compose.yml's header says what is on and off, README.md what turns each on.
# Data under /mnt/docker/Observability (d06's local data disk; never NFS).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
# shellcheck disable=SC2034 # read by backup_lib.sh run_detached_if_interactive
SCREEN_APP="observability"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
# run_detached_if_interactive (update in screen when a person runs it from a terminal).
if [ -f "$HOME/scripts/docker/backup_lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/backup_lib.sh"
fi

DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
OBSERVABILITY_ROOT="$DOCKER_DL/Observability"

# The theOrg observability commit whose images run here: one sha for every image (DEPLOY.md,
# Images). 64a2bf3 is theOrg main (#311, design 4). Change it here, commit, then deploy (README.md,
# Deploy).
OBSERVABILITY_TAG="${OBSERVABILITY_TAG_OVERRIDE:-64a2bf35c19275dadc577cdb37f9434064cf0842}"
REGISTRY="gitea.asyla.org"
# Already pulled for the stack, here and on a replica; also the throwaway container that sets the
# data directories' owners: theOrg's Dockerfile.loki ends USER root on grafana/loki (Alpine: sh,
# chown). Not the gateway's image any more: it is not in the stack, and at 64a2bf3 it is FROM
# scratch, with no shell.
LOKI_IMAGE="$REGISTRY/theorg/observability-loki:$OBSERVABILITY_TAG"

# The host this folder belongs to. On any other host (test01 as a replica of d06) the stack runs
# the services below only: no alert-relay (it files issues on the forge), no emporia-collector or
# scrape-proxy (they read production's OpenBao records) and no Vector (its chronicle episodes would
# reach production's memory-system).
SERVING_HOST="d06"
REPLICA_SERVICES="loki prometheus prometheus-trends alertmanager pushgateway docker-state-exporter blackbox-exporter"

# The services that read OpenBao in-process, each through the single-use wrapped token in the
# variable token_var names. Each starts only when its token is here: started without one,
# emporia-collector exits and the other two serve nothing, so `up --wait` would fail or the
# service would sit idle. Without its token a service is left as it is, running or not.
VAULT_READERS="alert-relay emporia-collector scrape-proxy"

# asyla's settings (asyla hub, the observability-on-d06 item).
PROMETHEUS_EXTERNAL_URL="${PROMETHEUS_EXTERNAL_URL:-https://prometheus.asyla.org}"
ALERTMANAGER_EXTERNAL_URL="${ALERTMANAGER_EXTERNAL_URL:-https://alertmanager.asyla.org}"
GITEA_URL="https://gitea.asyla.org"
GITEA_ALERT_REPO="asyla/alerts"
ALERT_REPOS=""
# memory-system's Vector on the Mini (theOrg lead, 2026-11-03).
CHRONICLE_VECTOR_ADDRESS="10.0.0.150:6000"
COMPOSE_PROJECT_NAME="observability"
# Where alert-relay, emporia-collector and scrape-proxy read their secrets (theOrg's default).
OPENBAO_ADDR="https://vault.asyla.org"
# Critical alerts by email: Alertmanager's email piece posts them to alert-relay, which sends them
# with the SMTP login it reads from OpenBao (theOrg deploy.yml's recipient).
ALERT_EMAIL_TO="shepner@asyla.org"
# Alertmanager's watchdog piece: off until secret/hubs/asyla/observability-watchdog-ping-url
# exists. Set to "on" to turn it on (alert-relay already names the record, compose.yml).
ALERT_WATCHDOG_PING=""
# Scraped by the trends Prometheus through scrape-proxy (theOrg deploy.yml's address).
HOME_ASSISTANT_URL="https://homeassistant.asyla.org"

# The blackbox-selftest job's three probes of Prometheus (theOrg prometheus/scrape-optional/
# blackbox-exporter.yml), each of which must read 1 (DEPLOY.md: deploy.yml requires all three).
SELF_PROBES_WANT="http_2xx=1 icmp=1 tcp_connect=1"

VERIFY_WAIT_S="${OBSERVABILITY_VERIFY_WAIT_S:-300}"

export DOCKER_DL OBSERVABILITY_ROOT OBSERVABILITY_TAG PROMETHEUS_EXTERNAL_URL ALERTMANAGER_EXTERNAL_URL \
  GITEA_URL GITEA_ALERT_REPO ALERT_REPOS CHRONICLE_VECTOR_ADDRESS COMPOSE_PROJECT_NAME \
  OPENBAO_ADDR ALERT_EMAIL_TO ALERT_WATCHDOG_PING HOME_ASSISTANT_URL

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

is_replica() {
  [ "$(hostname -s)" != "$SERVING_HOST" ]
}

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

# The variable that carries a tokened service's wrapped token; fails for any other service.
token_var() {
  case "$1" in
    alert-relay) echo ALERT_RELAY_OPENBAO_WRAPPED_TOKEN ;;
    emporia-collector) echo EMPORIA_OPENBAO_WRAPPED_TOKEN ;;
    scrape-proxy) echo SCRAPE_PROXY_OPENBAO_WRAPPED_TOKEN ;;
    *) return 1 ;;
  esac
}

# True when the service is tokened and its token is here (set and not empty).
has_token() {
  local var
  var="$(token_var "$1")" || return 1
  [ -n "${!var:-}" ]
}

# The tokened services whose token is here (space-separated; empty when none is).
tokens_here() {
  local svc out=""
  for svc in $VAULT_READERS; do
    if has_token "$svc"; then out="$out $svc"; fi
  done
  echo "${out# }"
}

# The tokened services whose token is not here.
tokens_absent() {
  local svc out=""
  for svc in $VAULT_READERS; do
    if ! has_token "$svc"; then out="$out $svc"; fi
  done
  echo "${out# }"
}

# The pull's throwaway DOCKER_CONFIG, removed on exit.
PULL_CONFIG=""
cleanup() {
  if [ -n "$PULL_CONFIG" ]; then rm -rf "$PULL_CONFIG"; fi
}
trap cleanup EXIT

# --- images -------------------------------------------------------------------------------------

# Pulls never log in and never write a credential: they run under a throwaway DOCKER_CONFIG whose
# config.json names only the credential helper beside this script (docker-credential-observability-env),
# which hands Docker OBSERVABILITY_REGISTRY_PULL_TOKEN from this process's environment
# (build_host.py pull_token_env). Docker Hub images (pushgateway) pull anonymously. As ticketing.sh.
pull_compose() {
  if [ -z "${OBSERVABILITY_REGISTRY_PULL_TOKEN:-}" ]; then
    echo "[ERROR] OBSERVABILITY_REGISTRY_PULL_TOKEN is not in this process's environment; the pull token comes from the workstation (build_host.py pull_token_env)" >&2
    return 1
  fi
  if [ -z "$PULL_CONFIG" ]; then
    PULL_CONFIG="$(mktemp -d)" || return
    printf '{"credHelpers":{"%s":"observability-env"}}\n' "$REGISTRY" > "$PULL_CONFIG/config.json" || return
  fi
  ( export DOCKER_CONFIG="$PULL_CONFIG" PATH="$SCRIPT_DIR:$PATH"; run_compose "$@" )
}

do_pull() {
  pull_compose pull
}

# The images the stack names that are not on this host, space-separated (empty when none is).
missing_images() {
  local img imgs out=""
  # Not a process substitution: its failure would read as "nothing missing" and skip the pull.
  imgs="$(run_compose config --images)" \
    || { echo "[ERROR] docker compose config failed" >&2; return 1; }
  while read -r img; do
    [ -n "$img" ] || continue
    docker image inspect "$img" >/dev/null 2>&1 || out="$out $img"
  done <<< "$imgs"
  echo "${out# }"
}

# Pulls only images that are missing, so `up` on a running host does not move to a new image by
# itself (that is `update`).
pull_missing() {
  local missing
  missing="$(missing_images)" || { echo "[ERROR] not pulling" >&2; return 1; }
  [ -n "$missing" ] || return 0
  if [ -z "${OBSERVABILITY_REGISTRY_PULL_TOKEN:-}" ]; then
    echo "[ERROR] images missing; the pull token comes from the workstation (build_host.py pull_token_env)" >&2
    return 1
  fi
  do_pull
}

# Before a start. With a wrapped token here nothing is pulled: a token lapses 300 s after it is
# minted and a pull could outlast it, so the deploy runs `images` before it mints them, and a
# missing image is an error. Without one, pull what is missing.
images_ready() {
  local missing
  if [ -z "$(tokens_here)" ]; then
    pull_missing
    return
  fi
  missing="$(missing_images)" || return
  [ -n "$missing" ] || return 0
  echo "[ERROR] not pulling with a wrapped token here (it lapses 300 s after it is minted); run \`images\` before minting. Missing: $missing" >&2
  return 1
}

do_images() {
  pull_missing >&2 || return
  run_compose config --images
}

do_update() {
  info "Pulling images for tag $OBSERVABILITY_TAG (not starting; use up or restart)"
  do_pull
}

# --- data directories -----------------------------------------------------------------------------

ensure_dirs() {
  mkdir -p "$OBSERVABILITY_ROOT/loki-data" "$OBSERVABILITY_ROOT/prometheus-data" \
    "$OBSERVABILITY_ROOT/prometheus-trends-data" "$OBSERVABILITY_ROOT/alertmanager-data"
}

# Owners the images run as: Prometheus, the trends Prometheus and Alertmanager are nobody (65534);
# Loki runs as root in theOrg's image (Dockerfile.loki ends USER root) and grafana/loki's own user
# is 10001, which suits both. Top directories only: what is inside is the service's own.
own_dirs() {
  docker run --rm --network none --pull never -v "$OBSERVABILITY_ROOT:/data" --entrypoint sh "$LOKI_IMAGE" -c \
    'chown 10001:10001 /data/loki-data && chown 65534:65534 /data/prometheus-data /data/prometheus-trends-data /data/alertmanager-data' \
    < /dev/null
}

# --- up -------------------------------------------------------------------------------------------

# Every `up` and `down` passes --remove-orphans: a service taken out of compose.yml leaves its
# container behind otherwise (loki-gateway-1 when 64a2bf3 dropped the gateway, option A). It
# removes only containers of this project whose service is not in compose.yml; a tokened service
# left out of the named list stays as it is. Measured with Compose v5.6.1 (d06's version) on a
# throwaway busybox project, 2026-11-03: a service dropped from the file was removed by
# `up -d --wait --remove-orphans <one service>` and another running service kept, while a service
# kept in the file under an inactive `profiles:` was not removed (so the gateway is dropped, not
# profiled out).
do_up() {
  local all svc services="" left=""
  ensure_dirs || return
  images_ready || return
  own_dirs || die "cannot set the data directories' owners under $OBSERVABILITY_ROOT"
  if is_replica; then
    info "Replica of $SERVING_HOST ($(hostname -s)): $REPLICA_SERVICES"
    # shellcheck disable=SC2086
    run_compose up -d --wait --wait-timeout "$VERIFY_WAIT_S" --remove-orphans $REPLICA_SERVICES
    return
  fi
  # Every service without a token, and each tokened service whose token is here (VAULT_READERS). Not a
  # process substitution: an empty list would start every service.
  all="$(run_compose config --services)" || die "docker compose config failed; not starting"
  for svc in $all; do
    if token_var "$svc" >/dev/null && ! has_token "$svc"; then
      left="$left $svc"
    else
      services="$services $svc"
    fi
  done
  [ -n "$services" ] || die "no service to start"
  if [ -n "$left" ]; then
    warn "no wrapped token for:$left; left as they are, running or not (README.md, Deploy)"
  fi
  info "starting:$services"
  # shellcheck disable=SC2086
  run_compose up -d --wait --wait-timeout "$VERIFY_WAIT_S" --remove-orphans $services
}

# --- verify, status -------------------------------------------------------------------------------

# On the serving host every service, except a tokened one with no container and no token here
# (never deployed, or taken down; not_deployed lists them). A tokened container that exists is
# expected to run: one looping on a spent token after a restart fails verify.
expected_services() {
  local all svc out=""
  if is_replica; then
    echo "$REPLICA_SERVICES"
    return
  fi
  all="$(run_compose config --services)" || return
  for svc in $all; do
    if token_var "$svc" >/dev/null && ! has_token "$svc" && [ "$(service_state "$svc")" = missing ]; then
      continue
    fi
    out="$out $svc"
  done
  echo "${out# }"
}

not_deployed() {
  local svc out=""
  is_replica && return 0
  for svc in $VAULT_READERS; do
    if ! has_token "$svc" && [ "$(service_state "$svc")" = missing ]; then out="$out $svc"; fi
  done
  echo "${out# }"
}

# "running healthy", "running none" (no healthcheck), ... or "missing".
service_state() {
  docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1-1" 2>/dev/null \
    || echo missing
}

wait_ready() {
  local deadline svc state ready
  deadline=$(( $(date +%s) + VERIFY_WAIT_S ))
  while :; do
    ready=true
    for svc in $(expected_services); do
      state="$(service_state "$svc")"
      case "$state" in "running healthy"|"running none") ;; *) ready=false ;; esac
    done
    $ready && return 0
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 5
  done
}

# The self-probes as "module=value ..." (sorted), from the operations Prometheus.
self_probes() {
  curl -sf --max-time 10 -G http://127.0.0.1:9090/api/v1/query \
      --data-urlencode 'query=probe_success{job="blackbox-selftest",instance=~"http://prometheus:9090/-/healthy|prometheus:9090|prometheus"}' \
    | python3 -c 'import json,sys; print(" ".join(sorted(r["metric"].get("module", "?") + "=" + r["value"][1] for r in json.load(sys.stdin)["data"]["result"])))'
}

# Waits for the first scrapes (the probe job runs every 60 s).
check_self_probes() {
  local deadline got=""
  deadline=$(( $(date +%s) + VERIFY_WAIT_S ))
  while :; do
    got="$(self_probes 2>/dev/null)" || got=""
    if [ "$got" = "$SELF_PROBES_WANT" ]; then
      info "blackbox self-probes: $got"
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 5
  done
  echo "[ERROR] blackbox self-probes read '${got:-nothing}', not '$SELF_PROBES_WANT'" >&2
  return 1
}

# The trends Prometheus's up{job="$1"} values (space-separated), from its 127.0.0.1:9107.
trends_up() {
  curl -sf --max-time 10 -G http://127.0.0.1:9107/api/v1/query --data-urlencode "query=up{job=\"$1\"}" \
    | python3 -c 'import json,sys; print(" ".join(sorted(r["value"][1] for r in json.load(sys.stdin)["data"]["result"])))'
}

# alert-relay's alert_relay_secret_present for its SMTP login, as "secret=value ..." (sorted), from
# its own metrics on 127.0.0.1:9111 (theOrg alert-relay/relay.py; compose.yml publishes it there).
relay_smtp_held() {
  curl -sf --max-time 10 http://127.0.0.1:9111/metrics \
    | python3 -c 'import re,sys; print(" ".join(sorted(m[0] + "=" + format(float(m[1]), "g") for m in re.findall(r"^alert_relay_secret_present\{secret=\"(smtp_username|smtp_password)\"\} (\S+)$", sys.stdin.read(), re.M))))'
}

# Waits until "$@" prints WANT ($1) or the shared deadline TOKENED_DEADLINE passes; the last
# reading is in GOT.
wait_reading() {
  local want="$1"
  shift
  while :; do
    GOT="$("$@" 2>/dev/null)" || GOT=""
    [ "$GOT" = "$want" ] && return 0
    [ "$(date +%s)" -lt "$TOKENED_DEADLINE" ] || return 1
    sleep 5
  done
}

# That each tokened service whose container exists holds its secrets, not only that it is
# healthy: the trends jobs scrape-proxy and emporia-collector serve (theOrg trends/scrape/
# asyla-home-assistant.yml and emporia.yml) read up 1, and alert-relay holds its SMTP login.
# The first scrape comes within a minute (scrape_interval 60s): one wait of VERIFY_WAIT_S for all.
check_tokened() {
  local rc=0
  TOKENED_DEADLINE=$(( $(date +%s) + VERIFY_WAIT_S ))
  if [ "$(service_state scrape-proxy)" != missing ]; then
    if wait_reading 1 trends_up asyla-home-assistant; then
      info "scrape-proxy: trends up{job=\"asyla-home-assistant\"} 1 (it holds the Home Assistant token)"
    else
      echo "[ERROR] scrape-proxy: trends up{job=\"asyla-home-assistant\"} reads '${GOT:-nothing}', not 1" >&2; rc=1
    fi
  fi
  if [ "$(service_state emporia-collector)" != missing ]; then
    if wait_reading 1 trends_up emporia; then
      info "emporia-collector: trends up{job=\"emporia\"} 1"
    else
      echo "[ERROR] emporia-collector: trends up{job=\"emporia\"} reads '${GOT:-nothing}', not 1" >&2; rc=1
    fi
  fi
  if [ "$(service_state alert-relay)" != missing ] && [ -n "$ALERT_EMAIL_TO" ]; then
    if wait_reading "smtp_password=1 smtp_username=1" relay_smtp_held; then
      info "alert-relay: alert_relay_secret_present 1 for smtp_username and smtp_password"
    else
      echo "[ERROR] alert-relay: alert_relay_secret_present reads '${GOT:-nothing}', not smtp_password=1 smtp_username=1" >&2; rc=1
    fi
  fi
  return "$rc"
}

# The lines Vector's container-log pipeline put in Loki in the last 10 minutes (theOrg
# vector-docker-logs.toml labels every one forwarder="vector-observability"), asked from inside
# observability-net: vector-1's own wget (Dockerfile.vector installs it) to loki:3100, the address
# Vector pushes to. Prints the count, 0 for none.
vector_lines() {
  local q
  q="$(python3 -c 'import urllib.parse; print(urllib.parse.quote("sum(count_over_time({forwarder=\"vector-observability\"}[10m]))", safe=""))')" || return
  docker exec vector-1 wget -q -O- "http://loki:3100/loki/api/v1/query?query=$q" < /dev/null \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(int(float(r[0]["value"][1])) if r else 0)'
}

# Waits up to VERIFY_WAIT_S for a line from Vector. Vector reads the stack's containers from the
# moment it starts, so a quiet stack could leave nothing; but Loki logs every query at info
# (caller=metrics.go; measured on grafana/loki:2.9.4, 2026-11-03, and theOrg's config sets no
# log_level), so this check's own first query gives Vector a line to ship.
check_vector_logs() {
  local deadline got=""
  deadline=$(( $(date +%s) + VERIFY_WAIT_S ))
  while :; do
    got="$(vector_lines 2>/dev/null)" || got=""
    if [[ "$got" =~ ^[1-9][0-9]*$ ]]; then
      info "vector: $got lines in Loki from this stack's containers in the last 10 minutes (forwarder vector-observability, read from vector-1 at loki:3100)"
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 5
  done
  echo "[ERROR] vector: Loki holds '${got:-nothing}' lines with forwarder vector-observability in the last 10 minutes, not 1 or more" >&2
  return 1
}

# What runs: the services, Prometheus and its Alertmanager, docker-state-exporter, the trends
# retention, the blackbox self-probes, Vector's container logs in Loki (not on a replica: no
# Vector) and the tokened services' secrets (check_tokened). The pieces that are off
# (compose.yml's header) have nothing to check.
do_verify() {
  local rc=0 svc state n body off
  off="$(not_deployed)"
  if [ -n "$off" ]; then warn "not deployed (no container, no wrapped token): $off"; fi
  wait_ready || true
  for svc in $(expected_services); do
    state="$(service_state "$svc")"
    case "$state" in
      "running healthy"|"running none") ;;
      *) echo "[ERROR] $svc: $state" >&2; rc=1 ;;
    esac
  done
  if [ "$rc" -eq 0 ]; then info "services running and healthy: $(expected_services)"; fi

  if curl -sf -o /dev/null --max-time 10 http://127.0.0.1:9090/-/healthy; then
    info "prometheus /-/healthy OK"
  else
    echo "[ERROR] prometheus 127.0.0.1:9090/-/healthy failed" >&2; rc=1
  fi
  n="$(curl -sf --max-time 10 http://127.0.0.1:9090/api/v1/alertmanagers \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]["activeAlertmanagers"]))' 2>/dev/null)" || n=""
  if [ "$n" = "1" ]; then
    info "prometheus has 1 active Alertmanager"
  else
    echo "[ERROR] prometheus active Alertmanagers: ${n:-unknown}, not 1" >&2; rc=1
  fi
  if curl -sf --max-time 10 http://127.0.0.1:9099/metrics | grep -q '^docker_container_running'; then
    info "docker-state-exporter: docker_container_running present on 127.0.0.1:9099"
  else
    echo "[ERROR] docker_container_running absent on 127.0.0.1:9099/metrics" >&2; rc=1
  fi
  body="$(curl -sf --max-time 10 http://127.0.0.1:9107/api/v1/status/runtimeinfo \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["storageRetention"])' 2>/dev/null)" || body=""
  if [[ "$body" =~ ^[0-9.]+[KMGTPE]?i?B$ ]]; then
    info "prometheus-trends storageRetention $body (a size alone)"
  else
    echo "[ERROR] prometheus-trends storageRetention is '${body:-unknown}', not a size alone" >&2; rc=1
  fi

  check_self_probes || rc=1
  if ! is_replica; then check_vector_logs || rc=1; fi
  check_tokened || rc=1

  if [ "$rc" -eq 0 ]; then info "verify OK"; else echo "[ERROR] verify failed" >&2; fi
  return "$rc"
}

do_status() {
  run_compose ps -a --format 'table {{.Name}}\t{{.Status}}'
}

# --- switches -------------------------------------------------------------------------------------

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    update)
      if declare -F run_detached_if_interactive >/dev/null; then
        run_detached_if_interactive update do_update
      else
        do_update
      fi
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
      do_up
      ;;
    down)
      run_compose down --remove-orphans
      ;;
    restart)
      # down removes the tokened containers too, and only their tokens bring them back: on the
      # serving host a restart needs every one (a deploy; README.md). Images are made ready before
      # the stack goes down, so a missing token or image never leaves it down.
      if ! is_replica && [ -n "$(tokens_absent)" ]; then
        echo "[ERROR] restart takes down $VAULT_READERS, and no wrapped token is here for: $(tokens_absent). Deploy instead (README.md, Deploy)" >&2
        return 1
      fi
      images_ready && run_compose down --remove-orphans && do_up
      ;;
    verify)
      do_verify
      ;;
    status)
      do_status
      ;;
    *)
      return 2
      ;;
  esac
}

usage() {
  echo "Usage: $0 [switch ...]" >&2
  echo "  Switches can be combined, e.g. update restart verify" >&2
  echo "" >&2
  echo "  update   - Pull the images for OBSERVABILITY_TAG (screen if interactive); use up/restart to start" >&2
  echo "  pull     - Pull the images now (inline)" >&2
  echo "  images   - Pull missing images, then list the images (build_host.py's replica guard;" >&2
  echo "             deploy_role.py's pull before it mints the wrapped tokens)" >&2
  echo "  up       - Data directories, missing images (none pulled with a wrapped token here), then" >&2
  echo "             the stack; a tokened service ($VAULT_READERS) only with its token" >&2
  echo "             (replica: $REPLICA_SERVICES)" >&2
  echo "  down     - Stop and remove every container (the data stays; the tokened ones need a deploy)" >&2
  echo "  restart  - images ready, then down, then up; on $SERVING_HOST only with every wrapped token" >&2
  echo "  verify   - Services running and healthy, Prometheus and its one Alertmanager," >&2
  echo "             docker-state-exporter, trends retention, the blackbox self-probes, Vector's" >&2
  echo "             container logs in Loki, the tokened services' secrets" >&2
  echo "  status   - Containers" >&2
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

# A switch that fails exits with its status; an unknown one (2) shows the usage too.
for cmd in "$@"; do
  rc=0
  run_cmd "$cmd" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 2 ]; then usage; fi
    exit "$rc"
  fi
done
