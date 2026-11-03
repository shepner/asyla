#!/bin/bash
# theOrg's observability stack on d06 (Loki without its gateway, Prometheus, the trends Prometheus,
# Alertmanager, alert-relay, emporia-collector, scrape-proxy, Vector and the probes). Usage:
# observability.sh [switch ...], e.g. up|down|restart|verify|update|pull|images|logs|status;
# switches can be combined. Loads ~/scripts/docker/common.env. From theOrg observability DEPLOY.md
# at main f7579118fdac5d90101a5ec6698200ae2c9d836f (README.md here says what asyla changed).
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
# Images). f757911 is theOrg main (#327: Prometheus scrapes loki:3100 over plain HTTP; design 4
# since #311). Change it here, commit, then deploy (README.md, Deploy).
OBSERVABILITY_TAG="${OBSERVABILITY_TAG_OVERRIDE:-f7579118fdac5d90101a5ec6698200ae2c9d836f}"
REGISTRY="gitea.asyla.org"
# Already pulled for the stack, here and on a replica; also the throwaway container that sets the
# data directories' owners: theOrg's Dockerfile.loki ends USER root on grafana/loki (Alpine: sh,
# chown). Not the gateway's image any more: it is not in the stack, and at f757911 it is FROM
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

# The operations Prometheus's own jobs at OBSERVABILITY_TAG, as job:service: theOrg
# prometheus/scrape-stack/*.yml (always read), the two optional pieces compose.yml switches on
# (scrape-optional/blackbox-exporter.yml, docker-state-exporter.yml) and base_config.py's own job.
# The service is the one a sample must follow the start of. theOrg's deploy.yml step "Verify this
# stack's own scrape targets are up" (#327) checks the scrape-stack jobs from its checkout's files;
# d06 has only the images, so they are listed here (check_stack_targets).
STACK_JOBS="prometheus:prometheus alert-relay:alert-relay alertmanager:alertmanager loki:loki
  prometheus-trends:prometheus-trends pushgateway:pushgateway scrape-proxy:scrape-proxy vector:vector
  blackbox-exporter:blackbox-exporter blackbox-selftest:blackbox-exporter
  docker-state-exporter:docker-state-exporter"

VERIFY_WAIT_S="${OBSERVABILITY_VERIFY_WAIT_S:-300}"
# The least each tokened service's check waits after the shared VERIFY_WAIT_S: one 60 s scrape and
# some (check_tokened).
SCRAPE_GRACE_S="${OBSERVABILITY_SCRAPE_GRACE_S:-75}"
# emporia_held's reading when the collector read its login from OpenBao, Emporia took it and the
# channels are read (an extended regex, matched whole).
EMPORIA_WANT='openbao_failure=0 channel_info=[1-9][0-9]*'

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

# The latest .State.StartedAt of the containers "$@", in epoch seconds; fails when one is missing
# or has never started. Reads only that field.
started_at() {
  local name stamps=""
  for name in "$@"; do
    stamps="$stamps $(docker inspect -f '{{.State.StartedAt}}' "$name" 2>/dev/null)" || return 1
  done
  # shellcheck disable=SC2086 # one word per container
  python3 -c '
import calendar, re, sys, time
out = []
for s in sys.argv[1:]:
    m = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?Z", s)
    t = calendar.timegm(time.strptime(m[1], "%Y-%m-%dT%H:%M:%S")) + float(m[2] or 0) if m else 0
    if t <= 0:
        sys.exit(1)
    out.append(t)
if not out:
    sys.exit(1)
print("%.3f" % max(out))' $stamps
}

# The values of PromQL instant query $2 on 127.0.0.1:$1, sorted, space-separated (empty for none).
prom_values() {
  curl -sf --max-time 10 -G "http://127.0.0.1:$1/api/v1/query" --data-urlencode "query=$2" \
    | python3 -c 'import json,sys; print(" ".join(sorted(r["value"][1] for r in json.load(sys.stdin)["data"]["result"])))'
}

# PromQL: the series of selector $1 whose newest sample was scraped after epoch $2. An instant
# query returns a series' last sample for up to 5 minutes, and a Prometheus that stops writes no
# staleness markers, so until its first scrape after a restart (every 60 s here) it can return a
# sample taken before the restart: no evidence about the containers running now.
fresh() {
  printf '(%s and timestamp(%s) > %s)' "$1" "$1" "$2"
}

# The self-probes as "module=value ..." (sorted), from the operations Prometheus: only samples
# taken after prometheus-1 and blackbox-exporter-1 started.
self_probes() {
  local since
  since="$(started_at prometheus-1 blackbox-exporter-1)" || return 1
  curl -sf --max-time 10 -G http://127.0.0.1:9090/api/v1/query \
      --data-urlencode "query=$(fresh 'probe_success{job="blackbox-selftest",instance=~"http://prometheus:9090/-/healthy|prometheus:9090|prometheus"}' "$since")" \
    | python3 -c 'import json,sys; print(" ".join(sorted(r["metric"].get("module", "?") + "=" + r["value"][1] for r in json.load(sys.stdin)["data"]["result"])))'
}

# Waits for the first scrapes after the restart (the probe job runs every 60 s).
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

# The operations Prometheus's active targets (127.0.0.1:9090/api/v1/targets) in one line: "N
# targets up in M jobs" when each reads health up at a scrape (lastScrape) after S and each job of
# STACK_JOBS has a target; else "not up: ..." naming each other target with Prometheus's error, and
# exit 1. health is that scrape's outcome, which Prometheus also writes as up (1 when up). S: the
# later .State.StartedAt of prometheus-1 and the job's service (STACK_JOBS; prometheus-1 alone for
# a job not listed there). A listed job whose service is not expected here (a replica's, or a
# tokened service never deployed: expected_services) is left out: its target cannot be up.
stack_targets() {
  local entry job svc since base expected
  local -a args=()
  expected=" $(expected_services) " || return 1
  base="$(started_at prometheus-1)" || return 1
  for entry in $STACK_JOBS; do
    job="${entry%%:*}"; svc="${entry#*:}"
    if [[ "$expected" != *" $svc "* ]]; then args+=("$job=-"); continue; fi
    since="$(started_at prometheus-1 "$svc-1")" || return 1
    args+=("$job=$since")
  done
  curl -sf --max-time 10 'http://127.0.0.1:9090/api/v1/targets?state=active' | python3 -c '
import calendar, json, re, sys, time
def epoch(s):
    m = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)", s or "")
    if not m:
        return 0.0
    t = calendar.timegm(time.strptime(m[1], "%Y-%m-%dT%H:%M:%S")) + float(m[2] or 0)
    if m[3] != "Z":
        t -= (1 if m[3][0] == "+" else -1) * (int(m[3][1:3]) * 3600 + int(m[3][4:6]) * 60)
    return t
base, since, skip = float(sys.argv[1]), {}, set()
for a in sys.argv[2:]:
    job, s = a.split("=", 1)
    if s == "-":
        skip.add(job)
    else:
        since[job] = float(s)
targets = [t for t in json.load(sys.stdin)["data"]["activeTargets"] if t["labels"].get("job") not in skip]
jobs = {t["labels"].get("job") for t in targets}
bad = ["%s: no target" % j for j in sorted(set(since) - jobs)]
for t in targets:
    job = t["labels"].get("job")
    fresh = epoch(t.get("lastScrape")) > since.get(job, base)
    if t.get("health") != "up" or not fresh:
        bad.append("%s %s: %s%s%s" % (job, t["labels"].get("instance", "?"), t.get("health"),
                   "" if fresh else ", no scrape since it started",
                   " " + t["lastError"] if t.get("lastError") else ""))
if bad:
    print("not up: " + "; ".join(bad))
    sys.exit(1)
print("%d targets up in %d jobs" % (len(targets), len(jobs)))' "$base" "${args[@]}"
}

# Every target of the operations Prometheus up after the restart (stack_targets). Not the trends
# Prometheus: from d06 its asyla-d03-node, asyla-d07-node and asyla-switch-snmp jobs read 0 by the
# allow lists of those ports (README.md, Known limits). It runs after the self-probes, which waited
# for the first scrapes after prometheus-1 started; every job here is scraped each 15 s
# (base_config.py) but blackbox-selftest (60 s), so it waits SCRAPE_GRACE_S of its own.
check_stack_targets() {
  local deadline got=""
  deadline=$(( $(date +%s) + SCRAPE_GRACE_S ))
  while :; do
    if got="$(stack_targets 2>/dev/null)"; then
      info "prometheus: $got, each scraped after it started"
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 5
  done
  echo "[ERROR] prometheus targets: ${got:-no reading (a start time, or 127.0.0.1:9090/api/v1/targets)}" >&2
  return 1
}

# The trends Prometheus's up{job="$1"} values (space-separated), from its 127.0.0.1:9107: only
# samples taken after container $2 and prometheus-trends-1 started.
trends_up() {
  local since
  since="$(started_at "$2" prometheus-trends-1)" || return 1
  prom_values 9107 "$(fresh "up{job=\"$1\"}" "$since")"
}

# emporia-collector as the trends Prometheus scraped it (job emporia) after emporia-collector-1
# and prometheus-trends-1 started, as "openbao_failure=SUM channel_info=COUNT" ("none" for no such
# sample). It serves /metrics before it reads OpenBao and retries the login forever (theOrg
# emporia-collector/collector.py at f757911), so up{job="emporia"} 1 proves neither. SUM is
# emporia_collector_openbao_failure over its categories: all 0 after an OpenBao read or a renewal
# that worked (the renewal since #325), the failed category 1 after one that did not. COUNT is the
# emporia_channel_info series, set only once Emporia took the login and the collector read the
# channels.
emporia_held() {
  local since failure channels
  since="$(started_at emporia-collector-1 prometheus-trends-1)" || return 1
  failure="$(prom_values 9107 "sum$(fresh 'emporia_collector_openbao_failure{job="emporia"}' "$since")")" || return 1
  channels="$(prom_values 9107 "count$(fresh 'emporia_channel_info{job="emporia"}' "$since")")" || return 1
  echo "openbao_failure=${failure:-none} channel_info=${channels:-none}"
}

# alert-relay's alert_relay_secret_present for its SMTP login, as "secret=value ..." (sorted), from
# its own metrics on 127.0.0.1:9111 (theOrg alert-relay/relay.py; compose.yml publishes it there).
relay_smtp_held() {
  curl -sf --max-time 10 http://127.0.0.1:9111/metrics \
    | python3 -c 'import re,sys; print(" ".join(sorted(m[0] + "=" + format(float(m[1]), "g") for m in re.findall(r"^alert_relay_secret_present\{secret=\"(smtp_username|smtp_password)\"\} (\S+)$", sys.stdin.read(), re.M))))'
}

# Waits until "$@" prints a reading that the extended regex WANT ($1) matches whole, or the shared
# deadline TOKENED_DEADLINE passes; each reading still gets SCRAPE_GRACE_S of its own when an
# earlier one used up the shared wait. The last reading is in GOT.
wait_reading() {
  local want="$1" deadline
  shift
  deadline=$(( $(date +%s) + SCRAPE_GRACE_S ))
  [ "$deadline" -ge "$TOKENED_DEADLINE" ] || deadline="$TOKENED_DEADLINE"
  while :; do
    GOT="$("$@" 2>/dev/null)" || GOT=""
    [[ "$GOT" =~ ^($want)$ ]] && return 0
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 5
  done
}

# That each tokened service whose container exists read its secrets (the two trends ones: and used
# them), not only that it is healthy, from samples taken after it and the trends Prometheus started:
# - scrape-proxy: the trends job it serves (theOrg trends/scrape/asyla-home-assistant.yml) reads
#   up 1. It answers 503 without its vault token and 502 when Home Assistant refuses the token,
#   which Prometheus records as up 0 (theOrg scrape-proxy/proxy.py);
# - emporia-collector: no OpenBao failure and the channel names on (emporia_held);
# - alert-relay: alert_relay_secret_present 1 for its SMTP login (its own metrics, live).
# The first scrape comes within a minute (scrape_interval 60s): one wait of VERIFY_WAIT_S for all,
# and at least SCRAPE_GRACE_S for each.
check_tokened() {
  local rc=0
  TOKENED_DEADLINE=$(( $(date +%s) + VERIFY_WAIT_S ))
  if [ "$(service_state scrape-proxy)" != missing ]; then
    if wait_reading 1 trends_up asyla-home-assistant scrape-proxy-1; then
      info "scrape-proxy: trends up{job=\"asyla-home-assistant\"} 1, scraped after it started (Home Assistant took the token it read)"
    else
      echo "[ERROR] scrape-proxy: trends up{job=\"asyla-home-assistant\"} scraped after it started reads '${GOT:-nothing}', not 1" >&2; rc=1
    fi
  fi
  if [ "$(service_state emporia-collector)" != missing ]; then
    if wait_reading "$EMPORIA_WANT" emporia_held; then
      info "emporia-collector: trends $GOT, scraped after it started (OpenBao read, Emporia login, channels)"
    else
      echo "[ERROR] emporia-collector: trends scraped after it started reads '${GOT:-nothing}', not openbao_failure=0 and channel_info 1 or more" >&2; rc=1
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
# retention, the blackbox self-probes, every operations Prometheus target up, Vector's container
# logs in Loki (not on a replica: no Vector) and the tokened services' secrets (check_tokened). The
# pieces that are off (compose.yml's header) have nothing to check.
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
  check_stack_targets || rc=1
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
  echo "             docker-state-exporter, trends retention, the blackbox self-probes, every" >&2
  echo "             operations Prometheus target up, Vector's container logs in Loki, the" >&2
  echo "             tokened services' secrets" >&2
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
