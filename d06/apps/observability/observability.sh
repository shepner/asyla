#!/bin/bash
# theOrg's observability stack on d06 (Loki and its gateway, Prometheus, the trends Prometheus,
# Alertmanager, alert-relay, Vector and the probes). Usage: observability.sh [switch ...], e.g.
# up|down|restart|verify|update|pull|images|logs|status; switches can be combined. Loads
# ~/scripts/docker/common.env. From theOrg observability DEPLOY.md at main
# 2144f83c3ec978663d3cb544e743ae8006471a0a (README.md here says what asyla changed).
#
# No secret is in any file or volume, here or on the host, on disk or in memory (asyla SEC-5 and
# SEC-7; the operator, 2026-11-03: secrets live only in OpenBao). Nothing here writes a value
# anywhere. Two values may reach this process, each only as a named environment variable that the
# workstation resolves from OpenBao and sends at use (build_host.py, d06/host.toml):
# - the image pulls use the variable named OBSERVABILITY_REGISTRY_PULL_TOKEN (pull_token_env),
#   answered by the credential helper beside this script under a throwaway DOCKER_CONFIG;
# - alert-relay's forge account uses the variable named OBSERVABILITY_ALERT_RELAY_GITEA_TOKEN, once
#   that account exists (optional: without it the relay serves and every delivery fails, with a WARN).
# Every piece that needs a secret any other way is off until theOrg's stack reads it from OpenBao
# itself (compose.yml's header says how each is off, README.md what turns each on).
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
# Images). 2144f83 is theOrg main (#298). Change it here, commit, then `update restart verify`.
OBSERVABILITY_TAG="${OBSERVABILITY_TAG_OVERRIDE:-2144f83c3ec978663d3cb544e743ae8006471a0a}"
REGISTRY="gitea.asyla.org"
# Already pulled for the stack; also the throwaway container that sets the data directories' owners.
GATEWAY_IMAGE="$REGISTRY/theorg/observability-loki-gateway:$OBSERVABILITY_TAG"

# The host this folder belongs to. On any other host (test01 as a replica of d06) the stack runs
# the services below only: no alert-relay (it files issues on the forge) and no Vector (its
# chronicle episodes would reach production's memory-system).
SERVING_HOST="d06"
REPLICA_SERVICES="loki loki-gateway prometheus prometheus-trends alertmanager pushgateway docker-state-exporter blackbox-exporter"

# asyla's settings (asyla hub, the observability-on-d06 item).
PROMETHEUS_EXTERNAL_URL="${PROMETHEUS_EXTERNAL_URL:-https://prometheus.asyla.org}"
ALERTMANAGER_EXTERNAL_URL="${ALERTMANAGER_EXTERNAL_URL:-https://alertmanager.asyla.org}"
GITEA_URL="https://gitea.asyla.org"
GITEA_ALERT_REPO="asyla/alerts"
ALERT_REPOS=""
# memory-system's Vector on the Mini (theOrg lead, 2026-11-03).
CHRONICLE_VECTOR_ADDRESS="10.0.0.150:6000"
COMPOSE_PROJECT_NAME="observability"

# The blackbox-selftest job's three probes of Prometheus (theOrg prometheus/scrape-optional/
# blackbox-exporter.yml), each of which must read 1 (DEPLOY.md: deploy.yml requires all three).
SELF_PROBES_WANT="http_2xx=1 icmp=1 tcp_connect=1"

VERIFY_WAIT_S="${OBSERVABILITY_VERIFY_WAIT_S:-300}"

export DOCKER_DL OBSERVABILITY_ROOT OBSERVABILITY_TAG PROMETHEUS_EXTERNAL_URL ALERTMANAGER_EXTERNAL_URL \
  GITEA_URL GITEA_ALERT_REPO ALERT_REPOS CHRONICLE_VECTOR_ADDRESS COMPOSE_PROJECT_NAME

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

is_replica() {
  [ "$(hostname -s)" != "$SERVING_HOST" ]
}

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
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

# Pulls only images that are missing, so `up` on a running host does not move to a new image by
# itself (that is `update`).
pull_missing() {
  local img imgs missing=false
  # Not a process substitution: its failure would read as "nothing missing" and skip the pull.
  imgs="$(run_compose config --images)" \
    || { echo "[ERROR] docker compose config failed; not pulling" >&2; return 1; }
  while read -r img; do
    [ -n "$img" ] || continue
    docker image inspect "$img" >/dev/null 2>&1 || missing=true
  done <<< "$imgs"
  $missing || return 0
  if [ -z "${OBSERVABILITY_REGISTRY_PULL_TOKEN:-}" ]; then
    echo "[ERROR] images missing; the pull token comes from the workstation (build_host.py pull_token_env)" >&2
    return 1
  fi
  do_pull
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
  docker run --rm --network none --pull never -v "$OBSERVABILITY_ROOT:/data" --entrypoint sh "$GATEWAY_IMAGE" -c \
    'chown 10001:10001 /data/loki-data && chown 65534:65534 /data/prometheus-data /data/prometheus-trends-data /data/alertmanager-data' \
    < /dev/null
}

# --- up -------------------------------------------------------------------------------------------

do_up() {
  ensure_dirs || return
  pull_missing || return
  own_dirs || die "cannot set the data directories' owners under $OBSERVABILITY_ROOT"
  if is_replica; then
    info "Replica of $SERVING_HOST ($(hostname -s)): $REPLICA_SERVICES"
    # shellcheck disable=SC2086
    run_compose up -d --wait --wait-timeout "$VERIFY_WAIT_S" $REPLICA_SERVICES
    return
  fi
  if [ -z "${OBSERVABILITY_ALERT_RELAY_GITEA_TOKEN:-}" ]; then
    warn "alert-relay files no issue: OBSERVABILITY_ALERT_RELAY_GITEA_TOKEN is not in this process's environment (add it to d06/host.toml start_env once its forge account exists; README.md)"
  fi
  run_compose up -d --wait --wait-timeout "$VERIFY_WAIT_S"
}

# --- verify, status -------------------------------------------------------------------------------

expected_services() {
  if is_replica; then
    echo "$REPLICA_SERVICES"
  else
    run_compose config --services | tr '\n' ' '
  fi
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

# What runs: the services, Prometheus and its Alertmanager, docker-state-exporter, the trends
# retention, the gateway (HTTP, failing closed) and the blackbox self-probes. The pieces that are
# off (compose.yml's header) have nothing to check.
do_verify() {
  local rc=0 svc state n body code
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

  if curl -sf -o /dev/null --max-time 10 http://127.0.0.1:3100/ready; then
    info "loki-gateway /ready over HTTP"
  else
    echo "[ERROR] loki-gateway http://127.0.0.1:3100/ready failed" >&2; rc=1
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST http://127.0.0.1:3100/loki/api/v1/push)" || code=""
  if [ "$code" = "401" ]; then
    info "loki-gateway refuses a push without an account (401): no accounts, so it fails closed"
  else
    echo "[ERROR] loki-gateway answered a push without an account with ${code:-nothing}, not 401" >&2; rc=1
  fi

  check_self_probes || rc=1

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
      run_compose down
      ;;
    restart)
      run_compose down && do_up
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
  echo "  images   - Pull missing images, then list the images (build_host.py's replica guard)" >&2
  echo "  up       - Data directories, missing images, then the stack (replica: $REPLICA_SERVICES)" >&2
  echo "  down     - Stop and remove every container (the data stays)" >&2
  echo "  restart  - down, then up" >&2
  echo "  verify   - Services running and healthy, Prometheus and its one Alertmanager," >&2
  echo "             docker-state-exporter, trends retention, the gateway over HTTP (failing" >&2
  echo "             closed), the blackbox self-probes" >&2
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
