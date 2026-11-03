#!/bin/bash
# theOrg's observability stack on d06 (Loki and its gateway, Prometheus, the trends Prometheus,
# Alertmanager, alert-relay, Vector, emporia-collector and the probes). Usage: observability.sh
# [switch ...], e.g. up|down|restart|verify|update|logs|status|tls-install|tls-status; switches can be
# combined. Loads ~/scripts/docker/common.env. From theOrg observability DEPLOY.md at main
# 2144f83c3ec978663d3cb544e743ae8006471a0a (README.md here says what asyla changed).
#
# No secret is in any file here or on the host's disk (the operator: "secrets are to live in the
# vault", 2026-11-03). On d06 the workstation resolves the values from OpenBao at deploy and hands
# them to this process's environment (build_host.py start_env, d06/host.toml); `up` writes each
# into its in-memory volume (compose.secret-volumes.yml, held by secrets-holder) through a container's
# stdin, never an argument or a log line. A missing optional value turns its piece off with a WARN;
# a missing Loki check password refuses `up`, and so does a missing pull token when images are
# missing. Data under /mnt/docker/Observability (d06's local data disk; never NFS).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SECRET_VOLUMES_FILE="$SCRIPT_DIR/compose.secret-volumes.yml"
VENDOR="$SCRIPT_DIR/vendor"
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
# Images). 2144f83 is theOrg main (#298). Change it here (and re-vendor vendor/ at the same sha),
# commit, then `update restart verify`.
OBSERVABILITY_TAG="${OBSERVABILITY_TAG_OVERRIDE:-2144f83c3ec978663d3cb544e743ae8006471a0a}"
REGISTRY="gitea.asyla.org"
GATEWAY_IMAGE="$REGISTRY/theorg/observability-loki-gateway:$OBSERVABILITY_TAG"

# The host this folder belongs to. On any other host (test01 as a replica of d06) the stack runs
# compose.yml alone with the core services only: no values, no pings, no email, no Vector (its
# chronicle episodes would reach production's memory-system), no gateway (no accounts to render).
SERVING_HOST="d06"
REPLICA_SERVICES="loki prometheus prometheus-trends alertmanager pushgateway docker-state-exporter blackbox-exporter"
# d06's services, without emporia-collector (only with its login) and the two below.
CORE_SERVICES="loki loki-gateway prometheus prometheus-trends pushgateway vector docker-state-exporter blackbox-exporter"
# They read their secret files and pieces at start, so `up` recreates them every time.
RENDERED_SERVICES="alertmanager alert-relay"

# asyla's settings (asyla hub, the observability-on-d06 item).
PROMETHEUS_EXTERNAL_URL="${PROMETHEUS_EXTERNAL_URL:-https://prometheus.asyla.org}"
ALERTMANAGER_EXTERNAL_URL="${ALERTMANAGER_EXTERNAL_URL:-https://alertmanager.asyla.org}"
GITEA_URL="https://gitea.asyla.org"
GITEA_ALERT_REPO="asyla/alerts"
ALERT_REPOS=""
# Always https: the leaf (tls-install) names host.docker.internal; without one the relay's log
# queries fail until it is installed, and no restart of the relay is needed after.
ALERT_RELAY_LOKI_URL="https://host.docker.internal:3100"
# memory-system's Vector on the Mini (theOrg lead, 2026-11-03).
CHRONICLE_VECTOR_ADDRESS="10.0.0.150:6000"
COMPOSE_PROJECT_NAME="observability"

# Loki's TLS: the leaf, key and root in memory (held), the root alone persistent.
TLS_VOLUME="observability-loki-tls"
CA_VOLUME="observability-loki-ca"
AUTH_VOLUME="observability_loki-gateway-auth"
TLS_NAMES="loki host.docker.internal d06 d06.asyla.org 10.0.0.65"
TLS_MIN_DAYS=30

VERIFY_WAIT_S="${OBSERVABILITY_VERIFY_WAIT_S:-300}"

is_replica() {
  [ "$(hostname -s)" != "$SERVING_HOST" ]
}

if is_replica; then ALERT_EMAIL_TO=""; else ALERT_EMAIL_TO="shepner@asyla.org"; fi

export DOCKER_DL OBSERVABILITY_ROOT OBSERVABILITY_TAG PROMETHEUS_EXTERNAL_URL ALERTMANAGER_EXTERNAL_URL \
  GITEA_URL GITEA_ALERT_REPO ALERT_REPOS ALERT_RELAY_LOKI_URL CHRONICLE_VECTOR_ADDRESS \
  COMPOSE_PROJECT_NAME ALERT_EMAIL_TO

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

run_compose() {
  if is_replica; then
    docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
  else
    docker compose -f "$COMPOSE_FILE" -f "$SECRET_VOLUMES_FILE" --project-directory "$SCRIPT_DIR" "$@"
  fi
}

# Temporary state, removed on exit: the pull's throwaway DOCKER_CONFIG, and WORK (0700, in
# memory under /dev/shm) with the Loki passwords and the registry of the accounts that have one.
PULL_CONFIG=""
WORK=""
cleanup() {
  if [ -n "$PULL_CONFIG" ]; then rm -rf "$PULL_CONFIG"; fi
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
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

# --- volumes and files ----------------------------------------------------------------------------

volume_exists() {
  docker volume inspect "$1" >/dev/null 2>&1
}

# in_volume VOLUME ro|rw SCRIPT [ARG...]: sh -c SCRIPT in a throwaway container of the gateway image
# (already pulled; no network) with VOLUME at /v; ARGs are $1... and stdin passes through.
in_volume() {
  local vol="$1" mode="$2" script="$3"
  shift 3
  docker run --rm -i --network none --pull never --cpus 0.5 --memory 64m \
    -v "$vol:/v:$mode" --entrypoint sh "$GATEWAY_IMAGE" -c "$script" sh "$@"
}

# put_file VOLUME FILE: stdin into VOLUME/FILE, uid 65534, mode 0600, renamed into place; no
# trailing newline is added (the value arrives with printf %s), as theOrg's deploy writes them.
put_file() {
  in_volume "$1" rw 'umask 077; cat > "/v/$1.new" && chown 65534:65534 "/v/$1.new" && mv "/v/$1.new" "/v/$1"' "$2"
}

drop_file() {
  in_volume "$1" rw 'rm -f "/v/$1"' "$2" < /dev/null
}

# held VOLUME/FILE: true when secrets-holder holds a non-empty FILE (the consumers mount the same
# in-memory volume). Nothing is read out. As uid 65534, the owner: the holder has no capabilities,
# so its root could not enter a 0700 directory of 65534's.
held() {
  docker exec -u 65534:65534 secrets-holder-1 sh -c 'test -s "$1"' sh "/hold/$1" 2>/dev/null
}

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

# put_values PIECE VOLUME FILE:NAME...: each NAME's value from this process's environment into
# VOLUME/FILE, all or none. Returns 1 (the piece is off, its files removed) when any is absent.
put_values() {
  local piece="$1" vol="observability_$2" pair name missing=()
  shift 2
  for pair in "$@"; do
    name="${pair#*:}"
    [ -n "${!name:-}" ] || missing+=("$name")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    for pair in "$@"; do drop_file "$vol" "${pair%%:*}" || die "$piece: cannot clear $vol"; done
    warn "$piece off: ${missing[*]} not in this process's environment (add to d06/host.toml start_env once stored)"
    return 1
  fi
  for pair in "$@"; do
    name="${pair#*:}"
    printf %s "${!name}" | put_file "$vol" "${pair%%:*}" || die "$piece: writing ${pair%%:*} into $vol failed"
  done
  info "$piece: written into $vol"
}

# put_ping watchdog|delivery NAME: the healthchecks.io ping URL through theOrg's write_ping_url.sh
# (URL on stdin; --remove switches the ping off).
put_ping() {
  local kind="$1" name="$2"
  if [ -n "${!name:-}" ]; then
    printf '%s\n' "${!name}" | "$VENDOR/write_ping_url.sh" "$kind" || die "$kind ping: write_ping_url.sh failed"
  else
    "$VENDOR/write_ping_url.sh" "$kind" --remove < /dev/null || die "$kind ping: write_ping_url.sh --remove failed"
    warn "$kind ping off: $name not in this process's environment (add to d06/host.toml start_env once stored)"
  fi
}

EMPORIA_ON=false
write_secrets() {
  put_values "trends Home Assistant job" prometheus-trends-tokens \
    "asyla-home-assistant:HOME_ASSISTANT_PROMETHEUS_TOKEN" || true
  if put_values "emporia-collector" emporia-login "username:EMPORIA_USERNAME" "password:EMPORIA_PASSWORD"; then
    EMPORIA_ON=true
  fi
  put_values "email for critical alerts" alertmanager-smtp \
    "username:SMTP_RELAY_USERNAME" "password:SMTP_RELAY_PASSWORD" || true
  put_ping watchdog OBSERVABILITY_WATCHDOG_PING_URL
  put_ping delivery OBSERVABILITY_DELIVERY_PING_URL
  if [ -z "${OBSERVABILITY_ALERT_RELAY_GITEA_TOKEN:-}" ]; then
    warn "alert-relay files no issue: OBSERVABILITY_ALERT_RELAY_GITEA_TOKEN not in this process's environment (add to d06/host.toml start_env once stored)"
  fi
}

# --- Loki accounts (vendor/loki_clients.py, DEPLOY.md "Deploying without theOrg's OpenBao") --------

# WORK/passwords: one 0600 file per account whose LOKI_CLIENT_<NAME> is set (no trailing newline);
# WORK/loki-clients.toml: loki-clients.toml with only those accounts, so an absent one is refused
# at the gateway rather than failing the render. Values are read from the environment by python,
# never passed as arguments.
loki_work() {
  [ -z "$WORK" ] || return 0
  WORK="$(mktemp -d /dev/shm/observability.XXXXXX)" || die "cannot create a work directory under /dev/shm"
  chmod 700 "$WORK" && mkdir -m 700 "$WORK/passwords" || die "cannot prepare $WORK"
  python3 -I - "$SCRIPT_DIR/loki-clients.toml" "$WORK" <<'PY' || die "cannot write the Loki accounts into $WORK"
import json, os, sys, tomllib
registry, work = sys.argv[1], sys.argv[2]
with open(registry, "rb") as f:
    clients = tomllib.load(f).get("clients") or {}
out = []
for name, spec in clients.items():
    var = "LOKI_CLIENT_" + name.upper().replace("-", "_")
    value = os.environ.get(var, "")
    if not value:
        print(f"[WARN] Loki account {name}: {var} is not in this process's environment; "
              "the gateway refuses it", file=sys.stderr)
        continue
    fd = os.open(os.path.join(work, "passwords", name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(fd, value.encode())
    os.close(fd)
    out.append(f"[clients.{name}]")
    out += [f"{k} = {json.dumps(v)}" for k, v in spec.items()]
    out.append("")
with open(os.path.join(work, "loki-clients.toml"), "w") as f:
    f.write("\n".join(out))
PY
}

loki_clients() {
  local cmd="$1"
  shift
  python3 "$VENDOR/loki_clients.py" "$cmd" --registry "$WORK/loki-clients.toml" \
    --passwords-dir "$WORK/passwords" "$@"
}

# up's check: the two accounts loki_clients.py verify signs in as.
require_values() {
  is_replica && return 0
  if [ -z "${LOKI_CLIENT_OBSERVABILITY_CHECK_PUSH:-}" ] || [ -z "${LOKI_CLIENT_OBSERVABILITY_CHECK_QUERY:-}" ]; then
    die "LOKI_CLIENT_OBSERVABILITY_CHECK_PUSH and LOKI_CLIENT_OBSERVABILITY_CHECK_QUERY come from OpenBao at deploy, in this process's environment (build_host.py start_env); not starting"
  fi
}

# --- TLS ------------------------------------------------------------------------------------------

# Loki serves HTTPS only with both cert.pem and key.pem (loki-entrypoint.sh).
leaf_present() {
  volume_exists "$TLS_VOLUME" || return 1
  in_volume "$TLS_VOLUME" ro 'test -s /v/cert.pem && test -s /v/key.pem' < /dev/null 2>/dev/null
}

ca_digest() {
  if volume_exists "$CA_VOLUME"; then
    in_volume "$CA_VOLUME" ro 'if [ -s /v/root_ca.crt ]; then sha256sum < /v/root_ca.crt; else echo none; fi' < /dev/null
  else
    echo none
  fi
}

# Runs in the gateway image (busybox tar, openssl) with the TLS volume at /tls and the CA volume at
# /ca; the tar arrives on stdin. Checks before it replaces anything: exactly the three names, each a
# non-empty regular file, the leaf chains to root_ca.crt, the key is the leaf's. Owners root; key 0600.
TLS_INSTALL_SH="$(cat <<'SH'
set -eu
umask 077
cat > /tmp/in.tar
names="$(tar -tf /tmp/in.tar | sed 's#^\./##; /^$/d' | sort | tr '\n' ' ')"
if [ "$names" != "cert.pem key.pem root_ca.crt " ]; then
  echo "tls-install: the tar must hold exactly cert.pem, key.pem and root_ca.crt (it holds: $names)" >&2
  exit 1
fi
s=/tls/.stage
rm -rf "$s"
mkdir "$s"
trap 'rm -rf "$s"' EXIT
tar -xf /tmp/in.tar -C "$s"
for f in cert.pem key.pem root_ca.crt; do
  if [ -L "$s/$f" ] || [ ! -f "$s/$f" ] || [ ! -s "$s/$f" ]; then
    echo "tls-install: $f is not a non-empty regular file; nothing replaced" >&2
    exit 1
  fi
done
if ! openssl verify -CAfile "$s/root_ca.crt" -untrusted "$s/cert.pem" "$s/cert.pem" >/dev/null 2>&1; then
  echo "tls-install: cert.pem does not chain to root_ca.crt; nothing replaced" >&2
  exit 1
fi
if [ "$(openssl x509 -in "$s/cert.pem" -noout -pubkey | openssl sha256)" != "$(openssl pkey -in "$s/key.pem" -pubout | openssl sha256)" ]; then
  echo "tls-install: key.pem is not cert.pem's key; nothing replaced" >&2
  exit 1
fi
chown 0:0 "$s/cert.pem" "$s/key.pem" "$s/root_ca.crt"
chmod 0644 "$s/cert.pem" "$s/root_ca.crt"
chmod 0600 "$s/key.pem"
cp "$s/root_ca.crt" /ca/root_ca.crt.new
chmod 0644 /ca/root_ca.crt.new
mv /ca/root_ca.crt.new /ca/root_ca.crt
mv "$s/root_ca.crt" /tls/root_ca.crt
mv "$s/key.pem" /tls/key.pem
mv "$s/cert.pem" /tls/cert.pem
echo "tls-install: cert.pem, key.pem and root_ca.crt installed; root_ca.crt in the CA volume"
SH
)"

container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

# tls-install: an uncompressed POSIX tar on stdin with exactly cert.pem, key.pem and root_ca.crt
# (the hub's tools/loki_tls.py issue d06 sends it). Into the held TLS volume, the root also into
# the CA volume; then Loki and the gateway restart (each picks HTTP or HTTPS only at start), and
# Vector too when the root changed (vector-entrypoint.sh picks its scheme from the CA at start).
do_tls_install() {
  local before after
  is_replica && die "tls-install installs a key; never on a replica"
  [ ! -t 0 ] || die "tls-install reads a tar of cert.pem, key.pem and root_ca.crt on stdin"
  docker image inspect "$GATEWAY_IMAGE" >/dev/null 2>&1 || die "$GATEWAY_IMAGE is not here; run up first"
  run_compose up -d --no-recreate secrets-holder || return
  before="$(ca_digest)"
  docker run --rm -i --network none --pull never --cpus 0.5 --memory 64m \
    -v "$TLS_VOLUME:/tls" -v "$CA_VOLUME:/ca" --entrypoint sh "$GATEWAY_IMAGE" -c "$TLS_INSTALL_SH" \
    || die "tls-install refused or failed; the TLS volume is unchanged unless it said installed"
  after="$(ca_digest)"
  if container_exists loki-1; then
    run_compose restart loki || return
    run_compose restart loki-gateway || return
  else
    info "The stack is not running: Loki and the gateway start on HTTPS at the next up"
  fi
  if [ "$before" != "$after" ] && container_exists vector-1; then
    info "The root changed: restarting vector so it switches to HTTPS"
    run_compose restart vector || return
  fi
}

# tls-status: the leaf, cert.pem from the TLS volume, as PEM on stdout, or the word `absent`;
# nothing else on stdout, exit 0 either way (the hub's tools/loki_tls.py checks it with its own
# openssl). A cert.pem without key.pem is absent: Loki serves HTTP then.
do_tls_status() {
  local pem=""
  if volume_exists "$TLS_VOLUME" && docker image inspect "$GATEWAY_IMAGE" >/dev/null 2>&1; then
    pem="$(in_volume "$TLS_VOLUME" ro \
      'if [ -s /v/key.pem ]; then cat /v/cert.pem; elif [ -s /v/cert.pem ]; then echo "tls-status: cert.pem without key.pem" >&2; fi' \
      < /dev/null)" || pem=""
  fi
  if [[ "$pem" == *"-----BEGIN CERTIFICATE-----"* ]]; then
    printf '%s\n' "$pem"
  else
    echo absent
  fi
  return 0
}

# verify's TLS line: at least TLS_MIN_DAYS left and every name in TLS_NAMES on the leaf.
check_tls() {
  local out end end_s days sans n bad=0
  if ! leaf_present; then
    warn "TLS is not installed: Loki and the gateway serve HTTP (install with the hub's tools/loki_tls.py issue d06)"
    return 0
  fi
  out="$(in_volume "$TLS_VOLUME" ro 'openssl x509 -in /v/cert.pem -noout -enddate -issuer -ext subjectAltName' < /dev/null)" \
    || { echo "[ERROR] TLS: cannot read cert.pem" >&2; return 1; }
  end="$(sed -n 's/^notAfter=//p' <<< "$out")"
  end_s="$(date -d "$end" +%s 2>/dev/null)" || { echo "[ERROR] TLS: cannot read notAfter ($end)" >&2; return 1; }
  days=$(( (end_s - $(date +%s)) / 86400 ))
  sans="$(sed -n '/Subject Alternative Name/{n;p;}' <<< "$out" | sed 's/^[[:space:]]*//')"
  if [ "$days" -lt "$TLS_MIN_DAYS" ]; then
    echo "[ERROR] TLS: the leaf expires in $days days ($end), under $TLS_MIN_DAYS" >&2
    bad=1
  fi
  for n in $TLS_NAMES; do
    case ", $sans," in
      *", DNS:$n,"*|*", IP Address:$n,"*) ;;
      *) echo "[ERROR] TLS: $n is not on the leaf (SANs: $sans)" >&2; bad=1 ;;
    esac
  done
  if [ "$bad" -eq 0 ]; then
    info "TLS: $days days left ($end); SANs $sans; $(grep '^issuer=' <<< "$out")"
  fi
  return "$bad"
}

# --- up, restart ----------------------------------------------------------------------------------

do_up() {
  local svcs="$CORE_SERVICES"
  ensure_dirs || return
  pull_missing || return
  own_dirs || die "cannot set the data directories' owners under $OBSERVABILITY_ROOT"
  if is_replica; then
    info "Replica of $SERVING_HOST ($(hostname -s)): $REPLICA_SERVICES; no values, no pings, no email"
    # shellcheck disable=SC2086
    run_compose up -d --wait --wait-timeout "$VERIFY_WAIT_S" $REPLICA_SERVICES
    return
  fi
  # 1. The holder first, never recreated: it keeps the in-memory volumes (and the leaf) mounted.
  run_compose up -d --no-recreate secrets-holder || return
  # 2. The values into their volumes; a missing optional one turns its piece off.
  write_secrets
  # 3. The gateway's accounts, before it starts (DEPLOY.md, Loki gateway).
  loki_work
  loki_clients render --volume "$AUTH_VOLUME" --image "$GATEWAY_IMAGE" || die "loki_clients.py render failed"
  # 4. The stack. alert-relay's two values go to its container's environment, as theOrg's deploy.
  ALERT_RELAY_GITEA_TOKEN="${OBSERVABILITY_ALERT_RELAY_GITEA_TOKEN:-}"
  ALERT_RELAY_LOKI_PASSWORD="${LOKI_CLIENT_ALERT_RELAY:-}"
  export ALERT_RELAY_GITEA_TOKEN ALERT_RELAY_LOKI_PASSWORD
  if $EMPORIA_ON; then
    svcs="$svcs emporia-collector"
  else
    run_compose rm -s -f emporia-collector || return
  fi
  # shellcheck disable=SC2086
  run_compose up -d --wait --wait-timeout "$VERIFY_WAIT_S" $svcs || return
  # shellcheck disable=SC2086
  run_compose up -d --no-deps --force-recreate --wait --wait-timeout "$VERIFY_WAIT_S" $RENDERED_SERVICES || return
  # 5. The gateway admits exactly the accounts (DEPLOY.md, Loki gateway: verify).
  if leaf_present; then
    loki_clients verify --url https://host.docker.internal:3100 --ca-volume "$CA_VOLUME" || die "loki_clients.py verify failed"
  else
    warn "TLS is not installed: the gateway serves HTTP; loki_clients.py verify over HTTP (install with the hub's tools/loki_tls.py issue d06)"
    loki_clients verify --url http://host.docker.internal:3100 --ca-volume '' || die "loki_clients.py verify failed"
  fi
}

# Every service but secrets-holder, stopped and removed (restart keeps the held values).
stop_services() {
  local svcs
  svcs="$(run_compose config --services | grep -vx secrets-holder)" || return
  # shellcheck disable=SC2086
  run_compose rm -s -f $svcs
}

# --- verify, status -------------------------------------------------------------------------------

expected_services() {
  if is_replica; then
    echo "$REPLICA_SERVICES"
  else
    local svcs="secrets-holder $CORE_SERVICES $RENDERED_SERVICES"
    if held emporia-login/password; then svcs="$svcs emporia-collector"; fi
    echo "$svcs"
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

# The words after "pieces on:" in Alertmanager's newest start line (alertmanager-entrypoint.sh).
alertmanager_pieces() {
  docker logs alertmanager-1 2>&1 | grep 'pieces on:' | tail -n 1 | sed 's/.*pieces on:\([^;]*\);.*/\1/'
}

# check_piece LABEL EXPECTED(true|false) ON(true|false)
check_piece() {
  if [ "$2" = "$3" ]; then
    info "$1: $([ "$3" = true ] && echo on || echo off), as its file says"
    return 0
  fi
  echo "[ERROR] $1 is $([ "$3" = true ] && echo on || echo off) but its file is $([ "$2" = true ] && echo there || echo absent)" >&2
  return 1
}

# DEPLOY.md, "Check the stack after a live restore", and the pieces checks theOrg's deploy runs.
do_verify() {
  local rc=0 svc state n pieces relay want on body
  wait_ready || true
  for svc in $(expected_services); do
    state="$(service_state "$svc")"
    case "$state" in
      "running healthy"|"running none") ;;
      *) echo "[ERROR] $svc: $state" >&2; rc=1 ;;
    esac
  done
  if [ "$rc" -eq 0 ]; then info "services running and healthy: $(expected_services)"; fi
  if ! is_replica && ! held emporia-login/password; then
    warn "emporia-collector is off (no Emporia login held)"
  fi

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

  if is_replica; then
    info "Replica: no gateway, pieces, TLS or Loki accounts to check"
    if [ "$rc" -eq 0 ]; then info "verify OK (replica)"; else echo "[ERROR] verify failed (replica)" >&2; fi
    return "$rc"
  fi

  if leaf_present; then
    if docker run --rm --cpus 0.5 --memory 64m --add-host host.docker.internal:host-gateway \
        -v "$CA_VOLUME:/loki-ca:ro" curlimages/curl -sf -o /dev/null --max-time 10 \
        --cacert /loki-ca/root_ca.crt https://host.docker.internal:3100/ready; then
      info "loki-gateway /ready over HTTPS, the leaf verified with $CA_VOLUME"
    else
      echo "[ERROR] loki-gateway https://host.docker.internal:3100/ready failed (leaf verified with $CA_VOLUME)" >&2; rc=1
    fi
  elif curl -sf -o /dev/null --max-time 10 http://127.0.0.1:3100/ready; then
    info "loki-gateway /ready over HTTP"
  else
    echo "[ERROR] loki-gateway http://127.0.0.1:3100/ready failed" >&2; rc=1
  fi
  check_tls || rc=1

  pieces=" $(alertmanager_pieces) "
  want=false; held alertmanager-smtp/password && want=true
  on=false; [[ "$pieces" == *" email "* ]] && on=true
  check_piece "alertmanager email piece" "$want" "$on" || rc=1
  want=false; held alertmanager-healthchecks/watchdog-url && want=true
  on=false; [[ "$pieces" == *" watchdog "* ]] && on=true
  check_piece "alertmanager watchdog piece" "$want" "$on" || rc=1
  relay="$(docker logs alert-relay-1 2>&1 | grep 'alert-relay delivery ping:' | tail -n 1)"
  want=false; held alert-relay-healthchecks/delivery-url && want=true
  on=false; [[ "$relay" == *"delivery ping: on"* ]] && on=true
  check_piece "alert-relay delivery ping" "$want" "$on" || rc=1

  if [ -n "${LOKI_CLIENT_OBSERVABILITY_CHECK_PUSH:-}" ] && [ -n "${LOKI_CLIENT_OBSERVABILITY_CHECK_QUERY:-}" ]; then
    loki_work
    if leaf_present; then
      loki_clients verify --url https://host.docker.internal:3100 --ca-volume "$CA_VOLUME" || rc=1
    else
      loki_clients verify --url http://host.docker.internal:3100 --ca-volume '' || rc=1
    fi
  else
    info "Loki accounts not checked here (the two check passwords are not in this process's environment); up checks them"
  fi
  if [ "$rc" -eq 0 ]; then info "verify OK"; else echo "[ERROR] verify failed" >&2; fi
  return "$rc"
}

do_status() {
  local f
  run_compose ps -a --format 'table {{.Name}}\t{{.Status}}'
  is_replica && return 0
  for f in prometheus-trends-tokens/asyla-home-assistant emporia-login/password alertmanager-smtp/password \
      alertmanager-healthchecks/watchdog-url alert-relay-healthchecks/delivery-url; do
    if held "$f"; then echo "held: $f"; else echo "absent: $f"; fi
  done
  if leaf_present; then echo "TLS: installed"; else echo "TLS: absent (Loki on HTTP)"; fi
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
      require_values
      do_up
      ;;
    down)
      run_compose down
      ;;
    restart)
      require_values
      stop_services
      do_up
      ;;
    verify)
      do_verify
      ;;
    status)
      do_status
      ;;
    tls-install)
      do_tls_install
      ;;
    tls-status)
      do_tls_status
      ;;
    *)
      return 1
      ;;
  esac
}

usage() {
  echo "Usage: $0 [switch ...]" >&2
  echo "  Switches can be combined, e.g. update restart verify" >&2
  echo "" >&2
  echo "  update      - Pull the images for OBSERVABILITY_TAG (screen if interactive); use up/restart to start" >&2
  echo "  pull        - Pull the images now (inline)" >&2
  echo "  images      - Pull missing images, then list the images (build_host.py's replica guard)" >&2
  echo "  up          - Start: secrets-holder (never recreated), the values into its in-memory volumes," >&2
  echo "                the gateway's accounts, the stack, then loki_clients.py verify. On d06 refused" >&2
  echo "                unless LOKI_CLIENT_OBSERVABILITY_CHECK_PUSH and _QUERY are in the environment" >&2
  echo "                (from OpenBao at deploy). Replica: $REPLICA_SERVICES only" >&2
  echo "  down        - Stop and remove every container, secrets-holder too: the in-memory values and" >&2
  echo "                the Loki leaf are gone until the next deploy and tls-install" >&2
  echo "  restart     - Every service but secrets-holder removed, then up (the held values stay)" >&2
  echo "  verify      - Services running and healthy, Prometheus and its Alertmanager, the gateway," >&2
  echo "                docker-state-exporter, trends retention; on d06 also TLS (>= $TLS_MIN_DAYS days, SANs)," >&2
  echo "                the pieces against their files, and the Loki accounts when their passwords are given" >&2
  echo "  status      - Containers, which secret files are held (names only), TLS present or not" >&2
  echo "  tls-install - A tar of cert.pem, key.pem and root_ca.crt on stdin into the TLS volume" >&2
  echo "                (root also into $CA_VOLUME); restarts loki and loki-gateway (d06 only)" >&2
  echo "  tls-status  - The leaf (cert.pem) as PEM on stdout, or 'absent'" >&2
  echo "  logs        - Follow logs (optionally for one service)" >&2
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
