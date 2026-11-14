#!/bin/bash
# theOrg's identity-platform on d05 (Keycloak, keycloak-db, openldap). Usage:
# identity-platform.sh [switch ...], e.g. up|pull|images|verify|down|logs. Switches can be combined.
# From theOrg identity-platform DEPLOY.md "Production on d05" and deploy/d05/compose.example.yml at
# 701e893 (main, the #82 merge). This is M1 (agreed with theOrg): networks, images, theOrg's root
# CA, a report on the openldap leaf, and keycloak-db alone. openldap and keycloak are never started
# here: their first start is the M5 cutover (DEPLOY.md steps 5-6), after a restore, and theOrg's
# restores refuse a target that is not empty (keycloak_backup.sh counts tables; openldap_backup.sh
# checks the volumes). A first openldap start runs osixia's bootstrap, so M1 never creates
# openldap-data or openldap-config. start-openldap, start-keycloak and restore refuse until M5 is
# written.
# No secret is in any file here or on the host. The workstation resolves the values from OpenBao
# at deploy (build_host.py start_env, pull_token_env) and hands them to this process's environment;
# this script maps them onto the names compose.yml passes by name:
#   IDP_KEYCLOAK_DB_PASSWORD       -> KC_DB_PASSWORD, POSTGRES_PASSWORD, PGPASSWORD (up needs it)
#   IDP_LDAP_ADMIN_PASSWORD        -> LDAP_ADMIN_PASSWORD, LDAP_CONFIG_PASSWORD (M5; not sent in M1)
#   IDP_DEPLOY_DEX_CLIENT_SECRET   -> VAULT_DEX_CLIENT_SECRET, keycloak-configure (M5; not sent in M1)
# docker compose hands a name only to the services that list it, and M1 starts keycloak-db alone,
# so in M1 only POSTGRES_PASSWORD reaches a container.
# On any host but d05 (test01 as a replica of d05) up runs in replica mode: build_host.py sends a
# replica no start_env, so keycloak-db gets a throwaway password made at run time (never d05's,
# never written to a file by this script); the rest of up is as on d05, and openldap and keycloak
# still never start.
# Data under /mnt/docker/IdentityPlatform. No backup here yet: the data is the Mini's until M5.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi

DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
APP_ROOT="$DOCKER_DL/IdentityPlatform"
IDENTITY_PLATFORM_ROOT="$APP_ROOT"
# theOrg's four images are pinned to the commit this folder is written from; the two upstream
# images (keycloak, postgres) are pinned by digest in compose.yml. A pin by hand:
# IDENTITY_PLATFORM_TAG_OVERRIDE=<a theOrg main sha whose images are published>.
IDENTITY_PLATFORM_TAG="${IDENTITY_PLATFORM_TAG_OVERRIDE:-701e89316d99a4f28637def5993f2c66bdbbae53}"
REGISTRY="gitea.asyla.org"
export IDENTITY_PLATFORM_ROOT IDENTITY_PLATFORM_TAG

# theOrg's root, "theOrg-v2 Root CA" (expires 2036-08-29), copied from internal-access
# hosts/d03/upstream-ca/theorg-v2-root.pem (byte-identical to step-ca's /roots.pem, read
# 2026-11-14). Its SHA-256 is keycloak-configure's KEYCLOAK_CA_FINGERPRINT (compose.yml).
CA_SOURCE="$SCRIPT_DIR/theorg-v2-root.crt"
CA_FINGERPRINT="CD:39:1A:56:AE:00:0B:01:A4:43:3A:73:F2:2D:98:A3:73:E5:BB:08:E8:D7:75:31:DF:2D:B8:6A:4F:29:87:D3"
CA_FILE="$APP_ROOT/ca/root_ca.crt"
LEAF_DIR="$APP_ROOT/openldap-tls"

# DEPLOY.md "Production on d05: networks". Both external in compose.yml; created here.
NET_NAME="identity-platform-net"
NET_SUBNET="10.213.5.64/26"
EDGE_NAME="identity-platform-edge"
EDGE_SUBNET="10.213.5.0/29"
EDGE_GATEWAY="10.213.5.1"
EDGE_IP_RANGE="10.213.5.4/30"
# identity-platform-net's gateway: the subnet's first address, Docker's own default, named so that
# the check below is exact (asyla's choice; theOrg's example names the subnet only).
NET_GATEWAY="10.213.5.65"
# net_state's line for each, compared whole: another driver, an extra IPAM entry (an IPv6 one
# included), another gateway or an ip-range is refused.
NET_WANT="bridge false $NET_SUBNET $NET_GATEWAY -"
EDGE_WANT="bridge true $EDGE_SUBNET $EDGE_GATEWAY $EDGE_IP_RANGE"

# The host this folder belongs to; on any other host (test01 as a replica of d05) up runs in
# replica mode (the header).
SERVING_HOST="d05"

DB_WAIT_S="${IDENTITY_PLATFORM_DB_WAIT_S:-120}"

# --profile cutover and ops name every service, for the image list and the pulls only; a start
# never takes either profile.
ALL_PROFILES=(--profile ops --profile cutover)

is_replica() {
  [ "$(hostname -s)" != "$SERVING_HOST" ]
}

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

# Presence only; never prints a value.
require_db_secret() {
  if [ -z "${IDP_KEYCLOAK_DB_PASSWORD:-}" ]; then
    echo "[ERROR] IDP_KEYCLOAK_DB_PASSWORD is not in this process's environment; it comes from OpenBao at deploy (build_host.py start_env); not starting" >&2
    exit 1
  fi
}

# Replica mode: keycloak-db's password is a throwaway made here, in this process only. d05's value
# and M5's are never used on a replica, even when set. Never printed. A replica's keycloak-db keeps
# whichever throwaway its first start had (postgres reads POSTGRES_PASSWORD only on an empty data
# dir); nothing on a replica connects with it, and the healthcheck (pg_isready) needs none.
replica_db_secret() {
  local v
  v="$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')" || v=""
  if [ "${#v}" -ne 48 ]; then
    echo "[ERROR] could not make a throwaway keycloak-db password from /dev/urandom; not starting" >&2
    exit 1
  fi
  IDP_KEYCLOAK_DB_PASSWORD="$v"
  unset IDP_LDAP_ADMIN_PASSWORD IDP_DEPLOY_DEX_CLIENT_SECRET
  echo "[INFO] Replica of $SERVING_HOST ($(hostname -s)): keycloak-db with a throwaway password; openldap and keycloak never start"
}

map_secrets() {
  if [ -n "${IDP_KEYCLOAK_DB_PASSWORD:-}" ]; then
    KC_DB_PASSWORD="$IDP_KEYCLOAK_DB_PASSWORD"
    POSTGRES_PASSWORD="$IDP_KEYCLOAK_DB_PASSWORD"
    PGPASSWORD="$IDP_KEYCLOAK_DB_PASSWORD"
    export KC_DB_PASSWORD POSTGRES_PASSWORD PGPASSWORD
  fi
  if [ -n "${IDP_LDAP_ADMIN_PASSWORD:-}" ]; then
    LDAP_ADMIN_PASSWORD="$IDP_LDAP_ADMIN_PASSWORD"
    LDAP_CONFIG_PASSWORD="$IDP_LDAP_ADMIN_PASSWORD"
    export LDAP_ADMIN_PASSWORD LDAP_CONFIG_PASSWORD
  fi
  if [ -n "${IDP_DEPLOY_DEX_CLIENT_SECRET:-}" ]; then
    VAULT_DEX_CLIENT_SECRET="$IDP_DEPLOY_DEX_CLIENT_SECRET"
    export VAULT_DEX_CLIENT_SECRET
  fi
}

# Pulls never log in and never write a credential: they run under a throwaway DOCKER_CONFIG whose
# config.json names only the credential helper beside this script
# (docker-credential-identity-platform-env), which hands Docker IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN
# from this process's environment (build_host.py pull_token_env). quay.io and Docker Hub pull
# anonymously. As d06's ticketing.sh (the compose plugin is still found in the system directory).
PULL_CONFIG=""
remove_pull_config() { if [ -n "$PULL_CONFIG" ]; then rm -rf "$PULL_CONFIG"; fi; }
trap remove_pull_config EXIT

pull_compose() {
  if [ -z "${IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN:-}" ]; then
    echo "[ERROR] IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN is not in this process's environment; the pull token comes from the workstation (build_host.py pull_token_env)" >&2
    return 1
  fi
  if [ -z "$PULL_CONFIG" ]; then
    PULL_CONFIG="$(mktemp -d)" || return
    printf '{"credHelpers":{"%s":"identity-platform-env"}}\n' "$REGISTRY" > "$PULL_CONFIG/config.json" || return
  fi
  ( export DOCKER_CONFIG="$PULL_CONFIG" PATH="$SCRIPT_DIR:$PATH"; run_compose "$@" )
}

# All six images: theOrg's four and the two upstream ones.
do_pull() {
  pull_compose "${ALL_PROFILES[@]}" pull
}

# build_host.py's replica guard (replica_images): pull what is missing (with the workstation's pull
# token), then print the images of the default services (keycloak-db's alone: openldap and keycloak
# are in cutover, the one-shots in ops), one per line, on stdout only; each is probed for egress.
# As d06's ticketing.sh images.
do_images() {
  pull_missing >&2 || return
  run_compose config --images
}

# Pulls only when an image is missing; every image is pinned, so missing is the only reason.
pull_missing() {
  local img imgs missing=false
  # Not a process substitution: its failure would read as "nothing missing" and skip the pull.
  imgs="$(run_compose "${ALL_PROFILES[@]}" config --images)" \
    || { echo "[ERROR] docker compose config failed; not pulling" >&2; return 1; }
  while read -r img; do
    [ -n "$img" ] || continue
    docker image inspect "$img" >/dev/null 2>&1 || missing=true
  done <<< "$imgs"
  $missing || return 0
  do_pull
}

# "DRIVER INTERNAL" then " SUBNET GATEWAY IPRANGE" for each IPAM entry ("-" for an empty gateway or
# ip-range), or nothing when the network does not exist.
net_state() {
  docker network inspect -f '{{.Driver}} {{.Internal}}{{range .IPAM.Config}} {{.Subnet}} {{if .Gateway}}{{.Gateway}}{{else}}-{{end}} {{if .IPRange}}{{.IPRange}}{{else}}-{{end}}{{end}}' "$1" 2>/dev/null
}

# Creates NAME when missing; an existing one must already have exactly these settings. A network
# that differs is refused, never removed or changed here (containers of other projects may be on it).
# ensure_network NAME WANT [docker network create arguments]
ensure_network() {
  local name="$1" want="$2" got
  shift 2
  got="$(net_state "$name")" || got=""
  if [ -z "$got" ]; then
    echo "[INFO] creating network $name"
    docker network create "$@" "$name" >/dev/null || return
    got="$(net_state "$name")" || got=""
  fi
  if [ "$got" = "$want" ]; then
    echo "[INFO] network $name: $got"
  else
    echo "[ERROR] network $name is \"$got\", not \"$want\"; not changing it (fix it by hand)" >&2
    return 1
  fi
}

ensure_networks() {
  ensure_network "$NET_NAME" "$NET_WANT" \
    --driver bridge --subnet "$NET_SUBNET" --gateway "$NET_GATEWAY" || return
  ensure_network "$EDGE_NAME" "$EDGE_WANT" \
    --driver bridge --internal --subnet "$EDGE_SUBNET" --gateway "$EDGE_GATEWAY" --ip-range "$EDGE_IP_RANGE"
}

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi
}

# The certificate's SHA-256 (of its DER) as upper-case colon pairs, for a file holding exactly one
# certificate; nothing otherwise.
ca_fingerprint() {
  local f="$1" n hex
  [ -f "$f" ] || return 0
  n="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$f" 2>/dev/null)" || n=0
  [ "$n" = 1 ] || return 0
  hex="$(awk '/-----BEGIN CERTIFICATE-----/{f=1;next} /-----END CERTIFICATE-----/{f=0} f' "$f" \
    | base64 -d 2>/dev/null | sha256_hex)" || return 0
  printf '%s' "$hex" | tr '[:lower:]' '[:upper:]' | sed -E 's/(..)/\1:/g; s/:$//'
}

# The committed copy is checked before it is placed, and the placed one after.
place_ca() {
  local fp tmp
  fp="$(ca_fingerprint "$CA_SOURCE")"
  if [ "$fp" != "$CA_FINGERPRINT" ]; then
    echo "[ERROR] $CA_SOURCE does not hold one certificate with SHA-256 $CA_FINGERPRINT (got ${fp:-none}); not placing it" >&2
    return 1
  fi
  mkdir -p "$APP_ROOT/ca"
  if ! cmp -s "$CA_SOURCE" "$CA_FILE"; then
    tmp="$(mktemp "$APP_ROOT/ca/.root_ca.XXXXXX")" || return
    cp "$CA_SOURCE" "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$CA_FILE" || { rm -f "$tmp"; return 1; }
    echo "[INFO] placed theOrg's root CA at $CA_FILE"
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

# openldap's leaf in openldap-tls: ldap.crt (the leaf, then the intermediate), ldap.key, ca.crt.
# Reported only, never fatal in M1: openldap does not start until M5. The key is never read here,
# only checked for presence.
# TODO(renewer): the leaf's issue and renewal hook in here, from "identity-platform deploy/d05
# renewer example (theOrg PR, pending)". Until it lands, nothing writes openldap-tls; this script
# must not issue, renew, or read the vault's `ldap` provisioner or keycloak-client-* paths.
check_leaf() {
  local f n end
  if [ ! -d "$LEAF_DIR" ]; then
    echo "[WARN] openldap leaf: $LEAF_DIR is missing (ldap.crt, ldap.key, ca.crt; the renewer is not written yet); needed before the M5 cutover" >&2
    return 0
  fi
  for f in ldap.crt ldap.key ca.crt; do
    if [ -s "$LEAF_DIR/$f" ]; then
      echo "[INFO] openldap leaf: $f present"
    else
      echo "[WARN] openldap leaf: $LEAF_DIR/$f is missing or empty; needed before the M5 cutover" >&2
    fi
  done
  if [ -s "$LEAF_DIR/ldap.crt" ]; then
    n="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$LEAF_DIR/ldap.crt" 2>/dev/null)" || n=0
    if [ "$n" -lt 2 ]; then
      echo "[WARN] openldap leaf: ldap.crt holds $n certificate(s), not the leaf and the intermediate" >&2
    fi
    if command -v openssl >/dev/null 2>&1; then
      end="$(openssl x509 -in "$LEAF_DIR/ldap.crt" -noout -enddate 2>/dev/null)" || end=""
      if [ -z "$end" ]; then
        echo "[WARN] openldap leaf: ldap.crt cannot be read as a certificate" >&2
      elif openssl x509 -in "$LEAF_DIR/ldap.crt" -noout -checkend 0 >/dev/null 2>&1; then
        echo "[INFO] openldap leaf: ${end#notAfter=}"
      else
        echo "[WARN] openldap leaf: expired (${end#notAfter=})" >&2
      fi
    fi
  fi
  return 0
}

# M1's directories only: never openldap-data, openldap-config or openldap-tls.
ensure_dirs() {
  mkdir -p "$APP_ROOT/ca" "$APP_ROOT/keycloak-db"
}

# M1: networks, images, the root CA, the leaf report, then keycloak-db alone, waited for until
# healthy. --no-deps and the one service name: nothing else starts, whatever its profile.
do_up() {
  ensure_networks || return
  pull_missing || return
  ensure_dirs || return
  place_ca || return
  check_leaf
  run_compose up -d --no-deps --wait --wait-timeout "$DB_WAIT_S" keycloak-db || {
    echo "[ERROR] keycloak-db did not become healthy within ${DB_WAIT_S}s" >&2
    return 1
  }
  echo "[INFO] keycloak-db is healthy; openldap and keycloak wait for the M5 cutover"
}

db_health() {
  local id
  id="$(run_compose ps -q keycloak-db 2>/dev/null)" || id=""
  [ -n "$id" ] || { echo "not running"; return 0; }
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' "$id" 2>/dev/null || echo "unknown"
}

# Fatal: both networks as DEPLOY.md has them, the placed root CA, keycloak-db healthy.
# Reported: the openldap leaf.
do_verify() {
  local rc=0 got h
  got="$(net_state "$NET_NAME")" || got=""
  if [ "$got" = "$NET_WANT" ]; then
    echo "[INFO] network $NET_NAME OK"
  else
    echo "[ERROR] network $NET_NAME is \"${got:-missing}\", not \"$NET_WANT\"" >&2
    rc=1
  fi
  got="$(net_state "$EDGE_NAME")" || got=""
  if [ "$got" = "$EDGE_WANT" ]; then
    echo "[INFO] network $EDGE_NAME OK (internal)"
  else
    echo "[ERROR] network $EDGE_NAME is \"${got:-missing}\", not \"$EDGE_WANT\"" >&2
    rc=1
  fi
  check_ca || rc=1
  h="$(db_health)"
  if [ "$h" = healthy ]; then
    echo "[INFO] keycloak-db healthy"
  else
    echo "[ERROR] keycloak-db: $h" >&2
    rc=1
  fi
  check_leaf
  return "$rc"
}

refuse_cutover() {
  echo "[ERROR] $1: M5 cutover, not yet written (theOrg identity-platform DEPLOY.md steps 5-6, after a restore); refused" >&2
  exit 1
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    up)
      if is_replica; then replica_db_secret; else require_db_secret; fi
      map_secrets
      do_up
      ;;
    pull)
      do_pull
      ;;
    images)
      do_images
      ;;
    verify)
      do_verify
      ;;
    down)
      # keycloak-db only: stopped, never removed, no volume or network touched; data stays.
      run_compose stop keycloak-db
      ;;
    start-openldap|start-keycloak|restore)
      refuse_cutover "$cmd"
      ;;
    *)
      echo "[ERROR] unknown switch: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

usage() {
  echo "Usage: $0 [switch ...]" >&2
  echo "  Switches can be combined, e.g. up verify" >&2
  echo "" >&2
  echo "  up              - M1: create $NET_NAME and $EDGE_NAME (internal) if missing, pull missing images," >&2
  echo "                    place theOrg's root CA (fingerprint checked), report the openldap leaf, then" >&2
  echo "                    start keycloak-db alone and wait until healthy; needs IDP_KEYCLOAK_DB_PASSWORD" >&2
  echo "                    in the environment (from OpenBao at deploy; never in a file)" >&2
  echo "                    (replica: a throwaway password made at run time; still keycloak-db alone)" >&2
  echo "  pull            - Pull all six images now (needs IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN)" >&2
  echo "  images          - Pull missing images, then list the default services' images (build_host.py's replica guard)" >&2
  echo "  verify          - Networks, the root CA and keycloak-db healthy (fatal); the openldap leaf (reported)" >&2
  echo "  down            - Stop keycloak-db (never removes a container's data, a volume or a network)" >&2
  echo "  start-openldap, start-keycloak, restore" >&2
  echo "                  - Refused: the M5 cutover, not yet written" >&2
  echo "  logs            - Follow logs (optionally for one service)" >&2
}

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

# A switch that fails has said why; usage is only for an unknown switch (run_cmd) or none.
for cmd in "$@"; do
  run_cmd "$cmd" || exit 1
done
