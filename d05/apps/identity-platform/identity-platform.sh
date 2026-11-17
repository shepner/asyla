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
# openldap-data or openldap-config. configure runs only at the M5 cutover, behind the cutover gate
# (the cutover bundle, the two restores, the two starts, configure, count-check and cutover-done below are M5's
# switches); restore refuses and points at restore-openldap and restore-keycloak. Once cutover-done
# exists (on d05, never on a replica), up starts keycloak-db, openldap and keycloak together
# (`--profile restored up -d --wait`) and needs IDP_LDAP_ADMIN_PASSWORD as well as
# IDP_KEYCLOAK_DB_PASSWORD (exit 1, nothing started, without either: a compose run missing a value
# would recreate a container without it), and refuses (exit 1, nothing started) when openldap-data,
# openldap-config or keycloak-db is missing or empty (check_post_cutover_data); verify then checks
# all three. Before it, up and verify are M1's, and up ignores IDP_LDAP_ADMIN_PASSWORD. Whatever the
# switch, IDP_LDAP_ADMIN_PASSWORD is unset before any child runs; only post-cutover up's compose up
# gets the value (as LDAP_ADMIN_PASSWORD and LDAP_CONFIG_PASSWORD).
# No secret is in any file here or on the host. The workstation resolves the values from OpenBao
# at deploy (build_host.py start_env, pull_token_env) and hands them to this process's environment;
# this script maps them onto the names compose.yml passes by name. Only the long-running services
# (keycloak, keycloak-db, openldap) name a secret; every one-shot (configure, the backup and
# restore runs, break-glass) takes its value on stdin (theOrg bd0c6bff, the operator's rule of
# 2026-11-16), so map_secrets exports nothing a one-shot would read:
#   IDP_KEYCLOAK_DB_PASSWORD       -> KC_DB_PASSWORD (keycloak), POSTGRES_PASSWORD (keycloak-db);
#                                     up needs it. keycloak-backup takes it on stdin (restore-keycloak
#                                     reads it on this script's stdin), never PGPASSWORD.
#   IDP_LDAP_ADMIN_PASSWORD        -> LDAP_ADMIN_PASSWORD, LDAP_CONFIG_PASSWORD (openldap); up needs it
#                                     once cutover-done exists and ignores it before
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
#   restore-openldap  openldap-backup restore of openldap-backup/ into the empty openldap-data and
#               openldap-config, with OPENLDAP_BACKUP_CONFIG_MOUNT=rw for that run; no secret.
#   restore-keycloak  reads keycloak-db's password (IDP_KEYCLOAK_DB_PASSWORD, the name up reads) as
#               one line on stdin and writes it to keycloak-backup restore's stdin alone
#               (KEYCLOAK_BACKUP_PASSWORD_STDIN=1); keycloak-db must be running and healthy. It needs
#               asyla's theOrg pin repinned to theOrg's merged main: the fcbed3fe images' keycloak-backup
#               does not take its password on stdin.
#               Both need a valid unpacked marker; each is refused (exit 3, no docker run, nothing
#               changed) on a replica, once its own restored-* marker or cutover-done exists, and
#               when a target or cutover-state/ is a symlink. The restore's own exit (3: a target
#               not empty) passes through, with no marker.
#   A marker per step in cutover-state/: fetched; unpack-started (written right before unpack's
#   docker run: the targets then hold unpack's files); unpacked; restored-openldap and
#   restored-keycloak (date, the unpacked manifests-sha256) from the two restores; started-openldap
#   (date, admin-bind ok) and started-keycloak (date) from the two starts; configured (date, apply
#   ok, reconcile ok) from configure; cutover-done (date, the unpacked manifests-sha256) from the
#   cutover-done switch. Each is written atomically, then synced (sync -f). start-openldap,
#   start-keycloak and configure are gated on them (cutover_gate, exit 3 naming the missing or
#   invalid marker: an unpacked whose version is not fetched's, an empty restored-* or started-*,
#   a started-openldap without admin-bind ok).
#   configure  reads IDP_LDAP_ADMIN_PASSWORD's then IDP_DEPLOY_DEX_CLIENT_SECRET's value, one line
#               each on stdin, and writes both, as theOrg's LDAP_ADMIN_PASSWORD= and
#               VAULT_DEX_CLIENT_SECRET= lines, to keycloak-configure apply's stdin, then reconcile's
#               (DEPLOY.md cutover step 6 at bd0c6bff); needs both restored-* and both started-*
#               markers and keycloak healthy; re-runnable, after cutover-done too (DEPLOY.md: the
#               configuration steps are idempotent; past cutover-done refused, exit 3, when a data
#               dir is missing or empty, as up). It needs the repin (fcbed3fe's keycloak-configure
#               does not read stdin). Refused (exit 3, no docker run) with either name in the
#               environment, on a replica, a terminal or an empty read.
#   start-openldap  reads IDP_LDAP_ADMIN_PASSWORD's value as one line on stdin; it reaches the
#               compose process alone, as LDAP_ADMIN_PASSWORD and LDAP_CONFIG_PASSWORD, for
#               `--profile restored up -d --no-deps --wait --wait-timeout START_WAIT_S openldap`; then
#               an admin bind (ldapwhoami -y /dev/stdin through docker exec -i, the value on its
#               stdin). A failed bind: openldap left running, no marker, exit 1.
#   start-keycloak  the same for keycloak with IDP_KEYCLOAK_DB_PASSWORD's value as KC_DB_PASSWORD;
#               keycloak-db must be healthy, and started-openldap valid. Both refuse (exit 3, no
#               docker call) with the value's name in the environment, on a replica, past their own
#               started-* marker or cutover-done, a terminal or an empty read.
#   restore refuses (exit 1: never build_host.py's skip status 3)
#   and points at restore-openldap and restore-keycloak. reset-cutover and unpack-bundle refuse
#   (exit 3) when a target or cutover-state/ is a symlink.
#   THEORG_REGISTRY_PULL_TOKEN and IDP_CUTOVER_BUNDLE_IDENTITY are noted and unset at start, as
#   LDAP_PROVISIONER_PASSWORD is; fetch-bundle and unpack-bundle then refuse (exit 3);
#   restore-keycloak refuses (exit 3) with IDP_KEYCLOAK_DB_PASSWORD in its environment.
#   count-check  no value, no ARG (DEPLOY.md cutover step 7, Counts): keycloak-backup backup into
#               the emptied count-check/ (`run -v count-check:/backup`; keycloak-db's password from
#               the running container, as backup, on its stdin alone), then its summary.txt's realm,
#               users, clients and credentials lines (changesets ignored) compared with the Mini's
#               backup/summary.txt. Equal: writes counted (date, manifests-sha256, counts equal);
#               not equal: exit 1, both differing line sets printed. Refused (exit 3) on a replica,
#               a symlink, the lock busy, past cutover-done, unless unpacked, both restored-*, both
#               started-* and configured are valid.
#   cutover-done  no value, no ARG: the operator runs it after the cutover's verification. Refused
#               (exit 3, nothing written) on a replica, with the lock busy, unless every marker is
#               there and valid (cutover_gate: unpacked, both restored-*, both started-*,
#               configured with apply ok and reconcile ok, and counted with counts equal; both
#               restored-* and counted naming unpacked's manifests-sha256), and unless openldap and
#               keycloak are running and healthy. Writes cutover-done (date, manifests-sha256); past
#               it, prints that and exits 0. The eleven
#   cutover switches each run alone, and one at a time: each holds flock(1) (util-linux) -n on
#   cutover-state/.lock for its whole run; a busy lock is refused (exit 3).
# Data under /mnt/docker/IdentityPlatform. backup (host-maintenance's nightly task, once cutover-done
# exists; refused, exit 3, before it and on a replica): openldap-backup and keycloak-backup backup and
# verify, then both copies mirrored to /mnt/nas/data1/docker/IdentityPlatform/mirror (do_backup).

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
# IDP_LDAP_ADMIN_PASSWORD: only up past cutover-done takes it from the environment (build_host.py
# start_env); start-openldap and configure refuse while it is set (LDAP_ADMIN_IN_ENV). Note its
# presence; when up is among the switches, keep a private copy (never exported; xtrace off from here
# on in that run, as start-openldap's read does); then unset it before any child runs (dirname below
# included) or common.env is sourced. Only post-cutover up's docker compose up gets the value, under
# compose.yml's names (do_up).
LDAP_ADMIN_IN_ENV=false
LDAP_ADMIN_KEPT=""
if [ -n "${IDP_LDAP_ADMIN_PASSWORD+x}" ]; then
  LDAP_ADMIN_IN_ENV=true
  for sw_arg in "$@"; do
    if [ "$sw_arg" = up ]; then
      { set +x; } 2>/dev/null
      LDAP_ADMIN_KEPT="$IDP_LDAP_ADMIN_PASSWORD"
      break
    fi
  done
  unset sw_arg
fi
export -n LDAP_ADMIN_KEPT
unset IDP_LDAP_ADMIN_PASSWORD

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
# count-check's own keycloak-backup copy (DEPLOY.md cutover step 7), mounted over /backup for that run.
COUNT_DIR="$APP_ROOT/count-check"

# backup's nightly mirror (the operator's "Yes, mirror nightly", 2026-11-16): the NAS share
# (build/setup/nfs.sh mounts /mnt/nas/data1/docker on d05), one dir per copy; the stage is this
# user's readable copy of each, made by mirror-stage.sh in the copy's own image.
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"
MIRROR_DIR="$DOCKER_D1/IdentityPlatform/mirror"
MIRROR_STAGE="$APP_ROOT/mirror-stage"
MIRROR_STAGE_SCRIPT="$SCRIPT_DIR/mirror-stage.sh"

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
# start-openldap and start-keycloak: --wait-timeout for the restored service (asyla's addition, as up's).
START_WAIT_S="${IDENTITY_PLATFORM_START_WAIT_S:-300}"
# The admin DN (DEPLOY.md at bd0c6bff, "Verify" 1) start-openldap binds as.
LDAP_ADMIN_DN="cn=admin,dc=theorg,dc=local"

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

# up's mode, decided once, before any child runs: true on d05 once cutover-done exists (the three
# services), false otherwise (keycloak-db alone; always on a replica). Never re-read later in the
# same run, so a marker written meanwhile cannot start openldap without its value.
POST_CUTOVER=false
cutover_is_done() { [ -e "$STATE_DIR/$CUTOVER_DONE" ]; }

# up's values on d05: IDP_KEYCLOAK_DB_PASSWORD always; IDP_LDAP_ADMIN_PASSWORD once cutover-done
# exists (exit 1, nothing started, without it: LDAP_ADMIN_KEPT, the top's private copy), and dropped
# before it (M1 starts nothing that takes it). Presence only; never prints a value.
up_secrets() {
  require_db_secret
  if cutover_is_done; then
    if [ "${#LDAP_ADMIN_KEPT}" -eq 0 ]; then
      echo "[ERROR] IDP_LDAP_ADMIN_PASSWORD is not in this process's environment; past $STATE_DIR/$CUTOVER_DONE up starts openldap and keycloak too and needs it (build_host.py start_env, from OpenBao); not starting" >&2
      exit 1
    fi
    POST_CUTOVER=true
  else
    LDAP_ADMIN_KEPT=""
    POST_CUTOVER=false
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
  LDAP_ADMIN_KEPT=""
  unset IDP_DEPLOY_DEX_CLIENT_SECRET
  echo "[INFO] Replica of $SERVING_HOST ($(hostname -s)): keycloak-db with a throwaway password; openldap and keycloak never start"
}

# Exports only the names a long-running service lists (compose.yml). Never PGPASSWORD or
# VAULT_DEX_CLIENT_SECRET: their one-shots take the value on stdin. The LDAP names are not exported
# here: do_up's post-cutover compose up alone gets them, from LDAP_ADMIN_KEPT.
map_secrets() {
  if [ -n "${IDP_KEYCLOAK_DB_PASSWORD:-}" ]; then
    KC_DB_PASSWORD="$IDP_KEYCLOAK_DB_PASSWORD"
    POSTGRES_PASSWORD="$IDP_KEYCLOAK_DB_PASSWORD"
    export KC_DB_PASSWORD POSTGRES_PASSWORD
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

# keycloak-db's image, as compose.yml pins it (a test checks they are equal): every up pulls it
# (pull_missing), it does not follow theOrg's tag, and it has sh, ls and grep. The data check runs in it.
KC_DB_IMAGE="postgres:16.14-bookworm@sha256:64154d0babcb1741988719e703419af0382b19953706149f9872fbd0f438efa8"
POST_DATA_DIRS=(openldap-data openldap-config keycloak-db)

# Past cutover-done the three services start over the restored data: refuse when openldap-data,
# openldap-config or keycloak-db is missing or empty (lost+found aside), so that a lost or unmounted
# data dir never starts as a fresh, empty directory. The host check comes first: `docker run -v`
# would create a missing dir. Each dir is then listed read-only, as root (whatever its owner and
# mode), in keycloak-db's image: no pull, no network. Returns 1 when one fails.
check_post_cutover_data() {   # check_post_cutover_data WHO
  local who="$1" d dir rc
  for d in "${POST_DATA_DIRS[@]}"; do
    dir="$APP_ROOT/$d"
    if [ ! -d "$dir" ]; then
      echo "[ERROR] $who: refused: $dir is missing; past $STATE_DIR/$CUTOVER_DONE openldap and keycloak need their restored data; nothing started or changed" >&2
      return 1
    fi
    rc=0
    docker run --rm --pull never --network none --user 0:0 --entrypoint sh -v "$dir:/d:ro" "$KC_DB_IMAGE" \
      -c 'test -n "$(ls -A /d | grep -vx lost+found)"' </dev/null >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 1 ]; then
      echo "[ERROR] $who: refused: $dir is empty; past $STATE_DIR/$CUTOVER_DONE openldap and keycloak need their restored data; nothing started or changed" >&2
      return 1
    elif [ "$rc" -ne 0 ]; then
      echo "[ERROR] $who: refused: could not check that $dir holds data (docker run exited $rc); nothing started or changed" >&2
      return 1
    fi
  done
}

# M1: networks, images, the root CA, the leaf report, then keycloak-db alone, waited for until
# healthy. --no-deps and the one service name: nothing else starts, whatever its profile.
# POST_CUTOVER (up_secrets): the same, with the data check (check_post_cutover_data) before
# ensure_dirs, then keycloak-db, openldap and keycloak together (--profile restored, no ops
# one-shot), waited for START_WAIT_S, with map_secrets' exports and the LDAP names from
# LDAP_ADMIN_KEPT in that compose process's environment alone (its own subshell).
do_up() {
  ensure_networks || return
  pull_missing || return
  if [ "$POST_CUTOVER" = true ]; then
    check_post_cutover_data up || return 1
  fi
  ensure_dirs || return
  place_ca || return
  check_leaf
  if [ "$POST_CUTOVER" = true ]; then
    ( LDAP_ADMIN_PASSWORD="$LDAP_ADMIN_KEPT" LDAP_CONFIG_PASSWORD="$LDAP_ADMIN_KEPT"
      builtin export LDAP_ADMIN_PASSWORD LDAP_CONFIG_PASSWORD
      builtin exec docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" --profile restored \
        up -d --wait --wait-timeout "$START_WAIT_S" keycloak-db openldap keycloak ) || {
      echo "[ERROR] keycloak-db, openldap and keycloak did not all become healthy within ${START_WAIT_S}s" >&2
      return 1
    }
    echo "[INFO] keycloak-db, openldap and keycloak are healthy ($CUTOVER_DONE)"
    return 0
  fi
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

# Fatal: both networks as DEPLOY.md has them, the placed root CA, keycloak-db healthy; on d05 once
# cutover-done exists, openldap and keycloak healthy too. Reported: the openldap leaf.
do_verify() {
  local rc=0 got h svc
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
  if ! is_replica && cutover_is_done; then
    for svc in openldap keycloak; do
      h="$(restored_health "$svc")"
      if [ "$h" = healthy ]; then
        echo "[INFO] $svc healthy"
      else
        echo "[ERROR] $svc: $h ($CUTOVER_DONE exists)" >&2
        rc=1
      fi
    done
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
# unpacked (unpack's four lines); restored-openldap and restored-keycloak (date, manifests-sha256)
# from the restores; started-openldap and started-keycloak from the starts; configured from
# configure; cutover-done (date, manifests-sha256) from the cutover-done switch.
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

# The restores (DEPLOY.md "Production on d05", cutover step 5, at theOrg bd0c6bff): the unpacked
# copies (backup/ and openldap-backup/) into keycloak-db's empty database and openldap's empty data
# and config volumes, through theOrg's ops one-shots. restore_gate SWITCH MARKER: the refusals both
# share, each exit 3 with nothing changed: on a replica, a target or cutover-state/ a symlink, the
# cutover lock busy, no valid unpacked marker (cutover_gate; its manifests-sha256 a 64-hex too),
# MARKER (the switch's own restored-*) or cutover-done present. Exit 2 for an ARG. Sets
# RESTORE_MANIFESTS to the unpacked manifests-sha256. Never in a subshell: the lock is this
# shell's fd 9.
RESTORE_MANIFESTS=""
restore_gate() {   # restore_gate SWITCH MARKER [ARG...]
  local sw="$1" marker="$2" m
  shift 2
  RESTORE_MANIFESTS=""
  if [ $# -ne 0 ]; then
    echo "[ERROR] $sw: usage: $sw (no ARG)" >&2
    return 2
  fi
  if is_replica; then
    echo "[ERROR] $sw: refused: not on a replica ($(hostname -s </dev/null)); the cutover is d05's; nothing changed" >&2
    return 3
  fi
  refuse_symlinks "$sw" "$KC_TARGET" "$OL_TARGET" "$STATE_DIR" || return
  cutover_lock "$sw" || return
  cutover_gate "$sw" || return
  m="$(state_value unpacked manifests-sha256)"
  if [[ ! $m =~ $SHA256_RE ]]; then
    echo "[ERROR] $sw: refused: cutover marker missing or invalid: unpacked (manifests-sha256 '$m' is not 64 hex) (in $STATE_DIR); nothing done" >&2
    return 3
  fi
  if [ -e "$STATE_DIR/$marker" ]; then
    echo "[ERROR] $sw: refused: $STATE_DIR/$marker exists (already restored; the target is no longer empty); nothing changed" >&2
    return 3
  fi
  if [ -e "$STATE_DIR/$CUTOVER_DONE" ]; then
    echo "[ERROR] $sw: refused: $STATE_DIR/$CUTOVER_DONE exists (the cutover is done); nothing changed" >&2
    return 3
  fi
  RESTORE_MANIFESTS="$m"
}

# restore_done SWITCH MARKER MANIFESTS RC: on 0 the marker (date, the unpacked manifests-sha256);
# otherwise no marker and RC returned (the restore's own exit: 3 its refusal of a target that is not
# empty, 2 a usage or mount problem, 1 a failure).
restore_done() {
  if [ "$4" -ne 0 ]; then
    echo "[ERROR] $1: the restore exited $4 (3: it refused a target that is not empty or, for keycloak, the stdin value; 2: a mount or usage problem; 1: it failed); no $2 marker" >&2
    return "$4"
  fi
  write_state "$2" "date $(date -u +%Y-%m-%dT%H:%M:%SZ </dev/null)" "manifests-sha256 $3"
}

# restore-keycloak: keycloak-backup restore of backup/ into keycloak-db's empty database. The
# database password is one line on this script's stdin (scripts/app_switch.sh writes it; the same
# name up reads, IDP_KEYCLOAK_DB_PASSWORD), read as leaf-issue reads its value, and goes to the
# one-shot on its stdin alone, in the contract's form (KEYCLOAK_BACKUP_PASSWORD_STDIN=1; never
# PGPASSWORD, an argv, a file or a log). Refused (exit 3, no docker run, nothing changed) with
# IDP_KEYCLOAK_DB_PASSWORD in the environment (checked before any child runs), restore_gate's
# refusals, keycloak-db not running and healthy, a terminal on stdin or an empty read.
do_restore_keycloak() {
  local sw=restore-keycloak h rc=0
  if [ -n "${IDP_KEYCLOAK_DB_PASSWORD+x}" ]; then
    echo "[ERROR] $sw: refused: IDP_KEYCLOAK_DB_PASSWORD is set in the environment; unset it and write the value as one line to $sw's stdin (scripts/app_switch.sh does); nothing changed" >&2
    return 3
  fi
  restore_gate "$sw" restored-keycloak "$@" || return
  h="$(db_health </dev/null)"
  if [ "$h" != healthy ]; then
    echo "[ERROR] $sw: refused: keycloak-db is $h, not running and healthy (run up first); nothing changed" >&2
    return 3
  fi
  if [ -t 0 ]; then
    echo "[ERROR] $sw: refused: stdin is a terminal; $sw reads keycloak-db's password as one line on stdin (scripts/app_switch.sh writes it); nothing changed" >&2
    return 3
  fi
  { set +x; } 2>/dev/null
  set +a
  unset -v pw
  local +x pw=""
  IFS= builtin read -r pw || true
  exec </dev/null
  if [[ -z $pw ]]; then
    echo "[ERROR] $sw: refused: no database password read on stdin; nothing changed" >&2
    return 3
  fi
  echo "[INFO] $sw: keycloak-backup restore of $KC_TARGET into keycloak-db"
  # run_compose's argv, with `builtin exec docker` in its own subshell: the docker program, never a
  # function (a common.env function named docker would otherwise get the value on its stdin).
  builtin printf '%s\n' "$pw" \
    | (builtin exec docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" \
        --profile ops run --rm -T -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup restore) || rc=$?
  unset -v pw
  restore_done "$sw" restored-keycloak "$RESTORE_MANIFESTS" "$rc"
}

# restore-openldap: openldap-backup restore of openldap-backup/ into openldap's empty data and config
# volumes. No secret (theOrg's openldap_backup.sh reads none; the admin password is then the copy's).
# The restore writes the config volume, which compose.yml mounts read-only unless
# OPENLDAP_BACKUP_CONFIG_MOUNT=rw (DEPLOY.md step 5's form), so that one value is set for this run.
# Refused (exit 3) by restore_gate's refusals; keycloak-db need not run. stdin is /dev/null.
do_restore_openldap() {
  local sw=restore-openldap rc=0
  restore_gate "$sw" restored-openldap "$@" || return
  echo "[INFO] $sw: openldap-backup restore of $OL_TARGET into openldap-data and openldap-config"
  ( export OPENLDAP_BACKUP_CONFIG_MOUNT=rw; run_compose --profile ops run --rm -T openldap-backup restore ) </dev/null || rc=$?
  restore_done "$sw" restored-openldap "$RESTORE_MANIFESTS" "$rc"
}

# start-openldap and start-keycloak (DEPLOY.md "Production on d05", cutover steps 5-6, at theOrg
# bd0c6bff): `--profile restored up -d --no-deps --wait SERVICE` over the restored data, with
# --wait-timeout START_WAIT_S (IDENTITY_PLATFORM_START_WAIT_S, default 300; asyla's, as up's). The
# value (start-openldap: IDP_LDAP_ADMIN_PASSWORD; start-keycloak: IDP_KEYCLOAK_DB_PASSWORD) is one
# line on this script's stdin (scripts/app_switch.sh writes it), read as leaf-issue reads its value,
# and reaches the docker compose process alone, in its environment under the names compose.yml
# passes by name (LDAP_ADMIN_PASSWORD and LDAP_CONFIG_PASSWORD; KC_DB_PASSWORD): never an argv, a
# file or a log. start-openldap then checks an admin bind with it (step 5: the admin password is
# then the copy's) in theOrg's stdin form (scripts/rotate_ldap_admin_lab.py at bd0c6bff):
# ldapwhoami -y /dev/stdin in the container through docker exec -i, the value on its stdin with no
# newline, as that lab sends it. A failed bind leaves openldap running, writes no marker and exits
# 1. On success each writes its started-* marker (date; start-openldap also "admin-bind ok").
# Refused (exit 3, no docker call, nothing changed) with the value's name in the environment
# (checked before any child runs), on a replica, cutover-state/ a symlink, the lock busy, a missing
# or invalid marker (cutover_gate; start-keycloak needs started-openldap too), its own started-*
# marker or cutover-done present, keycloak-db not running and healthy (start-keycloak), a terminal
# on stdin or an empty read. Exit 2 for an ARG; 1 when the service does not become healthy.
do_start() {   # do_start SWITCH VALUE_NAME SERVICE MARKER [ARG...]
  local sw="$1" name="$2" svc="$3" marker="$4" h id rc=0 in_env=false
  shift 4
  # IDP_LDAP_ADMIN_PASSWORD is unset at the top; its presence is LDAP_ADMIN_IN_ENV.
  if [ "$name" = IDP_LDAP_ADMIN_PASSWORD ]; then in_env="$LDAP_ADMIN_IN_ENV"
  elif [ -n "${!name+x}" ]; then in_env=true; fi
  if [ "$in_env" = true ]; then
    echo "[ERROR] $sw: refused: $name is set in the environment; unset it and write the value as one line to $sw's stdin (scripts/app_switch.sh does); nothing changed" >&2
    return 3
  fi
  if [ $# -ne 0 ]; then
    echo "[ERROR] $sw: usage: $sw (no ARG)" >&2
    return 2
  fi
  if is_replica; then
    echo "[ERROR] $sw: refused: not on a replica ($(hostname -s </dev/null)); the cutover is d05's; nothing changed" >&2
    return 3
  fi
  cutover_lock "$sw" || return
  cutover_gate "$sw" || return
  if [ -e "$STATE_DIR/$marker" ]; then
    echo "[ERROR] $sw: refused: $STATE_DIR/$marker exists (already started); nothing changed" >&2
    return 3
  fi
  if [ -e "$STATE_DIR/$CUTOVER_DONE" ]; then
    echo "[ERROR] $sw: refused: $STATE_DIR/$CUTOVER_DONE exists (the cutover is done); nothing changed" >&2
    return 3
  fi
  if [ "$svc" = keycloak ]; then
    h="$(db_health </dev/null)"
    if [ "$h" != healthy ]; then
      echo "[ERROR] $sw: refused: keycloak-db is $h, not running and healthy (run up first); nothing changed" >&2
      return 3
    fi
  fi
  if [ -t 0 ]; then
    echo "[ERROR] $sw: refused: stdin is a terminal; $sw reads $name's value as one line on stdin (scripts/app_switch.sh writes it); nothing changed" >&2
    return 3
  fi
  { set +x; } 2>/dev/null
  set +a
  unset -v pw
  local +x pw=""
  IFS= builtin read -r pw || true
  exec </dev/null
  if [[ -z $pw ]]; then
    echo "[ERROR] $sw: refused: no value read on stdin; nothing changed" >&2
    return 3
  fi
  echo "[INFO] $sw: starting $svc (--profile restored, --no-deps; healthy within ${START_WAIT_S}s)"
  # run_compose's argv, with `builtin exec docker` in its own subshell: the docker program, never a
  # function; the value only in that subshell's environment.
  if [ "$svc" = openldap ]; then
    ( LDAP_ADMIN_PASSWORD="$pw" LDAP_CONFIG_PASSWORD="$pw"
      builtin export LDAP_ADMIN_PASSWORD LDAP_CONFIG_PASSWORD
      builtin exec docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" --profile restored \
        up -d --no-deps --wait --wait-timeout "$START_WAIT_S" openldap ) || rc=$?
  else
    ( KC_DB_PASSWORD="$pw"
      builtin export KC_DB_PASSWORD
      builtin exec docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" --profile restored \
        up -d --no-deps --wait --wait-timeout "$START_WAIT_S" keycloak ) || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    unset -v pw
    echo "[ERROR] $sw: $svc did not start and become healthy within ${START_WAIT_S}s (docker compose exited $rc); no $marker marker" >&2
    return 1
  fi
  if [ "$svc" = keycloak ]; then
    unset -v pw
    write_state "$marker" "date $(date -u +%Y-%m-%dT%H:%M:%SZ </dev/null)"
    return
  fi
  id="$(run_compose --profile restored ps -q openldap </dev/null)" || id=""
  if [ -z "$id" ]; then
    unset -v pw
    echo "[ERROR] $sw: openldap's container not found after the start; admin bind not checked; no $marker marker" >&2
    return 1
  fi
  builtin printf '%s' "$pw" \
    | (builtin exec docker exec -i "$id" ldapwhoami -x -H ldaps://localhost:636 -D "$LDAP_ADMIN_DN" -y /dev/stdin) || rc=$?
  unset -v pw
  if [ "$rc" -ne 0 ]; then
    echo "[ERROR] $sw: the admin bind as $LDAP_ADMIN_DN failed (ldapwhoami exited $rc; 49: the restored copy's admin password is not OpenBao's IDP_LDAP_ADMIN_PASSWORD); openldap left running; no $marker marker" >&2
    return 1
  fi
  write_state "$marker" "date $(date -u +%Y-%m-%dT%H:%M:%SZ </dev/null)" "admin-bind ok"
}
do_start_openldap() { do_start start-openldap IDP_LDAP_ADMIN_PASSWORD openldap started-openldap "$@"; }
do_start_keycloak() { do_start start-keycloak IDP_KEYCLOAK_DB_PASSWORD keycloak started-keycloak "$@"; }

# keycloak's health, as db_health's (keycloak is in profile restored, so ps names it).
kc_health() { restored_health keycloak; }
# restored_health SERVICE: openldap's or keycloak's health, as db_health's.
restored_health() {
  local id
  id="$(run_compose --profile restored ps -q "$1" 2>/dev/null)" || id=""
  [ -n "$id" ] || { echo "not running"; return 0; }
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' "$id" 2>/dev/null || echo "unknown"
}

# configure (DEPLOY.md "Production on d05", cutover step 6, at theOrg bd0c6bff): keycloak-configure
# apply, then reconcile; no ensure or bootstrap (the restored copy carries the realm and its client).
# Two values, one line each on this script's stdin in this order (scripts/app_switch.sh writes them,
# switch_env's order): IDP_LDAP_ADMIN_PASSWORD's, then IDP_DEPLOY_DEX_CLIENT_SECRET's, each read as
# leaf-issue reads its value. Each run gets both on its stdin alone, in theOrg's form (DEPLOY.md
# "Secrets on stdin only"; scripts/keycloak_realm.py read_network_secrets: one line per name, the
# name, an equals sign and the value, for LDAP_ADMIN_PASSWORD and VAULT_DEX_CLIENT_SECRET; no env
# flag), written by builtin printf: never an
# argv, an environment, a file or a log. compose.yml passes no secret by name to interpolate, so the
# compose process needs neither. Refused (exit 3, no docker run, nothing changed) with either name
# in the environment (checked before any child runs), on a replica, cutover-state/ a symlink, the
# lock busy, a missing or invalid marker (cutover_gate: both restored-* and both started-*),
# keycloak not running and healthy, a terminal on stdin or an empty read of either line. Exit 2 for
# an ARG. Not refused past its own configured marker or cutover-done: DEPLOY.md ("Updating", step 4)
# says the configuration steps are idempotent and are re-run after an update, and after a directory
# restore ("re-run the configuration reconcile steps"). An apply that fails skips reconcile; either
# failing returns its exit (3: keycloak-configure refused its stdin or settings) with no marker.
# On both 0 writes configured (date, apply ok, reconcile ok). It needs the repin: fcbed3fe's
# keycloak-configure image does not read its secrets on stdin.
do_configure() {
  local sw=configure n h cmd rc=0
  for n in IDP_LDAP_ADMIN_PASSWORD IDP_DEPLOY_DEX_CLIENT_SECRET; do
    # IDP_LDAP_ADMIN_PASSWORD is unset at the top; its presence is LDAP_ADMIN_IN_ENV.
    if { [ "$n" = IDP_LDAP_ADMIN_PASSWORD ] && $LDAP_ADMIN_IN_ENV; } || [ -n "${!n+x}" ]; then
      echo "[ERROR] $sw: refused: $n is set in the environment; unset it and write the two values as one line each to $sw's stdin (scripts/app_switch.sh does); nothing changed" >&2
      return 3
    fi
  done
  if [ $# -ne 0 ]; then
    echo "[ERROR] $sw: usage: $sw (no ARG)" >&2
    return 2
  fi
  if is_replica; then
    echo "[ERROR] $sw: refused: not on a replica ($(hostname -s </dev/null)); the cutover is d05's; nothing changed" >&2
    return 3
  fi
  cutover_lock "$sw" || return
  cutover_gate "$sw" || return
  if [ -e "$STATE_DIR/$CUTOVER_DONE" ]; then
    echo "[INFO] $sw: $STATE_DIR/$CUTOVER_DONE exists: a re-run after the cutover (apply and reconcile are idempotent)"
    check_post_cutover_data "$sw" || return 3
  fi
  h="$(kc_health </dev/null)"
  if [ "$h" != healthy ]; then
    echo "[ERROR] $sw: refused: keycloak is $h, not running and healthy (start-keycloak first); nothing changed" >&2
    return 3
  fi
  if [ -t 0 ]; then
    echo "[ERROR] $sw: refused: stdin is a terminal; $sw reads IDP_LDAP_ADMIN_PASSWORD's and IDP_DEPLOY_DEX_CLIENT_SECRET's values as one line each on stdin (scripts/app_switch.sh writes them); nothing changed" >&2
    return 3
  fi
  { set +x; } 2>/dev/null
  set +a
  unset -v ldap dex
  local +x ldap="" dex=""
  IFS= builtin read -r ldap || true
  IFS= builtin read -r dex || true
  exec </dev/null
  if [[ -z $ldap ]]; then
    unset -v ldap dex
    echo "[ERROR] $sw: refused: no IDP_LDAP_ADMIN_PASSWORD value read on stdin (line 1); nothing changed" >&2
    return 3
  fi
  if [[ -z $dex ]]; then
    unset -v ldap dex
    echo "[ERROR] $sw: refused: no IDP_DEPLOY_DEX_CLIENT_SECRET value read on stdin (line 2); nothing changed" >&2
    return 3
  fi
  for cmd in apply reconcile; do
    echo "[INFO] $sw: keycloak-configure $cmd"
    # run_compose's argv, with `builtin exec docker` in its own subshell: the docker program, never a
    # function (a common.env function named docker would otherwise get the values on its stdin).
    builtin printf 'LDAP_ADMIN_PASSWORD=%s\nVAULT_DEX_CLIENT_SECRET=%s\n' "$ldap" "$dex" \
      | (builtin exec docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" \
          --profile ops run --rm -T keycloak-configure "$cmd") || rc=$?
    if [ "$rc" -ne 0 ]; then
      unset -v ldap dex
      echo "[ERROR] $sw: keycloak-configure $cmd exited $rc (3: it refused its stdin or a setting; 1: it failed)$([ "$cmd" = apply ] && echo '; reconcile not run'); no configured marker" >&2
      return "$rc"
    fi
  done
  unset -v ldap dex
  write_state configured "date $(date -u +%Y-%m-%dT%H:%M:%SZ </dev/null)" "apply ok" "reconcile ok"
}

# cutover-done: the go-live record, run by the operator after the cutover's verification (DEPLOY.md
# step 8). No value, no ARG (exit 2). Refused (exit 3, nothing written) on a replica, cutover-state/
# a symlink, the lock busy, a missing or invalid marker (cutover_gate: unpacked, both restored-*,
# both started-*, configured and counted), an unpacked manifests-sha256 that is not 64 hex or a
# restored-* or counted naming another, and openldap or keycloak not running and healthy. Past an existing cutover-done:
# says so, exit 0, nothing written. Writes cutover-done (date, manifests-sha256): up then starts
# all three services and needs both values; the restores, starts, reset-cutover and cutover-clean
# refuse.
do_cutover_done() {
  local sw=cutover-done m f h svc
  if [ $# -ne 0 ]; then
    echo "[ERROR] $sw: usage: $sw (no ARG)" >&2
    return 2
  fi
  if is_replica; then
    echo "[ERROR] $sw: refused: not on a replica ($(hostname -s </dev/null)); the cutover is d05's; nothing changed" >&2
    return 3
  fi
  cutover_lock "$sw" || return
  if [ -e "$STATE_DIR/$CUTOVER_DONE" ]; then
    echo "[INFO] $sw: $STATE_DIR/$CUTOVER_DONE exists already (date $(state_value "$CUTOVER_DONE" date)); nothing changed"
    return 0
  fi
  cutover_gate "$sw" || return
  m="$(state_value unpacked manifests-sha256)"
  if [[ ! $m =~ $SHA256_RE ]]; then
    echo "[ERROR] $sw: refused: cutover marker missing or invalid: unpacked (manifests-sha256 '$m' is not 64 hex) (in $STATE_DIR); nothing done" >&2
    return 3
  fi
  for f in restored-openldap restored-keycloak counted; do
    if [ "$(state_value "$f" manifests-sha256)" != "$m" ]; then
      echo "[ERROR] $sw: refused: cutover marker missing or invalid: $f (its manifests-sha256 is not unpacked's) (in $STATE_DIR); nothing done" >&2
      return 3
    fi
  done
  for svc in openldap keycloak; do
    h="$(restored_health "$svc" </dev/null)"
    if [ "$h" != healthy ]; then
      echo "[ERROR] $sw: refused: $svc is $h, not running and healthy; nothing changed" >&2
      return 3
    fi
  done
  write_state "$CUTOVER_DONE" "date $(date -u +%Y-%m-%dT%H:%M:%SZ </dev/null)" "manifests-sha256 $m" || return 1
  echo "[INFO] $sw: recorded; up now starts keycloak-db, openldap and keycloak and needs IDP_KEYCLOAK_DB_PASSWORD and IDP_LDAP_ADMIN_PASSWORD"
}

# count-check: DEPLOY.md cutover step 7, Counts (theOrg bd0c6bff): keycloak-backup backup on d05 into
# its empty count-check/, then its summary.txt compared with the Mini's (backup/summary.txt, from the
# bundle): the realm names, and per realm the users, the clients and the credentials by type must be
# equal. Only the `realm`, `users`, `clients` and `credentials` lines count, compared LC_ALL=C sorted;
# `changesets` (Liquibase's count, which differs across Keycloak versions; step 7 does not name it)
# and any other line are ignored. No value, no ARG (exit 2); no stdin is read. keycloak-db's
# password is the running container's own (kc_db_password, as backup), on keycloak-backup backup's
# stdin alone; `run -v count-check:/backup` replaces the service's backup/ mount for that run (Compose
# v5.7.0, checked on ws01), so backup/ is never written. count-check/ is emptied first (its files are
# root-owned: find in keycloak-db's image, --pull never, --network none, as reset-cutover) and both
# summaries are read through that image, read-only. Refused (exit 3, nothing changed) on a replica,
# count-check/, a target or cutover-state/ a symlink, the lock busy, past cutover-done, and on a
# missing or invalid marker (cutover_gate: unpacked, both restored-*, both started-* and configured).
# Equal: writes counted (date, the unpacked manifests-sha256, counts equal), which cutover-done
# needs; exit 0. Not equal: exit 1, both differing line sets printed (counts, not secrets), no marker.
# The backup failing: its exit, no marker. count-check/ not emptied, keycloak-db's password not
# taken, or a summary unreadable or without a realm line: exit 1, no marker. Re-runnable until
# cutover-done; past the refusals a run first removes an existing counted.
do_count_check() {
  local sw=count-check m rc=0 mini new
  { set +x; } 2>/dev/null
  set +a
  unset -v pw
  local +x pw=""
  if [ $# -ne 0 ]; then
    echo "[ERROR] $sw: usage: $sw (no ARG)" >&2
    return 2
  fi
  if is_replica; then
    echo "[ERROR] $sw: refused: not on a replica ($(hostname -s </dev/null)); the cutover is d05's; nothing changed" >&2
    return 3
  fi
  refuse_symlinks "$sw" "$COUNT_DIR" "$KC_TARGET" "$OL_TARGET" "$STATE_DIR" || return
  cutover_lock "$sw" || return
  if [ -e "$STATE_DIR/$CUTOVER_DONE" ]; then
    echo "[ERROR] $sw: refused: $STATE_DIR/$CUTOVER_DONE exists (the cutover is done; backup/ may hold a nightly copy, not the Mini's); nothing changed" >&2
    return 3
  fi
  cutover_gate "$sw" || return
  m="$(state_value unpacked manifests-sha256)"
  if [[ ! $m =~ $SHA256_RE ]]; then
    echo "[ERROR] $sw: refused: cutover marker missing or invalid: unpacked (manifests-sha256 '$m' is not 64 hex) (in $STATE_DIR); nothing done" >&2
    return 3
  fi

  rm -f "$STATE_DIR/counted" || return 1
  mkdir -p "$COUNT_DIR" || return 1
  if ! target_empty "$COUNT_DIR"; then
    docker run --rm --network none --pull never --user 0:0 --entrypoint find -v "$COUNT_DIR:/t" "$KC_DB_IMAGE" \
      /t -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} + </dev/null || rc=$?
    if ! target_empty "$COUNT_DIR"; then
      echo "[ERROR] $sw: $COUNT_DIR still holds files (find exit $rc); no backup run, no counted marker" >&2
      return 1
    fi
  fi

  echo "[INFO] $sw: keycloak-backup backup into $COUNT_DIR (keycloak-db's password on its stdin)"
  kc_db_password "$sw" || { echo "[ERROR] $sw: no backup run, no counted marker" >&2; return 1; }
  rc=0
  # run_compose's argv, with `builtin exec docker` in its own subshell, as do_backup.
  builtin printf '%s\n' "$pw" \
    | (builtin exec docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" \
        --profile ops run --rm -T -v "$COUNT_DIR:/backup" -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup backup) || rc=$?
  pw=""
  unset -v pw
  if [ "$rc" -ne 0 ]; then
    echo "[ERROR] $sw: keycloak-backup backup exited $rc; no counted marker" >&2
    return "$rc"
  fi

  if ! mini="$(count_lines "$KC_TARGET")" || ! grep -q '^realm ' <<<"$mini"; then
    echo "[ERROR] $sw: could not read a realm line from the Mini's $KC_TARGET/summary.txt; no counted marker" >&2
    return 1
  fi
  if ! new="$(count_lines "$COUNT_DIR")" || ! grep -q '^realm ' <<<"$new"; then
    echo "[ERROR] $sw: could not read a realm line from d05's $COUNT_DIR/summary.txt; no counted marker" >&2
    return 1
  fi
  if [ "$mini" != "$new" ]; then
    {
      echo "[ERROR] $sw: the counts differ (realm, users, clients, credentials lines; changesets ignored); no counted marker"
      echo "  only in the Mini's $KC_TARGET/summary.txt:"
      LC_ALL=C comm -23 <(printf '%s\n' "$mini") <(printf '%s\n' "$new") | sed 's/^/    /'
      echo "  only in d05's $COUNT_DIR/summary.txt:"
      LC_ALL=C comm -13 <(printf '%s\n' "$mini") <(printf '%s\n' "$new") | sed 's/^/    /'
    } >&2
    return 1
  fi
  write_state counted "date $(date -u +%Y-%m-%dT%H:%M:%SZ </dev/null)" "manifests-sha256 $m" "counts equal" || return 1
  echo "[INFO] $sw: the realm names and each realm's users, clients and credentials by type are equal ($(grep -c '^realm ' <<<"$new") realm(s)); next: cutover-done"
}

# count_lines DIR: DIR/summary.txt read as root through keycloak-db's image (read-only, no pull, no
# network), its realm, users, clients and credentials lines LC_ALL=C sorted; returns 1 when unread.
count_lines() {
  local out
  out="$(docker run --rm --pull never --network none --user 0:0 --entrypoint cat -v "$1:/s:ro" "$KC_DB_IMAGE" /s/summary.txt </dev/null)" || return 1
  printf '%s\n' "$out" | { grep -E '^(realm|users|clients|credentials) ' || true; } | LC_ALL=C sort
}

# backup (asyla #654 unit D; the operator's "Yes, mirror nightly", 2026-11-16). host-maintenance's
# nightly backup task runs `identity-platform.sh backup` (it looks for run_cmd's `backup)` line)
# with stdin /dev/null and MAINT_FOREGROUND=1, blocks until it exits and reads only the exit: 0
# counts as a fresh backup. So 0 only when all three steps passed, in this order (theOrg DEPLOY.md
# at bd0c6bff, "Production on d05": Backup; "Keycloak: backup, restore and verify"; "Directory:
# backup, restore and verify"):
#   1. openldap-backup backup, then verify (no secret);
#   2. keycloak-backup backup with keycloak-db's password on its stdin alone
#      (-T -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1), then verify (theOrg: verify needs no password);
#   3. each copy mirrored to the NAS (mirror_copy).
# A failed step exits 1 naming it; the steps after it are skipped. The password is the running
# keycloak-db's own POSTGRES_PASSWORD (kc_db_password), as communications.sh's pg_password takes
# comms-postgres's: the nightly run gets no value. Refused (exit 3, nothing run or written: never
# 0, so a run before the data is d05's cannot count as a fresh backup) on a replica, before
# cutover-done exists, when backup/, openldap-backup/, mirror-stage/ or cutover-state/ is a symlink,
# and when the cutover lock is busy. The lock is cutover_lock (exclusive, -n), as the cutover
# switches take it: no configure, restore or other backup runs meanwhile, and a second backup is
# refused here (3) rather than by theOrg's own /backup/.lock (1). Runs alone. No stdin is read. It
# needs the repin to theOrg's merged main: fcbed3fe's keycloak-backup does not read stdin.
do_backup() {
  local sw=backup rc=0 id n
  { set +x; } 2>/dev/null
  set +a
  unset -v pw
  local +x pw=""
  if is_replica; then
    echo "[ERROR] $sw: refused: not on a replica ($(hostname -s </dev/null)); a replica's copy is not d05's and its NAS shares are read-only; nothing done" >&2
    return 3
  fi
  if ! cutover_is_done; then
    echo "[ERROR] $sw: refused: no $STATE_DIR/$CUTOVER_DONE yet; the data is the Mini's until the M5 cutover is done; nothing done" >&2
    return 3
  fi
  refuse_symlinks "$sw" "$KC_TARGET" "$OL_TARGET" "$MIRROR_STAGE" "$MIRROR_STAGE/openldap" "$MIRROR_STAGE/keycloak" || return
  cutover_lock "$sw" || return

  echo "[INFO] $sw: step 1: openldap-backup backup, then verify"
  run_compose --profile ops run --rm -T openldap-backup backup </dev/null || { backup_failed 1 "openldap-backup backup" $?; return 1; }
  run_compose --profile ops run --rm -T openldap-backup verify </dev/null || { backup_failed 1 "openldap-backup verify" $?; return 1; }

  echo "[INFO] $sw: step 2: keycloak-backup backup (keycloak-db's password on its stdin), then verify"
  kc_db_password "$sw" || { backup_failed 2 "keycloak-db's password" 1; return 1; }
  # run_compose's argv, with `builtin exec docker` in its own subshell: the docker program, never a
  # function (a common.env function named docker would otherwise get the value on its stdin).
  builtin printf '%s\n' "$pw" \
    | (builtin exec docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" \
        --profile ops run --rm -T -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup backup) || rc=$?
  pw=""
  unset -v pw
  [ "$rc" -eq 0 ] || { backup_failed 2 "keycloak-backup backup" "$rc"; return 1; }
  run_compose --profile ops run --rm -T keycloak-backup verify </dev/null || { backup_failed 2 "keycloak-backup verify" $?; return 1; }

  echo "[INFO] $sw: step 3: mirror both copies to $MIRROR_DIR"
  if ! mountpoint -q "$DOCKER_D1" </dev/null; then
    echo "[ERROR] $sw: $DOCKER_D1 is not a mount point (the NAS share is not mounted); not mirroring" >&2
    backup_failed 3 "mirror" 1
    return 1
  fi
  for n in openldap keycloak; do
    mirror_copy "$n" || { backup_failed 3 "mirror of $n" 1; return 1; }
  done
  echo "[INFO] $sw: done: both copies backed up, verified and mirrored to $MIRROR_DIR"
}

backup_failed() {   # backup_failed STEP NAME EXIT
  echo "[ERROR] backup: step $1 failed: $2 (exit $3); the steps after it were skipped; not a fresh backup" >&2
}

# kc_db_password: sets do_backup's local pw to the running keycloak-db container's POSTGRES_PASSWORD.
# docker inspect's template matches that one Config.Env entry by name and emits nothing else (the
# environment is never listed); the value lands in this process only: never printed, an argv, an
# environment or a file. The docker group can read it there already (dockerd's config.v2.json).
# Returns 1 when keycloak-db is not running or has no such entry. SWITCH (backup or count-check,
# whose local pw it sets) names the caller in its messages.
kc_db_password() {   # kc_db_password SWITCH
  local sw="$1" id
  id="$(run_compose ps -q --status running keycloak-db 2>/dev/null </dev/null)" || id=""
  id="${id%%$'\n'*}"
  if [ -z "$id" ]; then
    echo "[ERROR] $sw: keycloak-db is not running, so its password cannot be taken from it" >&2
    return 1
  fi
  pw="$(docker inspect -f '{{range .Config.Env}}{{if eq (index (split . "=") 0) "POSTGRES_PASSWORD"}}{{.}}{{end}}{{end}}' "$id" 2>/dev/null </dev/null)" || pw=""
  case "$pw" in
    POSTGRES_PASSWORD=?*) pw="${pw#POSTGRES_PASSWORD=}" ;;
    *) pw=""; echo "[ERROR] $sw: the running keycloak-db has no POSTGRES_PASSWORD to take" >&2; return 1 ;;
  esac
  echo "[INFO] $sw: keycloak-db's password taken from the running keycloak-db (not printed)"
}

# manifest_names FILE: the file names a theOrg manifest.sha256 lists, one per line; returns 1 (and
# says why) unless every line is "<64 hex>  <plain file name>" naming neither STATUS nor itself.
manifest_names() {
  local f="$1" line out=() re='^[0-9a-f]{64} [ *]([A-Za-z0-9][A-Za-z0-9._-]*)$'
  if [ ! -s "$f" ]; then
    echo "[ERROR] backup: $f is missing or empty" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $re ]] && [ "${BASH_REMATCH[1]}" != STATUS ] && [ "${BASH_REMATCH[1]}" != manifest.sha256 ]; then
      out+=("${BASH_REMATCH[1]}")
    else
      echo "[ERROR] backup: $f has a line that is not '<sha256>  <file name>'" >&2
      return 1
    fi
  done < "$f"
  printf '%s\n' "${out[@]}"
}

# mirror_copy NAME (openldap | keycloak): one copy to MIRROR_DIR/NAME, per theOrg's mirroring rule
# (DEPLOY.md at bd0c6bff, "Mirroring /backup"). The copy's files are root-owned and owner-only, so
# first mirror-stage.sh runs as root in the copy's own image (--network none, --pull never: steps 1
# and 2 just ran it) with the copy and mirror-stage/NAME mounted: under flock -s on the copy's
# .lock it stages the files manifest.sha256 names, the manifest, then STATUS last, checks them with
# sha256sum -c and chowns the stage to this user. Then, as this user: the stage's STATUS must be
# OK; the mirror's STATUS is removed first, then the named files and manifest.sha256 are copied,
# then STATUS last, so a mirror cut off part-way has no STATUS and never passes for a copy. .work,
# .prev, .lock and anything the manifest does not name never reach the stage or the mirror.
mirror_copy() {
  local name="$1" src svc st dest n names
  case "$name" in
    openldap) src="$OL_TARGET" svc=openldap-backup ;;
    keycloak) src="$KC_TARGET" svc=keycloak-backup ;;
  esac
  st="$MIRROR_STAGE/$name" dest="$MIRROR_DIR/$name"
  (umask 077 && mkdir -p "$st") || return 1
  docker run --rm --network none --pull never --user 0:0 --entrypoint sh \
    -v "$src:/backup:ro" -v "$st:/stage" -v "$MIRROR_STAGE_SCRIPT:/mirror-stage.sh:ro" \
    "$REGISTRY/theorg/identity-platform-$svc:$IDENTITY_PLATFORM_TAG" \
    /mirror-stage.sh /backup /stage "$(id -u)" "$(id -g)" </dev/null || return 1
  case "$(head -n 1 "$st/STATUS" 2>/dev/null)" in
    OK*) ;;
    *) echo "[ERROR] backup: $st/STATUS is missing or not OK after staging; not mirroring $name" >&2; return 1 ;;
  esac
  names="$(manifest_names "$st/manifest.sha256")" || return 1
  (umask 077 && mkdir -p "$dest") || return 1
  rm -f "$dest/STATUS" || return 1
  if [ -e "$dest/STATUS" ]; then
    echo "[ERROR] backup: could not remove $dest/STATUS; not mirroring $name" >&2
    return 1
  fi
  for n in $names; do
    cp -p "$st/$n" "$dest/$n" || return 1
  done
  cp -p "$st/manifest.sha256" "$dest/manifest.sha256" || return 1
  # The NAS copy itself checked against its manifest before STATUS: a copy that did not land
  # intact never gets a STATUS.
  if ! (cd "$dest" && sha256sum --quiet -c manifest.sha256) </dev/null; then
    echo "[ERROR] backup: the files in $dest do not match its manifest.sha256; no STATUS written there" >&2
    return 1
  fi
  cp -p "$st/STATUS" "$dest/STATUS" || return 1
  echo "[INFO] backup: $name mirrored to $dest (STATUS last)"
}

# cutover_gate SWITCH: the markers a cutover switch needs; prints the missing or invalid ones and
# returns 3. unpacked counts only with a non-empty version equal to fetched's; started-openldap only
# with its "admin-bind ok" line; configured only with its "apply ok" and "reconcile ok" lines; a
# restored-* or started-keycloak marker only when it is a non-empty file; counted only with its
# "counts equal" line. configure needs both restored-* and both started-*; count-check needs those,
# unpacked and configured; cutover-done needs those and counted.
cutover_gate() {
  local m v fv need=() missing=()
  case "$1" in
    start-openldap) need=(unpacked restored-openldap) ;;
    start-keycloak) need=(unpacked restored-keycloak started-openldap) ;;
    configure) need=(restored-openldap restored-keycloak started-openldap started-keycloak) ;;
    count-check) need=(unpacked restored-openldap restored-keycloak started-openldap started-keycloak configured) ;;
    cutover-done) need=(unpacked restored-openldap restored-keycloak started-openldap started-keycloak configured counted) ;;
    restore-keycloak|restore-openldap) need=(unpacked) ;;
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
    elif [ "$m" = started-openldap ] && ! grep -qx 'admin-bind ok' "$STATE_DIR/$m"; then
      missing+=("started-openldap (no admin-bind ok)")
    elif [ "$m" = configured ] && ! { grep -qx 'apply ok' "$STATE_DIR/$m" && grep -qx 'reconcile ok' "$STATE_DIR/$m"; }; then
      missing+=("configured (no apply ok and reconcile ok)")
    elif [ "$m" = counted ] && ! grep -qx 'counts equal' "$STATE_DIR/$m"; then
      missing+=("counted (no counts equal)")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "[ERROR] $1: refused: cutover marker missing or invalid: ${missing[*]} (in $STATE_DIR); nothing done" >&2
    return 3
  fi
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    up)
      # A replica: keycloak-db alone whatever its cutover-state holds (POST_CUTOVER stays false).
      if is_replica; then replica_db_secret; else up_secrets; fi
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
    backup)
      # host-maintenance's nightly backup task (do_backup). 3 = refused, never a fresh backup.
      do_backup || exit $?
      ;;
    restore)
      # Not 3: build_host.py reads exit 3 from a restore as "skipped, data present".
      echo "[ERROR] restore: refused: the M5 restores are restore-openldap then restore-keycloak (each run alone, after unpack-bundle; scripts/app_switch.sh)" >&2
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
  echo "                    Once cutover-done exists (d05): keycloak-db, openldap and keycloak together" >&2
  echo "                    (--profile restored up -d --wait); needs IDP_LDAP_ADMIN_PASSWORD too, else exit 1;" >&2
  echo "                    exit 1 too when openldap-data, openldap-config or keycloak-db is missing or empty" >&2
  echo "  pull           - Pull all six images now (needs IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN)" >&2
  echo "  images          - Pull missing images, then list the default services' images (build_host.py's replica guard)" >&2
  echo "  verify          - Networks, the root CA and keycloak-db healthy (fatal; once cutover-done exists on" >&2
  echo "                    d05, openldap and keycloak healthy too); the openldap leaf (reported)" >&2
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
  echo "  start-openldap  - M5: start openldap (--profile restored up -d --no-deps --wait) over the restored" >&2
  echo "                    volumes, then check an admin bind; reads IDP_LDAP_ADMIN_PASSWORD's value as one" >&2
  echo "                    line on stdin (scripts/app_switch.sh); needs unpacked and restored-openldap;" >&2
  echo "                    writes started-openldap. Runs alone. Not on a replica" >&2
  echo "  start-keycloak  - M5: start keycloak the same way; reads IDP_KEYCLOAK_DB_PASSWORD's value as one" >&2
  echo "                    line on stdin; keycloak-db must be healthy; needs unpacked, restored-keycloak" >&2
  echo "                    and started-openldap; writes started-keycloak. Runs alone. Not on a replica" >&2
  echo "  configure       - M5: keycloak-configure apply, then reconcile; reads IDP_LDAP_ADMIN_PASSWORD's then" >&2
  echo "                    IDP_DEPLOY_DEX_CLIENT_SECRET's value as one line each on stdin (scripts/app_switch.sh)" >&2
  echo "                    and writes both to each run's stdin; keycloak must be healthy; needs both restored-*" >&2
  echo "                    and both started-*; writes configured; re-runnable. Runs alone. Not on a replica" >&2
  echo "  count-check     - M5 step 7: keycloak-backup backup into the empty count-check/ (keycloak-db's" >&2
  echo "                    password from the running container, on its stdin), then its summary.txt's" >&2
  echo "                    realm, users, clients and credentials lines compared with backup/summary.txt's" >&2
  echo "                    (changesets ignored); equal: writes counted, exit 0; not equal: exit 1, both" >&2
  echo "                    differing line sets printed. No value, no ARG; needs unpacked, both restored-*," >&2
  echo "                    both started-* and configured. Runs alone. Not on a replica" >&2
  echo "  cutover-done    - M5: record the go-live after the cutover's verification; no value, no ARG; needs" >&2
  echo "                    every marker (unpacked, both restored-*, both started-*, configured, counted) and" >&2
  echo "                    openldap and keycloak healthy; writes cutover-done (date, manifests-sha256);" >&2
  echo "                    exits 0 if it exists. Runs alone. Not on a replica" >&2
  echo "  restore-openldap - M5: openldap-backup restore of openldap-backup/ into the empty openldap-data and" >&2
  echo "                    openldap-config (OPENLDAP_BACKUP_CONFIG_MOUNT=rw for this run); no secret; needs a" >&2
  echo "                    valid unpacked marker; writes restored-openldap. Runs alone. Not on a replica" >&2
  echo "  restore-keycloak - M5: keycloak-backup restore of backup/ into keycloak-db's empty database, which" >&2
  echo "                    must be running and healthy; reads keycloak-db's password as one line on stdin" >&2
  echo "                    (scripts/app_switch.sh), never IDP_KEYCLOAK_DB_PASSWORD in the environment;" >&2
  echo "                    writes restored-keycloak. Runs alone. Not on a replica" >&2
  echo "  backup          - Nightly (host-maintenance), once cutover-done exists: openldap-backup backup and" >&2
  echo "                    verify, keycloak-backup backup (keycloak-db's password from the running container," >&2
  echo "                    on its stdin) and verify, then both copies mirrored to $MIRROR_DIR" >&2
  echo "                    (STATUS last); 0 only when all passed. Refused (exit 3) before cutover-done, on a" >&2
  echo "                    replica or with the cutover lock busy. Runs alone. Needs the theOrg repin" >&2
  echo "  restore         - Refused (exit 1): the M5 restores are restore-openldap and restore-keycloak" >&2
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
  restore-keycloak)
    do_restore_keycloak "${@:2}" || exit $?
    exit 0
    ;;
  restore-openldap)
    do_restore_openldap "${@:2}" || exit $?
    exit 0
    ;;
  start-openldap)
    do_start_openldap "${@:2}" || exit $?
    exit 0
    ;;
  start-keycloak)
    do_start_keycloak "${@:2}" || exit $?
    exit 0
    ;;
  configure)
    do_configure "${@:2}" || exit $?
    exit 0
    ;;
  count-check)
    do_count_check "${@:2}" || exit $?
    exit 0
    ;;
  cutover-done)
    do_cutover_done "${@:2}" || exit $?
    exit 0
    ;;
esac

# leaf-issue runs alone: its stdin carries the provisioner password, and no other switch's
# children may run before it holding that pipe. So do the cutover switches (stdin or ARGs).
if [ $# -gt 1 ]; then
  for cmd in "$@"; do
    case "$cmd" in
      leaf-issue|fetch-bundle|unpack-bundle|reset-cutover|cutover-clean|restore-keycloak|restore-openldap|start-openldap|start-keycloak|configure|count-check|cutover-done|backup)
        echo "[ERROR] $cmd: refused: run it alone (it reads a value on stdin, takes ARGs or holds the cutover lock), not with: $*" >&2
        exit 3
        ;;
    esac
  done
fi

# A switch that fails has said why; usage is only for an unknown switch (run_cmd) or none.
for cmd in "$@"; do
  run_cmd "$cmd" || exit 1
done
