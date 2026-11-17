#!/bin/bash
# theOrg's identity-platform on d05 (Keycloak, keycloak-db, openldap). Usage:
# identity-platform.sh [switch ...], e.g. up|pull|images|verify|down|logs|leaf-issue|leaf-renew.
# Switches can be combined.
# From theOrg identity-platform DEPLOY.md "Production on d05" and deploy/d05/compose.example.yml at
# 701e893 (main, the #82 merge), carried to 47f65add (profile `restored`, deploy/d05/openldap-leaf.sh)
# and fcbed3fe (#85: openldap-leaf.sh issue takes the provisioner password on stdin).
# This is M1 (agreed with theOrg): networks, images, theOrg's root
# CA, a report on the openldap leaf, and keycloak-db alone. openldap and keycloak are never started
# here: their first start is the M5 cutover (DEPLOY.md steps 5-6), after a restore, and theOrg's
# restores refuse a target that is not empty (keycloak_backup.sh counts tables; openldap_backup.sh
# checks the volumes). A first openldap start runs osixia's bootstrap, so M1 never creates
# openldap-data or openldap-config. start-openldap, start-keycloak, configure and restore refuse
# until M5 is written (the cutover bundle below is its first part).
# No secret is in any file here or on the host. The workstation resolves the values from OpenBao
# at deploy (build_host.py start_env, pull_token_env) and hands them to this process's environment;
# this script maps them onto the names compose.yml passes by name. Only the long-running services
# (keycloak, keycloak-db, openldap) name a secret; every one-shot (configure, the backup and
# restore runs, break-glass) takes its value on stdin (theOrg bd0c6bff, the operator's rule of
# 2026-11-16), so map_secrets exports nothing a one-shot would read:
#   IDP_KEYCLOAK_DB_PASSWORD       -> KC_DB_PASSWORD (keycloak), POSTGRES_PASSWORD (keycloak-db);
#                                     up needs it. keycloak-backup takes it on stdin (M5), never PGPASSWORD.
#   IDP_LDAP_ADMIN_PASSWORD        -> LDAP_ADMIN_PASSWORD, LDAP_CONFIG_PASSWORD (openldap; M5; not sent in M1)
#   IDP_DEPLOY_DEX_CLIENT_SECRET   -> never exported: keycloak-configure takes it on stdin (#86; M5;
#                                     not sent in M1)
# docker compose hands a name only to the services that list it, and M1 starts keycloak-db alone,
# so in M1 only POSTGRES_PASSWORD reaches a container.
# On any host but d05 (test01 as a replica of d05) up runs in replica mode: build_host.py sends a
# replica no start_env, so keycloak-db gets a throwaway password made at run time (never d05's,
# never written to a file by this script); the rest of up is as on d05, and openldap and keycloak
# still never start.
# The openldap leaf (DEPLOY.md "Production on d05: directory (R10)"): openldap-leaf.sh beside this
# script, a byte-identical copy of theOrg's deploy/d05/openldap-leaf.sh at fcbed3fe (README).
#   leaf-issue  reads step-ca's `ldap` provisioner password (OpenBao secret/v2/certificate-management/
#               step-ca/provisioners/ldap, field password) as one line on its own stdin, which the
#               workstation writes (scripts/app_switch.sh, over ssh stdin), and writes it to
#               openldap-leaf.sh issue's stdin with bash's builtin printf. It is never in an
#               environment (refused, exit 3, when LDAP_PROVISIONER_PASSWORD is set in this one),
#               an argv, a file or a log. Runs alone (refused combined with another switch).
#               Run it before openldap's first start (osixia self-signs when the files are
#               missing). Never on a replica.
#   leaf-renew  no secret; every 3 hours once the operator approves the schedule (DEPLOY.md item 13,
#               leaf-schedule-install). Never on a replica.
#   Both write /mnt/docker/IdentityPlatform/leaf-status.json (ok, fail, or for leaf-issue refused by
#   openldap-leaf.sh: refused with the previous problems kept; exit, the leaf's notAfter)
#   for host-maintenance's monitor; leaf-schedule-install needs a successful leaf-issue in it.
# At start this script notes whether LDAP_PROVISIONER_PASSWORD is set in its environment and unsets
# it, without reading the value, so that no child ever inherits it; leaf-issue and leaf-renew then
# refuse (exit 3).
# The M5 cutover bundle (asyla #654; theOrg deploy/d05/CUTOVER-BUNDLE.md at CUTOVER_BUNDLE_COMMIT):
#   fetch-bundle VERSION  reads the theorg-registry pull token as one line on stdin; pulls the
#               cutover-bundle image if missing (the token in that docker pull's environment alone,
#               through the credential helper, as pull) and downloads the package's bundle.tar.age to
#               cutover/ with curl, the token on curl's config stdin (-K -) alone.
#   unpack-bundle MANIFESTS_SHA256 KC_SUM OL_SUM  reads the age identity as one line on stdin and
#               writes it to the image's unpack on stdin alone; the two targets are backup/ and
#               openldap-backup/ (the dirs the restores read).
#   reset-cutover  removes the unpacked marker, empties both targets (lost+found kept) with the
#               pinned image's find (the files are root-owned), then removes the unpack-started
#               marker, keeping the ciphertext and the fetched marker. It deletes only what an unpack
#               wrote: refused (exit 3, nothing changed) with neither unpack-started nor unpacked
#               (targets already empty: a no-op, exit 0), on a replica, once cutover-done, a restore
#               marker, or a restored or ops container exists, or when compose cannot tell.
#   cutover-clean  removes the ciphertext and fetch-bundle's temp downloads; keeps the fetched marker
#               (the gate compares unpacked with it); idempotent. Refused on a replica and once cutover-done exists.
#   A marker per step in cutover-state/: fetched; unpack-started (written right before unpack's
#   docker run: the targets then hold unpack's files); unpacked; restored-openldap and
#   restored-keycloak from the restores; cutover-done from the go-live or restore switch (neither
#   writes yet). Each is written atomically, then synced (sync -f). start-openldap, start-keycloak
#   and configure are gated on them (cutover_gate, exit 3 naming the missing or invalid marker: an
#   unpacked whose version is not fetched's, an empty restored-*), and still refuse (exit 3) in this
#   round. restore refuses (exit 1: never build_host.py's skip status 3) until theOrg's B2a and
#   identity-platform #86. reset-cutover and unpack-bundle refuse (exit 3) when a target or
#   cutover-state/ is a symlink.
#   THEORG_REGISTRY_PULL_TOKEN and IDP_CUTOVER_BUNDLE_IDENTITY are noted and unset at start, as
#   LDAP_PROVISIONER_PASSWORD is; fetch-bundle and unpack-bundle then refuse (exit 3). The four
#   cutover switches each run alone, and one at a time: each holds flock(1) (util-linux) -n on
#   cutover-state/.lock for its whole run; a busy lock is refused (exit 3).
# Data under /mnt/docker/IdentityPlatform. No backup here yet: the data is the Mini's until M5.

set -euo pipefail

# LDAP_PROVISIONER_PASSWORD never belongs in an environment (the value arrives on leaf-issue's
# stdin). If it is set anyway, note that and unset it before any child runs (dirname below included)
# or common.env is sourced, never copying the value: no child gets it (header).
LEAF_PW_IN_ENV=false
if [ -n "${LDAP_PROVISIONER_PASSWORD+x}" ]; then
  LEAF_PW_IN_ENV=true
fi
unset LDAP_PROVISIONER_PASSWORD
# The same for the cutover's two stdin values (fetch-bundle, unpack-bundle).
CUT_PULL_IN_ENV=false
if [ -n "${THEORG_REGISTRY_PULL_TOKEN+x}" ]; then
  CUT_PULL_IN_ENV=true
fi
unset THEORG_REGISTRY_PULL_TOKEN
CUT_ID_IN_ENV=false
if [ -n "${IDP_CUTOVER_BUNDLE_IDENTITY+x}" ]; then
  CUT_ID_IN_ENV=true
fi
unset IDP_CUTOVER_BUNDLE_IDENTITY

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
IDENTITY_PLATFORM_TAG="${IDENTITY_PLATFORM_TAG_OVERRIDE:-fcbed3febc7e65bc7afbab980d6b3868a0b3fe53}"
REGISTRY="gitea.asyla.org"
export IDENTITY_PLATFORM_ROOT IDENTITY_PLATFORM_TAG

# theOrg's root, "theOrg-v2 Root CA" (expires 2036-08-29), copied from internal-access
# hosts/d03/upstream-ca/theorg-v2-root.pem (byte-identical to step-ca's /roots.pem, read
# 2026-11-14). Its SHA-256 is keycloak-configure's KEYCLOAK_CA_FINGERPRINT (compose.yml).
CA_SOURCE="$SCRIPT_DIR/theorg-v2-root.crt"
CA_FINGERPRINT="CD:39:1A:56:AE:00:0B:01:A4:43:3A:73:F2:2D:98:A3:73:E5:BB:08:E8:D7:75:31:DF:2D:B8:6A:4F:29:87:D3"
CA_FILE="$APP_ROOT/ca/root_ca.crt"
LEAF_DIR="$APP_ROOT/openldap-tls"
LEAF_SCRIPT="$SCRIPT_DIR/openldap-leaf.sh"

# The M5 cutover bundle. The image is pinned to theOrg identity-platform #87 at its approved commit
# (CI green, NOT merged yet): repin to the merged main commit here, one line.
CUTOVER_BUNDLE_COMMIT="7ac1bfb4ba3402f16d029765cdc92c51a5fab769"
CUTOVER_IMAGE="$REGISTRY/theorg/identity-platform-cutover-bundle:$CUTOVER_BUNDLE_COMMIT"
CUTOVER_PKG_URL="https://$REGISTRY/api/packages/theorg/generic/identity-platform-cutover"
CUTOVER_VERSION_RE='^m5-[0-9a-f]{12}$'
SHA256_RE='^[0-9a-f]{64}$'
CUT_DIR="$APP_ROOT/cutover"
BUNDLE="$CUT_DIR/bundle.tar.age"
STATE_DIR="$APP_ROOT/cutover-state"
# unpack's two targets: the dirs keycloak-backup and openldap-backup mount at /backup (compose.yml),
# so the restores read what unpack wrote.
KC_TARGET="$APP_ROOT/backup"
OL_TARGET="$APP_ROOT/openldap-backup"

# The renewer's systemd units: the service is a template (@USER@, @SCRIPT@), filled in and
# installed only by leaf-schedule-install.
LEAF_UNIT="identity-platform-leaf-renew"
SYSTEMD_DIR="${IDENTITY_PLATFORM_SYSTEMD_DIR:-/etc/systemd/system}"

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

# --profile restored and ops name every service, for the image list and the pulls only; a start
# never takes either profile, and COMPOSE_PROFILES is never set here (M1).
ALL_PROFILES=(--profile ops --profile restored)

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

# Exports only the names a long-running service lists (compose.yml). Never PGPASSWORD or
# VAULT_DEX_CLIENT_SECRET: their one-shots take the value on stdin.
map_secrets() {
  if [ -n "${IDP_KEYCLOAK_DB_PASSWORD:-}" ]; then
    KC_DB_PASSWORD="$IDP_KEYCLOAK_DB_PASSWORD"
    POSTGRES_PASSWORD="$IDP_KEYCLOAK_DB_PASSWORD"
    export KC_DB_PASSWORD POSTGRES_PASSWORD
  fi
  if [ -n "${IDP_LDAP_ADMIN_PASSWORD:-}" ]; then
    LDAP_ADMIN_PASSWORD="$IDP_LDAP_ADMIN_PASSWORD"
    LDAP_CONFIG_PASSWORD="$IDP_LDAP_ADMIN_PASSWORD"
    export LDAP_ADMIN_PASSWORD LDAP_CONFIG_PASSWORD
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

ensure_pull_config() {
  if [ -z "$PULL_CONFIG" ]; then
    PULL_CONFIG="$(mktemp -d)" || return
    printf '{"credHelpers":{"%s":"identity-platform-env"}}\n' "$REGISTRY" > "$PULL_CONFIG/config.json" || return
  fi
}

pull_compose() {
  if [ -z "${IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN:-}" ]; then
    echo "[ERROR] IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN is not in this process's environment; the pull token comes from the workstation (build_host.py pull_token_env)" >&2
    return 1
  fi
  ensure_pull_config || return
  ( export DOCKER_CONFIG="$PULL_CONFIG" PATH="$SCRIPT_DIR:$PATH"; run_compose "$@" )
}

# All six images: theOrg's four and the two upstream ones.
do_pull() {
  pull_compose "${ALL_PROFILES[@]}" pull
}

# build_host.py's replica guard (replica_images): pull what is missing (with the workstation's pull
# token), then print the images of the default services (keycloak-db's alone: openldap and keycloak
# are in restored, the one-shots in ops), one per line, on stdout only; each is probed for egress.
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
# ip-range), or nothing when the network does not exist. Docker 29 keeps these as netip values, so
# an unset one prints "invalid Prefix" / "invalid IP", not empty (seen on d05, 29.9.3, 2026-11-14):
# both read as "-".
net_state() {
  docker network inspect -f '{{.Driver}} {{.Internal}}{{range .IPAM.Config}} {{.Subnet}} {{if .Gateway}}{{.Gateway}}{{else}}-{{end}} {{if .IPRange}}{{.IPRange}}{{else}}-{{end}}{{end}}' "$1" 2>/dev/null \
    | sed -e 's/invalid Prefix/-/g' -e 's/invalid IP/-/g'
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
# only checked for presence. up and verify never issue or renew: leaf-issue and leaf-renew do.
check_leaf() {
  local f n end
  if [ ! -d "$LEAF_DIR" ]; then
    echo "[WARN] openldap leaf: $LEAF_DIR is missing (ldap.crt, ldap.key, ca.crt; leaf-issue makes them); needed before openldap's first start" >&2
    return 0
  fi
  for f in ldap.crt ldap.key ca.crt; do
    if [ -s "$LEAF_DIR/$f" ]; then
      echo "[INFO] openldap leaf: $f present"
    else
      echo "[WARN] openldap leaf: $LEAF_DIR/$f is missing or empty (leaf-issue); needed before openldap's first start" >&2
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

# The leaf's status file, read by host-maintenance's monitor (its config/maintenance.toml [[status]]
# identity-platform-leaf; the format its runner/maint.py status_problems reads: "time" and
# "problems", each problem {"key", "severity", "message"}). Written by every leaf-issue and
# leaf-renew past their refusals (replica, value), ok or not, atomically: a temp file in the same
# directory, then mv. "problems" is empty on ok, the previous file's on a leaf-issue that
# openldap-leaf.sh refused (exit 3: result "refused"); on fail it holds one problem, key "leaf": "warn"
# (a work item) while the leaf's notAfter is LEAF_URGENT_S (6 hours) away or more, "urgent" when it
# is nearer, past or unreadable. "issued_ok" is the time of the last successful leaf-issue, carried
# forward by every write; leaf-schedule-install needs it. No secret is ever in it. "time" is UTC
# with a trailing Z: maint.py's parse_iso is datetime.fromisoformat (Python 3.12, its CI image),
# which reads a Z as UTC since Python 3.11.
LEAF_STATUS="$APP_ROOT/leaf-status.json"
LEAF_URGENT_S=21600

# The leaf's notAfter as openssl prints it ("Nov 15 12:00:00 2026 GMT"), or nothing.
leaf_not_after() {
  local end
  [ -s "$LEAF_DIR/ldap.crt" ] && command -v openssl >/dev/null 2>&1 || return 0
  end="$(openssl x509 -in "$LEAF_DIR/ldap.crt" -noout -enddate 2>/dev/null)" || return 0
  printf '%s' "${end#notAfter=}" | tr -cd 'A-Za-z0-9 :'
}

json_str() { if [ -n "$1" ]; then printf '"%s"' "$1"; else printf 'null'; fi; }

# write_leaf_status ACTION EXIT [refused]: "refused" (leaf-issue's EXIT 3 from openldap-leaf.sh: a
# valid leaf already there, or its lock held) records result "refused" and carries the previous
# file's problems forward unchanged (none when there is no file): nothing failed, so no new problem
# (host-maintenance would turn one into a spurious work item), and a standing one is not cleared.
write_leaf_status() {
  local action="$1" rc="$2" refused="${3:-}" t result=ok na issued="" sev msg problems="[]" prev tmp
  t="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return
  [ "$rc" -eq 0 ] || result=fail
  [ "$refused" != refused ] || [ "$rc" -eq 0 ] || result=refused
  na="$(leaf_not_after)"
  if [ "$action" = leaf-issue ] && [ "$result" = ok ]; then
    issued="$t"
  elif [ -f "$LEAF_STATUS" ]; then
    issued="$(sed -nE 's/^  "issued_ok": "([0-9TZ:-]+)",?$/\1/p' "$LEAF_STATUS" | head -n 1)" || issued=""
  fi
  if [ "$result" = refused ] && [ -f "$LEAF_STATUS" ]; then
    prev="$(sed -nE 's/^  "problems": (\[.*\])$/\1/p' "$LEAF_STATUS" | head -n 1)" || prev=""
    [ -z "$prev" ] || problems="$prev"
  fi
  if [ "$result" = fail ]; then
    msg="$SERVING_HOST: identity-platform $action failed (exit $rc)"
    if [ -n "$na" ] && openssl x509 -in "$LEAF_DIR/ldap.crt" -noout -checkend "$LEAF_URGENT_S" >/dev/null 2>&1; then
      sev=warn
      msg="$msg; the openldap leaf is valid until $na"
      [ "$action" != leaf-renew ] || msg="$msg; the timer retries every 3 hours"
    elif [ -n "$na" ]; then
      sev=urgent
      msg="$msg; the openldap leaf expires $na, under 6 hours away (or past): renew or issue it now"
    else
      sev=urgent
      msg="$msg; the openldap leaf cannot be read: renew or issue it now"
    fi
    problems="[{\"key\": \"leaf\", \"severity\": \"$sev\", \"message\": \"$msg\"}]"
  fi
  mkdir -p "$APP_ROOT" || return
  tmp="$(mktemp "$APP_ROOT/.leaf-status.XXXXXX")" || return
  if printf '{\n  "time": "%s",\n  "action": "%s",\n  "result": "%s",\n  "exit": %d,\n  "not_after": %s,\n  "issued_ok": %s,\n  "problems": %s\n}\n' \
      "$t" "$action" "$result" "$rc" "$(json_str "$na")" "$(json_str "$issued")" "$problems" > "$tmp" \
    && chmod 0644 "$tmp" && mv -f "$tmp" "$LEAF_STATUS"; then
    echo "[INFO] $LEAF_STATUS: $action $result (exit $rc)"
  else
    rm -f "$tmp"
    echo "[ERROR] could not write $LEAF_STATUS" >&2
    return 1
  fi
}

# A failed status write fails the switch (exit 1) even when openldap-leaf.sh succeeded: the monitor
# would otherwise call the leaf stale.
record_leaf() {   # record_leaf ACTION EXIT [refused]: prints the exit to return
  if write_leaf_status "$1" "$2" "${3:-}" >&2; then echo "$2"; elif [ "$2" -ne 0 ]; then echo "$2"; else echo 1; fi
}

# leaf-issue: the networks (openldap-leaf.sh runs step on identity-platform-net), the checked root
# CA at ca/root_ca.crt (step's --root, and the leaf's ca.crt), openldap-tls (the one openldap dir
# M1 makes; never openldap-data or openldap-config), then openldap-leaf.sh issue with the value on
# its stdin alone. The value is one line on this script's own stdin (scripts/app_switch.sh writes it
# over ssh stdin), read with `IFS= builtin read -r` into a local variable that is never exported
# (xtrace and allexport off first), then this shell's stdin is pointed at /dev/null so that no later
# child holds the pipe. bash's builtin printf writes it into a pipe to openldap-leaf.sh issue (theOrg's
# interface since fcbed3fe), run with `builtin exec` in a subshell, and the variable is unset after that run.
# Every command the value passes through is a builtin, a keyword ([[ ]]) or a program by path, never
# a function: a printf, read, [ or openldap-leaf.sh function (common.env is sourced above) is
# never called with it. Never an argv, an
# environment, a file or a log. Refused (exit 3, before any docker call and without a status
# write) when LDAP_PROVISIONER_PASSWORD was set in this script's environment, when stdin is a
# terminal, and when the line read is empty; refused on a replica (exit 1; step-ca and its
# provisioner are d05's). openldap-leaf.sh refuses over a leaf that is still valid or while its lock
# is held (exit 3, kept): recorded as result "refused" with the previous problems kept, never as a
# new failure.
do_leaf_issue() {
  if $LEAF_PW_IN_ENV; then
    echo "[ERROR] leaf-issue: refused: LDAP_PROVISIONER_PASSWORD is set in the environment; unset it and write the password as one line to leaf-issue's stdin (scripts/app_switch.sh does); not issuing" >&2
    return 3
  fi
  if [ -t 0 ]; then
    echo "[ERROR] leaf-issue: refused: stdin is a terminal; leaf-issue reads the provisioner password as one line on stdin (OpenBao secret/v2/certificate-management/step-ca/provisioners/ldap, field password; scripts/app_switch.sh writes it); not issuing" >&2
    return 3
  fi
  { set +x; } 2>/dev/null
  set +a
  # A same-named variable exported into this script's environment would make the local exported
  # too (bash's local keeps the export flag): out of the environment first, and never exported.
  unset -v pw
  local +x pw=""
  IFS= builtin read -r pw || true
  exec </dev/null
  if [[ -z $pw ]]; then
    echo "[ERROR] leaf-issue: refused: no provisioner password read on stdin (OpenBao secret/v2/certificate-management/step-ca/provisioners/ldap, field password); not issuing" >&2
    return 3
  fi
  if is_replica; then
    unset -v pw
    echo "[ERROR] leaf-issue: not on a replica ($(hostname -s)); the leaf is d05's" >&2
    return 1
  fi
  local rc=0 refused=""
  { ensure_networks && place_ca && mkdir -p "$LEAF_DIR"; } || rc=$?
  if [ "$rc" -eq 0 ]; then
    # `builtin exec` in its own subshell: a program, never a function, and its exit status kept
    # (bash 3.2 exits the shell under set -e when a program run by `builtin command` fails).
    builtin printf '%s\n' "$pw" | (IDENTITY_PLATFORM_ROOT="$IDENTITY_PLATFORM_ROOT" builtin exec "$LEAF_SCRIPT" issue) || rc=$?
    [ "$rc" -ne 3 ] || refused=refused
  fi
  unset -v pw
  rc="$(record_leaf leaf-issue "$rc" "$refused")"
  [ "$rc" -eq 0 ] || { echo "[ERROR] leaf-issue: exit $rc (3: refused by openldap-leaf.sh)" >&2; return "$rc"; }
  check_leaf
}

# leaf-renew: openldap-leaf.sh renew, no secret (it refuses one, so this does too). Refused on a
# replica. Exit as openldap-leaf.sh's (0 done or not due, 1 failed, 3 refused: run leaf-issue), or 1
# when the status file could not be written.
do_leaf_renew() {
  if is_replica; then
    echo "[ERROR] leaf-renew: not on a replica ($(hostname -s)); the leaf is d05's" >&2
    return 1
  fi
  if $LEAF_PW_IN_ENV; then
    echo "[ERROR] leaf-renew: needs no provisioner password; refused while LDAP_PROVISIONER_PASSWORD is set" >&2
    return 3
  fi
  local rc=0
  "$LEAF_SCRIPT" renew || rc=$?
  rc="$(record_leaf leaf-renew "$rc")"
  return "$rc"
}

# The renewer's schedule (DEPLOY.md item 13), installed only by leaf-schedule-install, which the
# operator runs once he has approved it: never by up, a build or the updater. The service runs
# leaf-renew as this user from this folder.
render_leaf_service() {
  local esc
  esc="$(printf '%s' "$SCRIPT_DIR/identity-platform.sh" | sed 's/[&|\\]/\\&/g')"
  sed -e "s|@USER@|$(id -un)|" -e "s|@SCRIPT@|$esc|" "$SCRIPT_DIR/$LEAF_UNIT.service"
}

leaf_issued_ok() {
  [ -f "$LEAF_STATUS" ] && grep -qE '^  "issued_ok": "[0-9]' "$LEAF_STATUS"
}

# Idempotent: each unit is rendered and compared with the installed one, installed only when it
# differs, and daemon-reload runs only when one changed. Run it again after an update that changes
# either template (README). Refused until the status file records a successful leaf-issue.
do_leaf_schedule_install() {
  local tmp changed=""
  if is_replica; then
    echo "[ERROR] leaf-schedule-install: not on a replica ($(hostname -s))" >&2
    return 1
  fi
  if ! leaf_issued_ok; then
    echo "[ERROR] leaf-schedule-install: $LEAF_STATUS records no successful leaf-issue; run leaf-issue first (renew refuses without a leaf)" >&2
    return 1
  fi
  if [ ! -s "$LEAF_DIR/ldap.crt" ]; then
    echo "[ERROR] leaf-schedule-install: no leaf at $LEAF_DIR/ldap.crt; run leaf-issue first (renew refuses without one)" >&2
    return 1
  fi
  tmp="$(mktemp)" || return
  render_leaf_service > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! cmp -s "$tmp" "$SYSTEMD_DIR/$LEAF_UNIT.service"; then
    sudo install -m 0644 "$tmp" "$SYSTEMD_DIR/$LEAF_UNIT.service" || { rm -f "$tmp"; return 1; }
    changed="$changed $LEAF_UNIT.service"
  fi
  rm -f "$tmp"
  if ! cmp -s "$SCRIPT_DIR/$LEAF_UNIT.timer" "$SYSTEMD_DIR/$LEAF_UNIT.timer"; then
    sudo install -m 0644 "$SCRIPT_DIR/$LEAF_UNIT.timer" "$SYSTEMD_DIR/$LEAF_UNIT.timer" || return
    changed="$changed $LEAF_UNIT.timer"
  fi
  if [ -n "$changed" ]; then
    echo "[INFO] installed$changed"
    sudo systemctl daemon-reload || return
  else
    echo "[INFO] $LEAF_UNIT.service and .timer unchanged; no daemon-reload"
  fi
  sudo systemctl enable --now "$LEAF_UNIT.timer" || return
  echo "[INFO] $LEAF_UNIT.timer enabled (openldap-leaf.sh renew every 3 hours)"
  do_leaf_schedule_status
}

# Read-only: the timer, the service's last result, and the status file.
do_leaf_schedule_status() {
  local en act res
  en="$(systemctl is-enabled "$LEAF_UNIT.timer" 2>/dev/null)" || true
  act="$(systemctl is-active "$LEAF_UNIT.timer" 2>/dev/null)" || true
  echo "[INFO] $LEAF_UNIT.timer: ${en:-not installed}, ${act:-inactive}"
  res="$(systemctl show -p Result,ExecMainStatus "$LEAF_UNIT.service" 2>/dev/null | tr '\n' ' ')" || res=""
  echo "[INFO] $LEAF_UNIT.service last run: ${res:-unknown}"
  if [ -f "$LEAF_STATUS" ]; then
    echo "[INFO] $LEAF_STATUS:"
    sed 's/^/  /' "$LEAF_STATUS"
  else
    echo "[INFO] $LEAF_STATUS: none yet (leaf-issue writes it)"
  fi
}

do_leaf_schedule_remove() {
  if [ -e "$SYSTEMD_DIR/$LEAF_UNIT.timer" ] || [ -e "$SYSTEMD_DIR/$LEAF_UNIT.service" ]; then
    sudo systemctl disable --now "$LEAF_UNIT.timer" || true
    sudo rm -f "$SYSTEMD_DIR/$LEAF_UNIT.timer" "$SYSTEMD_DIR/$LEAF_UNIT.service" || return
    sudo systemctl daemon-reload || return
    echo "[INFO] removed $LEAF_UNIT.timer and .service"
  else
    echo "[INFO] $LEAF_UNIT.timer is not installed"
  fi
}

# --- The M5 cutover bundle (theOrg deploy/d05/CUTOVER-BUNDLE.md at CUTOVER_BUNDLE_COMMIT) ---
# One marker per step in cutover-state/, each written atomically (a temp file in the same dir, then
# mv), then synced: bash has no fsync, so `sync -f` (coreutils >= 8.24; bookworm's 9.1: syncfs of
# the file's file system, the rename included), else `sync FILE`; a failed sync is a warning only.
# Each is `key value` lines: fetched (version, sha256), unpack-started (version, manifests-sha256),
# unpacked (unpack's four lines); restored-openldap, restored-keycloak and cutover-done come from
# the restores and go-live (not written yet).
CUTOVER_DONE=cutover-done
write_state() {   # write_state NAME LINE...
  local name="$1" tmp
  shift
  mkdir -p "$STATE_DIR" || return
  tmp="$(mktemp "$STATE_DIR/.$name.XXXXXX")" || return
  if printf '%s\n' "$@" > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$STATE_DIR/$name"; then
    sync -f "$STATE_DIR/$name" 2>/dev/null </dev/null || sync "$STATE_DIR/$name" </dev/null \
      || echo "[WARN] could not sync $STATE_DIR/$name (written, maybe not yet on disk)" >&2
    echo "[INFO] $STATE_DIR/$name written"
  else
    rm -f "$tmp"
    echo "[ERROR] could not write $STATE_DIR/$name" >&2
    return 1
  fi
}

# refuse_symlinks SWITCH PATH...: exit 3 (nothing touched) when any PATH is a symlink: the cutover
# writes and deletes in these dirs as root (through the image), never through a link.
refuse_symlinks() {
  local sw="$1" p
  shift
  for p in "$@"; do
    if [ -L "$p" ]; then
      echo "[ERROR] $sw: refused: $p is a symlink; the cutover never writes or deletes through a link; nothing changed" >&2
      return 3
    fi
  done
}

# cutover_lock SWITCH: one cutover switch at a time. flock(1) -n (util-linux, as openldap-leaf.sh)
# on cutover-state/.lock through fd 9, held until this script exits (each cutover switch runs alone,
# then exits). Busy: exit 3; no flock: exit 1. Called after the replica refusal (nothing on the
# filesystem before it); makes cutover-state/ first (refused when it is a symlink).
cutover_lock() {
  refuse_symlinks "$1" "$STATE_DIR" || return
  command -v flock >/dev/null 2>&1 || { echo "[ERROR] $1: flock (util-linux) is not on PATH; refusing to run without the cutover lock" >&2; return 1; }
  mkdir -p "$STATE_DIR" || return 1
  exec 9> "$STATE_DIR/.lock" || return 1
  if ! flock -n 9; then
    echo "[ERROR] $1: refused: another cutover switch is running (it holds $STATE_DIR/.lock); nothing changed" >&2
    return 3
  fi
}

state_value() {   # state_value NAME KEY: the value, or nothing
  [ -f "$STATE_DIR/$1" ] || return 0
  sed -nE "s/^$2 ([^ ]+)\$/\\1/p" "$STATE_DIR/$1" | head -n 1
}

file_sha256() { sha256_hex < "$1"; }

# fetch-bundle VERSION: the package's bundle.tar.age to cutover/, and the cutover image if missing.
# The token is one line on this script's stdin (scripts/app_switch.sh writes it), read as leaf-issue
# reads its value: a local never exported, xtrace and allexport off, stdin then /dev/null. It reaches
# two programs alone: curl, on its config stdin (`-K -`; -q first so no .curlrc is read), and the
# image's docker pull, in that subshell's environment, through the credential helper (as pull).
# Never an argv, a file or a log. Refused (exit 3, nothing called) on a replica (before stdin is
# read), when THEORG_REGISTRY_PULL_TOKEN
# or IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN is in the environment, stdin is a terminal or the read is
# empty, and over an existing bundle or unpacked marker (cutover-clean or reset-cutover first); exit
# 2 for a VERSION that is not m5-<12 hex>. The download goes to a temp name in cutover/, then mv;
# prints its size and sha256 and writes the fetched marker.
do_fetch_bundle() {
  local ver="${1:-}" tre='^[A-Za-z0-9_.-]+$' tmp rc=0 sum size
  if $CUT_PULL_IN_ENV || [ -n "${IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN+x}" ]; then
    echo "[ERROR] fetch-bundle: refused: the pull token is set in the environment; write it as one line to fetch-bundle's stdin (scripts/app_switch.sh does); not fetching" >&2
    return 3
  fi
  if [ $# -ne 1 ] || [[ ! $ver =~ $CUTOVER_VERSION_RE ]]; then
    echo "[ERROR] fetch-bundle: usage: fetch-bundle VERSION (one ARG matching $CUTOVER_VERSION_RE: pack's version line)" >&2
    return 2
  fi
  if is_replica; then
    echo "[ERROR] fetch-bundle: refused: not on a replica ($(hostname -s </dev/null)); the cutover is d05's; stdin not read" >&2
    return 3
  fi
  cutover_lock fetch-bundle || return
  if [ -e "$BUNDLE" ]; then
    echo "[ERROR] fetch-bundle: refused: $BUNDLE exists; run cutover-clean first (reset-cutover too after an unpack)" >&2
    return 3
  fi
  if [ -e "$STATE_DIR/unpacked" ]; then
    echo "[ERROR] fetch-bundle: refused: $STATE_DIR/unpacked exists (a bundle is already unpacked); run reset-cutover first" >&2
    return 3
  fi
  if [ -t 0 ]; then
    echo "[ERROR] fetch-bundle: refused: stdin is a terminal; fetch-bundle reads the theorg-registry pull token as one line on stdin (scripts/app_switch.sh writes it); not fetching" >&2
    return 3
  fi
  { set +x; } 2>/dev/null
  set +a
  unset -v tok
  local +x tok=""
  IFS= builtin read -r tok || true
  exec </dev/null
  if [[ -z $tok ]]; then
    echo "[ERROR] fetch-bundle: refused: no pull token read on stdin; not fetching" >&2
    return 3
  fi
  if [[ ! $tok =~ $tre ]]; then
    unset -v tok
    echo "[ERROR] fetch-bundle: refused: the value read holds characters outside [A-Za-z0-9_.-]; not fetching" >&2
    return 3
  fi
  if ! docker image inspect "$CUTOVER_IMAGE" >/dev/null 2>&1; then
    ensure_pull_config || { unset -v tok; return 1; }
    echo "[INFO] pulling $CUTOVER_IMAGE"
    # `builtin exec` in its own subshell: the docker program, never a function.
    ( IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN="$tok"
      export IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN DOCKER_CONFIG="$PULL_CONFIG" PATH="$SCRIPT_DIR:$PATH"
      builtin exec docker pull "$CUTOVER_IMAGE" ) >&2 || rc=$?
    if [ "$rc" -ne 0 ]; then
      unset -v tok
      echo "[ERROR] fetch-bundle: docker pull $CUTOVER_IMAGE failed (exit $rc); nothing downloaded" >&2
      return 1
    fi
  fi
  mkdir -p "$CUT_DIR" && tmp="$(mktemp "$CUT_DIR/.bundle.XXXXXX")" || { unset -v tok; return 1; }
  builtin printf 'header = "Authorization: token %s"\n' "$tok" \
    | (builtin exec curl -q -K - --fail --silent --show-error --proto =https --connect-timeout 20 \
        -o "$tmp" "$CUTOVER_PKG_URL/$ver/bundle.tar.age") || rc=$?
  unset -v tok
  if [ "$rc" -ne 0 ] || ! mv -f "$tmp" "$BUNDLE"; then
    rm -f "$tmp"
    echo "[ERROR] fetch-bundle: the download of $ver failed (curl exit $rc); nothing kept" >&2
    return 1
  fi
  sum="$(file_sha256 "$BUNDLE")" && size="$(wc -c < "$BUNDLE" | tr -d ' ')" || return 1
  echo "[INFO] $BUNDLE: $ver, $size bytes, sha256 $sum"
  write_state fetched "version $ver" "sha256 $sum"
}

target_empty() {   # target_empty DIR: missing, or holding nothing but lost+found (unlistable: not empty)
  local d="$1" names
  [ -e "$d" ] || return 0
  [ -d "$d" ] || return 1
  names="$(ls -A "$d" </dev/null)" || return 1
  [ -z "$names" ] || [ "$names" = "lost+found" ]
}

# unpack-bundle MANIFESTS_SHA256 KC_SUM OL_SUM: the image's unpack of cutover/bundle.tar.age into
# backup/ and openldap-backup/ (the contract's command, exactly), checked against pack's three
# sha256s the operator relays. The identity is one line on this script's stdin (scripts/app_switch.sh
# writes it), read as leaf-issue reads its value; it reaches unpack's stdin alone (builtin printf
# into `builtin exec docker run -i`), never an argv, an environment, a file or a log. Refused (exit 3,
# nothing changed, no docker run) on a replica (before stdin is read), with IDP_CUTOVER_BUNDLE_IDENTITY
# in the environment, a terminal on stdin or an empty read; with no fetched marker or no bundle, a
# bundle whose sha256 is not the fetched one, a fetched version that is not m5-<MANIFESTS_SHA256's
# first 12 hex> (a wrong bundle), an unpacked marker, an unpack-started marker without unpacked (a
# previous unpack did not finish), a target holding more than lost+found (run reset-cutover), a
# target or cutover-state/ that is a symlink, the cutover lock busy, or the image missing (run
# fetch-bundle). Exit 2 for ARGs that are not three 64-hex. Past every refusal and the identity
# read, the unpack-started marker (fetched version, MANIFESTS_SHA256), then the docker run
# (--pull never: the image fetch-bundle pulled, never a registry).
# unpack's own exit is kept: 1 or 4 leave files without STATUS (reset-cutover before a retry), 2 or 3
# changed nothing. After exit 0 its four stdout lines must be version, manifests-sha256,
# keycloak-summary-sha256 and openldap-summary-sha256 equal to the fetched version and the three ARGs,
# in that order; then the unpacked marker holds them. Anything else: no marker, exit 1.
do_unpack_bundle() {
  local m="${1:-}" k="${2:-}" o="${3:-}" ver sum out want rc=0
  if $CUT_ID_IN_ENV; then
    echo "[ERROR] unpack-bundle: refused: IDP_CUTOVER_BUNDLE_IDENTITY is set in the environment; write the identity as one line to unpack-bundle's stdin (scripts/app_switch.sh does); not unpacking" >&2
    return 3
  fi
  if [ $# -ne 3 ] || [[ ! $m =~ $SHA256_RE ]] || [[ ! $k =~ $SHA256_RE ]] || [[ ! $o =~ $SHA256_RE ]]; then
    echo "[ERROR] unpack-bundle: usage: unpack-bundle MANIFESTS_SHA256 KC_SUM OL_SUM (three ARGs matching $SHA256_RE: pack's manifests-sha256, keycloak-summary-sha256 and openldap-summary-sha256 lines)" >&2
    return 2
  fi
  if is_replica; then
    echo "[ERROR] unpack-bundle: refused: not on a replica ($(hostname -s </dev/null)); the cutover is d05's; stdin not read" >&2
    return 3
  fi
  refuse_symlinks unpack-bundle "$KC_TARGET" "$OL_TARGET" "$STATE_DIR" || return
  cutover_lock unpack-bundle || return
  ver="$(state_value fetched version)"
  if [ ! -f "$STATE_DIR/fetched" ] || [ ! -f "$BUNDLE" ]; then
    echo "[ERROR] unpack-bundle: refused: no fetched bundle ($STATE_DIR/fetched and $BUNDLE); run fetch-bundle first; nothing changed" >&2
    return 3
  fi
  sum="$(file_sha256 "$BUNDLE")" || return 3
  if [ -z "$sum" ] || [ "$sum" != "$(state_value fetched sha256)" ]; then
    echo "[ERROR] unpack-bundle: refused: $BUNDLE's sha256 ($sum) is not the one fetch-bundle recorded; run cutover-clean and fetch-bundle again; nothing changed" >&2
    return 3
  fi
  if [ "$ver" != "m5-${m:0:12}" ]; then
    echo "[ERROR] unpack-bundle: refused: the fetched version ($ver) is not m5-${m:0:12} (MANIFESTS_SHA256's first 12 hex): a wrong bundle or a wrong relay; nothing changed" >&2
    return 3
  fi
  if [ -e "$STATE_DIR/unpacked" ]; then
    echo "[ERROR] unpack-bundle: refused: $STATE_DIR/unpacked exists (already unpacked); nothing changed" >&2
    return 3
  fi
  if [ -e "$STATE_DIR/unpack-started" ]; then
    echo "[ERROR] unpack-bundle: refused: $STATE_DIR/unpack-started exists without unpacked: a previous unpack did not finish: run reset-cutover; nothing changed" >&2
    return 3
  fi
  if ! target_empty "$KC_TARGET" || ! target_empty "$OL_TARGET"; then
    echo "[ERROR] unpack-bundle: refused: $KC_TARGET or $OL_TARGET is not empty (or cannot be listed); run reset-cutover; nothing changed" >&2
    return 3
  fi
  if ! docker image inspect "$CUTOVER_IMAGE" >/dev/null 2>&1 </dev/null; then
    echo "[ERROR] unpack-bundle: refused: $CUTOVER_IMAGE is not here; run fetch-bundle (it pulls the image); nothing changed" >&2
    return 3
  fi
  if [ -t 0 ]; then
    echo "[ERROR] unpack-bundle: refused: stdin is a terminal; unpack-bundle reads the age identity as one line on stdin (scripts/app_switch.sh writes it); nothing changed" >&2
    return 3
  fi
  { set +x; } 2>/dev/null
  set +a
  unset -v ident
  local +x ident=""
  IFS= builtin read -r ident || true
  exec </dev/null
  if [[ -z $ident ]]; then
    echo "[ERROR] unpack-bundle: refused: no identity read on stdin; nothing changed" >&2
    return 3
  fi
  # From here the targets may hold unpack's files: the marker that lets reset-cutover remove them.
  write_state unpack-started "version $ver" "manifests-sha256 $m" || { unset -v ident; return 1; }
  mkdir -p "$KC_TARGET" "$OL_TARGET" || { unset -v ident; return 1; }
  echo "[INFO] unpacking $BUNDLE ($ver) into $KC_TARGET and $OL_TARGET"
  # `builtin exec` in its own subshell: the docker program, never a function.
  out="$(builtin printf '%s\n' "$ident" \
    | (builtin exec docker run --rm -i --pull never --network none \
        -v "$BUNDLE:/in/bundle.tar.age:ro" \
        -v "$KC_TARGET:/dst/keycloak" \
        -v "$OL_TARGET:/dst/openldap" \
        "$CUTOVER_IMAGE" \
        unpack --expect-manifests-sha256 "$m" --expect-keycloak-summary "$k" --expect-openldap-summary "$o"))" || rc=$?
  unset -v ident
  case "$rc" in
    0) ;;
    2|3)
      # unpack changed nothing: with both targets still empty the start marker goes too.
      if target_empty "$KC_TARGET" && target_empty "$OL_TARGET"; then
        rm -f "$STATE_DIR/unpack-started" || return 1
        echo "[ERROR] unpack-bundle: unpack refused (exit $rc); nothing changed" >&2
      else
        echo "[ERROR] unpack-bundle: unpack refused (exit $rc), but a target is not empty: run reset-cutover before a retry" >&2
      fi
      return "$rc" ;;
    *)
      echo "[ERROR] unpack-bundle: unpack failed (exit $rc); the targets may hold files without STATUS: run reset-cutover before a retry" >&2
      return "$rc" ;;
  esac
  want="$(printf 'version %s\nmanifests-sha256 %s\nkeycloak-summary-sha256 %s\nopenldap-summary-sha256 %s' "$ver" "$m" "$k" "$o")"
  if [ "$out" != "$want" ]; then
    echo "[ERROR] unpack-bundle: unpack exited 0 but its four lines are not the fetched version and the three ARGs, in order; no unpacked marker; run reset-cutover" >&2
    printf '%s\n' "$out" | sed 's/^/[ERROR]   unpack said: /' >&2
    return 1
  fi
  printf '%s\n' "$out" | sed 's/^/[INFO] unpack: /'
  write_state unpacked "version $ver" "manifests-sha256 $m" "keycloak-summary-sha256 $k" "openldap-summary-sha256 $o"
}

# reset-cutover: undo an unpack (a failed one included: unpack-started without unpacked, files
# present) so that unpack-bundle can run again. It deletes only what an unpack wrote: with neither
# an unpack-started nor an unpacked marker it refuses (exit 3, nothing changed), unless both targets
# are empty already (a no-op, exit 0). Refused (exit 3, nothing changed) also on a replica, when a
# target or cutover-state/ is a symlink, the cutover lock is busy, cutover-done or a restored-*
# marker exists, or `compose --profile restored --profile ops ps -a -q openldap keycloak
# keycloak-backup openldap-backup` lists a container or fails: past a restore the targets are the
# restores' input, never emptied here. Then the unpacked marker goes first (a crash mid-delete
# leaves no unpacked over a partial target; unpack-started stays, so a reset can run again), each
# existing target is emptied but for lost+found by the pinned image's find (unpack's files are
# root-owned; --pull never, --network none), and once both are verified empty the unpack-started
# marker goes. The ciphertext and the fetched marker are kept. With the image missing: targets
# already empty succeed; a target holding files cannot be emptied here, so unpacked goes and it
# fails (exit 1, unpack-started kept): cutover-clean and fetch-bundle (it pulls the image), then
# again. Exit 1 too when a target is not empty afterwards.
do_reset_cutover() {
  local f ids d rc=0
  if [ $# -ne 0 ]; then
    echo "[ERROR] reset-cutover: usage: reset-cutover (no ARG)" >&2
    return 2
  fi
  if is_replica; then
    echo "[ERROR] reset-cutover: refused: not on a replica ($(hostname -s </dev/null)); the cutover is d05's; nothing changed" >&2
    return 3
  fi
  refuse_symlinks reset-cutover "$KC_TARGET" "$OL_TARGET" "$STATE_DIR" || return
  cutover_lock reset-cutover || return
  if [ -e "$STATE_DIR/$CUTOVER_DONE" ]; then
    echo "[ERROR] reset-cutover: refused: $STATE_DIR/$CUTOVER_DONE exists (the cutover is done); nothing changed" >&2
    return 3
  fi
  for f in "$STATE_DIR"/restored-*; do
    if [ -e "$f" ]; then
      echo "[ERROR] reset-cutover: refused: $f exists (a restore ran: the targets are its input); nothing changed" >&2
      return 3
    fi
  done
  if ! ids="$(run_compose --profile restored --profile ops ps -a -q openldap keycloak keycloak-backup openldap-backup </dev/null)"; then
    echo "[ERROR] reset-cutover: refused: docker compose ps for openldap, keycloak and the backup one-shots failed (cannot tell whether a restored or ops container exists); nothing changed" >&2
    return 3
  fi
  if [ -n "$ids" ]; then
    echo "[ERROR] reset-cutover: refused: an openldap, keycloak or backup one-shot container exists (the cutover is past its restore); nothing changed" >&2
    return 3
  fi
  if [ ! -e "$STATE_DIR/unpack-started" ] && [ ! -e "$STATE_DIR/unpacked" ]; then
    if target_empty "$KC_TARGET" && target_empty "$OL_TARGET"; then
      echo "[INFO] reset-cutover: no unpack-started or unpacked marker, and both targets are empty already; nothing to do"
      return 0
    fi
    echo "[ERROR] reset-cutover: refused: no unpack-started or unpacked marker in $STATE_DIR, so unpack-bundle did not write what $KC_TARGET or $OL_TARGET holds; nothing changed" >&2
    return 3
  fi
  if ! docker image inspect "$CUTOVER_IMAGE" >/dev/null 2>&1 </dev/null; then
    if target_empty "$KC_TARGET" && target_empty "$OL_TARGET"; then
      rm -f "$STATE_DIR/unpacked" || return 1
      rm -f "$STATE_DIR/unpack-started" || return 1
      echo "[INFO] reset-cutover: $CUTOVER_IMAGE is not here, and both targets are empty already; no unpacked or unpack-started marker"
      return 0
    fi
    rm -f "$STATE_DIR/unpacked" || return 1
    echo "[ERROR] reset-cutover: $CUTOVER_IMAGE is not here, so the root-owned files in the targets cannot be removed; the unpacked marker is gone; run cutover-clean and fetch-bundle VERSION (it pulls the image), then reset-cutover again" >&2
    return 1
  fi
  rm -f "$STATE_DIR/unpacked" || return 1
  for d in "$KC_TARGET" "$OL_TARGET"; do
    [ -d "$d" ] || continue
    docker run --rm --network none --pull never --entrypoint find -v "$d:/t" "$CUTOVER_IMAGE" \
      /t -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} + </dev/null || rc=$?
  done
  if ! target_empty "$KC_TARGET" || ! target_empty "$OL_TARGET"; then
    echo "[ERROR] reset-cutover: a target still holds files (find exit $rc): $KC_TARGET, $OL_TARGET; unpack-started kept (run reset-cutover again)" >&2
    return 1
  fi
  rm -f "$STATE_DIR/unpack-started" || return 1
  echo "[INFO] reset-cutover: $KC_TARGET and $OL_TARGET empty (lost+found kept), no unpacked or unpack-started marker; the bundle and the fetched marker kept"
}

# cutover-clean: the ciphertext, fetch-bundle's temp downloads (cutover/.bundle.*) and a temp
# fetched marker removed; the fetched marker is kept, because cutover_gate checks unpacked
# against it (a new fetch-bundle rewrites it); idempotent. A bundle can always be fetched again, so no marker
# gates it. Refused (exit 3) on a replica, with the cutover lock busy, and once cutover-done exists.
do_cutover_clean() {
  if [ $# -ne 0 ]; then
    echo "[ERROR] cutover-clean: usage: cutover-clean (no ARG)" >&2
    return 2
  fi
  if is_replica; then
    echo "[ERROR] cutover-clean: refused: not on a replica ($(hostname -s </dev/null)); the cutover is d05's; nothing changed" >&2
    return 3
  fi
  cutover_lock cutover-clean || return
  if [ -e "$STATE_DIR/$CUTOVER_DONE" ]; then
    echo "[ERROR] cutover-clean: refused: $STATE_DIR/$CUTOVER_DONE exists (the cutover is done); nothing changed" >&2
    return 3
  fi
  rm -f "$BUNDLE" "$CUT_DIR"/.bundle.* "$STATE_DIR"/.fetched.* || return 1
  echo "[INFO] cutover-clean: no $BUNDLE, no temp download; the fetched marker is kept"
}

# cutover_gate SWITCH: the markers a cutover switch needs; prints the missing or invalid ones and
# returns 3. unpacked counts only with a non-empty version equal to fetched's; a restored-* marker
# only when it is a non-empty file.
cutover_gate() {
  local m v fv need=() missing=()
  case "$1" in
    start-openldap) need=(unpacked restored-openldap) ;;
    start-keycloak) need=(unpacked restored-keycloak) ;;
    configure) need=(restored-openldap restored-keycloak) ;;
    *) echo "[ERROR] cutover_gate: no gate for $1" >&2; return 3 ;;
  esac
  for m in "${need[@]}"; do
    if [ ! -f "$STATE_DIR/$m" ]; then
      missing+=("$m")
    elif [ ! -s "$STATE_DIR/$m" ]; then
      missing+=("$m (empty)")
    elif [ "$m" = unpacked ]; then
      v="$(state_value unpacked version)" fv="$(state_value fetched version)"
      [ -n "$v" ] && [ "$v" = "$fv" ] || missing+=("unpacked (version '$v' is not fetched's '$fv')")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "[ERROR] $1: refused: cutover marker missing or invalid: ${missing[*]} (in $STATE_DIR); nothing done" >&2
    return 3
  fi
}

refuse_cutover() {
  echo "[ERROR] $1: M5 cutover, not yet written (theOrg identity-platform DEPLOY.md steps 5-6, after a restore); refused" >&2
  exit 3
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
    leaf-issue)
      do_leaf_issue || exit $?
      ;;
    leaf-renew)
      do_leaf_renew || exit $?
      ;;
    leaf-schedule-install)
      do_leaf_schedule_install
      ;;
    leaf-schedule-status)
      do_leaf_schedule_status
      ;;
    leaf-schedule-remove)
      do_leaf_schedule_remove
      ;;
    start-openldap|start-keycloak|configure)
      cutover_gate "$cmd" || exit $?
      refuse_cutover "$cmd"
      ;;
    restore)
      # Not 3: build_host.py reads exit 3 from a restore as "skipped, data present".
      echo "[ERROR] restore: refused: waiting on theOrg's B2a (keycloak_backup.sh PGPASSWORD on stdin) and identity-platform #86" >&2
      exit 1
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
  echo "  leaf-issue      - Issue the openldap leaf into openldap-tls (openldap-leaf.sh issue), before" >&2
  echo "                    openldap's first start; reads the provisioner password as one line on stdin" >&2
  echo "                    (from OpenBao, written by scripts/app_switch.sh; never an environment or a" >&2
  echo "                    file). Runs alone. Not on a replica" >&2
  echo "  leaf-renew      - openldap-leaf.sh renew: renew at half life, reload slapd; no secret. Not on a replica" >&2
  echo "  leaf-schedule-install - Install or update and enable $LEAF_UNIT.timer (leaf-renew every 3 hours)," >&2
  echo "                    after a successful leaf-issue; idempotent, run again after a template change;" >&2
  echo "                    only with the operator's approval of the schedule (DEPLOY.md item 13)" >&2
  echo "  leaf-schedule-status  - The timer, the service's last result and leaf-status.json (read-only)" >&2
  echo "  leaf-schedule-remove  - Disable and remove the timer and its service" >&2
  echo "  fetch-bundle VERSION - M5: pull the cutover-bundle image if missing and download the package's" >&2
  echo "                    bundle.tar.age to cutover/; reads the theorg-registry pull token as one line on" >&2
  echo "                    stdin (scripts/app_switch.sh). Runs alone. Not on a replica" >&2
  echo "  unpack-bundle MANIFESTS_SHA256 KC_SUM OL_SUM - M5: the image's unpack of the fetched bundle into" >&2
  echo "                    backup/ and openldap-backup/, checked against pack's three sha256 lines; reads" >&2
  echo "                    the age identity as one line on stdin (scripts/app_switch.sh). Runs alone. Not" >&2
  echo "                    on a replica" >&2
  echo "  reset-cutover   - M5: remove the unpacked marker, empty backup/ and openldap-backup/ (lost+found" >&2
  echo "                    kept), then the unpack-started marker, after a failed unpack; only what an" >&2
  echo "                    unpack wrote; refused past a restore or cutover-done. Runs alone. Not on a replica" >&2
  echo "  cutover-clean   - M5: remove cutover/bundle.tar.age and temp downloads (fetched kept);" >&2
  echo "                    refused once cutover-done. Runs alone. Not on a replica" >&2
  echo "  start-openldap, start-keycloak, configure" >&2
  echo "                  - Gated on the cutover markers (exit 3 naming the missing or invalid one); then refused:" >&2
  echo "                    the M5 cutover, not yet written (exit 3)" >&2
  echo "  restore         - Refused (exit 1): waiting on theOrg's B2a and identity-platform #86" >&2
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

# The cutover switches with ARGs run alone, first, and take the rest as their ARGs.
case "$1" in
  fetch-bundle)
    do_fetch_bundle "${@:2}" || exit $?
    exit 0
    ;;
  unpack-bundle)
    do_unpack_bundle "${@:2}" || exit $?
    exit 0
    ;;
  reset-cutover)
    do_reset_cutover "${@:2}" || exit $?
    exit 0
    ;;
  cutover-clean)
    do_cutover_clean "${@:2}" || exit $?
    exit 0
    ;;
esac

# leaf-issue runs alone: its stdin carries the provisioner password, and no other switch's
# children may run before it holding that pipe. So do the cutover switches (stdin or ARGs).
if [ $# -gt 1 ]; then
  for cmd in "$@"; do
    case "$cmd" in
      leaf-issue|fetch-bundle|unpack-bundle|reset-cutover|cutover-clean)
        echo "[ERROR] $cmd: refused: run it alone (it reads a value on stdin or takes ARGs), not with: $*" >&2
        exit 3
        ;;
    esac
  done
fi

# A switch that fails has said why; usage is only for an unknown switch (run_cmd) or none.
for cmd in "$@"; do
  run_cmd "$cmd" || exit 1
done
