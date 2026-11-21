#!/bin/bash
# theOrg's identity-platform on d05 (Keycloak, keycloak-db, openldap). Usage:
# identity-platform.sh [switch ...], e.g. up|pull|images|verify|down|logs|leaf-issue|leaf-renew.
# Switches can be combined.
# From theOrg identity-platform DEPLOY.md "Production on d05" and deploy/d05/compose.example.yml at
# 701e893 (main, the #82 merge), carried to 47f65add (profile `restored`, deploy/d05/openldap-leaf.sh)
# and fcbed3fe (#85: openldap-leaf.sh issue takes the provisioner password on stdin), then to
# theOrg's merged main 5dd8de6 (#86, #87, #88: every one-shot takes its value on stdin) and
# bb456ee (#89: keycloak-configure's read-only check-reset-off, DEPLOY.md cutover step 6).
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
# restore runs, break-glass) takes its value on stdin (theOrg bb456ee, the operator's rule of
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
# script, a byte-identical copy of theOrg's deploy/d05/openldap-leaf.sh at bb456ee, the same blob
# as at fcbed3fe (README).
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
#               (KEYCLOAK_BACKUP_PASSWORD_STDIN=1); keycloak-db must be running and healthy.
#               Both need a valid unpacked marker; each is refused (exit 3, no docker run, nothing
#               changed) on a replica, once its own restored-* marker or cutover-done exists, and
#               when a target or cutover-state/ is a symlink. The restore's own exit (3: a target
#               not empty) passes through, with no marker.
#   A marker per step in cutover-state/: fetched; unpack-started (written right before unpack's
#   docker run: the targets then hold unpack's files); unpacked; restored-openldap and
#   restored-keycloak (date, the unpacked manifests-sha256) from the two restores; started-openldap
#   (date, admin-bind ok) and started-keycloak (date) from the two starts; configured (date, apply
#   ok, reconcile ok) from configure; reset-off (date, resetPasswordAllowed false) from
#   check-reset-off; cutover-done (date, the unpacked manifests-sha256) from the
#   cutover-done switch. Each is written atomically, then synced (sync -f). start-openldap,
#   start-keycloak and configure are gated on them (cutover_gate, exit 3 naming the missing or
#   invalid marker: an unpacked whose version is not fetched's, an empty restored-* or started-*,
#   a started-openldap without admin-bind ok).
#   configure  reads IDP_LDAP_ADMIN_PASSWORD's then IDP_DEPLOY_DEX_CLIENT_SECRET's value, one line
#               each on stdin, and writes both, as theOrg's LDAP_ADMIN_PASSWORD= and
#               VAULT_DEX_CLIENT_SECRET= lines, to keycloak-configure apply's stdin, then reconcile's
#               (DEPLOY.md cutover step 6 at bb456ee); needs both restored-* and both started-*
#               markers and keycloak healthy; re-runnable, after cutover-done too (DEPLOY.md: the
#               configuration steps are idempotent; past cutover-done refused, exit 3, when a data
#               dir is missing or empty, as up). Refused (exit 3, no docker run) with either name in the
#               environment, on a replica, a terminal or an empty read. It removes counted,
#               reset-off and configured before apply.
#   check-reset-off  reads IDP_DEPLOY_DEX_CLIENT_SECRET's value as one line on stdin and writes it,
#               as theOrg's one VAULT_DEX_CLIENT_SECRET= line, to keycloak-configure check-reset-off's
#               stdin alone (DEPLOY.md cutover step 6 at bb456ee: read-only; exit 1 unless realm
#               theorg's resetPasswordAllowed is false). Needs configure's markers and configured, and
#               keycloak healthy; refused (exit 3, no docker run) as configure is. On 0 writes
#               reset-off; otherwise its exit (1, 3) with no marker. count-check and cutover-done
#               need reset-off.
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
#               users, clients, credentials and changesets lines compared with the Mini's
#               backup/summary.txt (read first; its sha256 must be unpacked's
#               keycloak-summary-sha256, else exit 1 and no backup run). count-check/ then keeps
#               only summary.txt. Equal: writes counted (date, manifests-sha256, counts equal);
#               not equal: exit 1, both differing line sets printed. Refused (exit 3) on a replica,
#               a symlink, the lock busy, past cutover-done, unless unpacked, both restored-*, both
#               started-*, configured and reset-off are valid.
#   cutover-done  no value, no ARG: the operator runs it after the cutover's verification. Refused
#               (exit 3, nothing written) on a replica, with the lock busy, unless every marker is
#               there and valid (cutover_gate: unpacked, both restored-*, both started-*,
#               configured with apply ok and reconcile ok, reset-off with resetPasswordAllowed
#               false, and counted with counts equal; both
#               restored-* and counted naming unpacked's manifests-sha256), and unless openldap and
#               keycloak are running and healthy. Writes cutover-done (date, manifests-sha256); past
#               it, prints that and exits 0. The cutover switches (those from fetch-bundle to here,
#   and restore-mirror, restore-mirror-accept-age and mirror-check below) each run alone, and one
#   at a time: each holds flock(1) (util-linux) -n on
#   cutover-state/.lock for its whole run; a busy lock is refused (exit 3).
# Data under /mnt/docker/IdentityPlatform. backup (host-maintenance's nightly task, once cutover-done
# exists; refused, exit 3, before it and on a replica): openldap-backup and keycloak-backup backup and
# verify, then both copies mirrored to /mnt/nas/data1/docker/IdentityPlatform/mirror (do_backup).
# After a rebuild (asyla #1101), the mirror is restored, not the Mini's bundle:
#   restore-mirror  no value, no ARG; runs alone, under the cutover lock; also on a replica (test01,
#               for the restore proof: it reads the mirror through the read-only NAS mount). Each
#               copy without a valid mirror-restored-* marker (openldap, then keycloak) is staged
#               from the mirror to mirror-stage/ and checked against its manifest, copied as root
#               into its empty target, then restored by theOrg's restore (keycloak-db's password
#               from the running container, on keycloak-backup's stdin alone); then
#               mirror-restored-openldap / -keycloak (date, source mirror, the STATUS line, the
#               restored summary.txt's sha256). Refused (exit 3, nothing changed) with
#               IDP_KEYCLOAK_DB_PASSWORD in the environment, a symlink, the lock busy, any M5 marker
#               (fetched to cutover-done), an invalid mirror-restored-* or both valid, an openldap or
#               keycloak container, a target holding data, keycloak-db not healthy, the NAS not
#               mounted, a mirror STATUS not "OK <UTC time>", a mirror older than 48 hours, a STATUS
#               more than 300 s in the future, the two copies' STATUS times more than 2 hours apart,
#               a bad manifest, or a mirror that changed while staged (do_restore_mirror). Exit 2
#               for an ARG.
#   restore-mirror-accept-age  the same, but a mirror older than 48 hours, a STATUS in the future
#               or two copies' times apart is restored, with a warning (a second switch name:
#               switch_args takes an exact ARG count).
#   reset-mirror  no value, no ARG; runs alone, under the cutover lock; also on a replica. After a
#               failed restore-mirror: each copy without a valid mirror-restored-* marker that
#               restore-mirror left something of (mirror-stage/NAME or an invalid marker) has its
#               dirs emptied as root and removed (openldap: openldap-backup/, openldap-data,
#               openldap-config; keycloak: backup/ and keycloak-db/, keycloak-db stopped first), then
#               its marker and stage removed. Refused (exit 3, nothing changed) past mirror-checked,
#               a start, configure or any M5 marker, with an openldap, keycloak or backup one-shot
#               container, a symlink or a mount point among its dirs, APP_ROOT on the NAS share, or
#               data no restore-mirror wrote. The NAS mirror is never touched (do_reset_mirror).
#   mirror-check  no value, no ARG; runs alone, under the cutover lock; also on a replica. After
#               both mirror-restored-* (and before start-openldap): fresh summaries compared with
#               each restored summary.txt (whose sha256 must be its marker's): keycloak-backup
#               backup into count-check/ (count-check's realm, users, clients, credentials and
#               changesets lines) and openldap-backup backup into openldap-count-check/ (its whole
#               summary, entryUUID digest included); each dir then keeps only summary.txt. Equal:
#               mirror-checked (date, source mirror, both summary sha256s, summaries equal); not
#               equal: exit 1, the differing lines printed (do_mirror_check).
#   Then leaf-issue, start-openldap, start-keycloak, configure, check-reset-off and cutover-done as after the M5
#   restores: cutover_gate takes mirror-restored-openldap, mirror-restored-keycloak and
#   mirror-checked in place of unpacked, both restored-* and counted; cutover-state/ holding
#   markers of both paths is refused (exit 3) by every gated switch, and restore-openldap,
#   restore-keycloak and count-check are refused on the mirror path. cutover-done then writes
#   cutover-done (date, source mirror, both summary sha256s), so up and backup run as after M5.
# Rollback inside the Mini's window (asyla #654; the M5 path only; each no value, no ARG, runs
# alone under the cutover lock; not on a replica; refused past any mirror-path marker):
#   rollback-stop  after traffic is back on the Mini (or before step 9): keycloak, then openldap
#               stopped, checked not running; containers, volumes, data and markers kept; writes
#               rolled-back, which refuses every gated switch, cutover-done and backup (exit 3) and
#               up past cutover-done (exit 1). Needs a restored-* or started-* marker. Idempotent
#               (do_rollback_stop).
#   rollback-reset its own approval, after rollback-stop: the keycloak and openldap containers
#               removed, keycloak-db stopped, rollback_reset_dirs emptied as root (lost+found kept),
#               then every cutover marker but fetched, rolled-back last. Never openldap-tls, ca, the
#               bundle or the NAS mirror. Then the build's apps phase and unpack-bundle again
#               (do_rollback_reset).

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
IDENTITY_PLATFORM_TAG="${IDENTITY_PLATFORM_TAG_OVERRIDE:-bb456ee07d47cf9beb906d5492c92d09a7239bfc}"
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

# The M5 cutover bundle. The image is pinned to theOrg identity-platform's merged main bb456ee
# (#87, #88 and #89 merged; its image published there), the same commit as IDENTITY_PLATFORM_TAG.
CUTOVER_BUNDLE_COMMIT="bb456ee07d47cf9beb906d5492c92d09a7239bfc"
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
# mirror-check's own openldap-backup copy (asyla #1101), mounted over /backup for that run.
OL_COUNT_DIR="$APP_ROOT/openldap-count-check"

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
# The admin DN (DEPLOY.md at bb456ee, "Verify" 1) start-openldap binds as.
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
  if cutover_is_done && { [ -e "$STATE_DIR/$ROLLED_BACK" ] || [ -L "$STATE_DIR/$ROLLED_BACK" ]; }; then
    echo "[ERROR] up: refused: $STATE_DIR/$ROLLED_BACK exists (rollback-stop stood d05's openldap and keycloak down after a rollback to the Mini); past $STATE_DIR/$CUTOVER_DONE up would start them again: run rollback-reset first; not starting" >&2
    exit 1
  fi
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
# empty, over an existing bundle or unpacked marker (cutover-clean or reset-cutover first), and once
# any MIRROR_PATH_MARKERS marker exists (refuse_mirror_path: a host restored from the mirror); exit
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
  refuse_mirror_path fetch-bundle || return
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
# target or cutover-state/ that is a symlink, the cutover lock busy, any MIRROR_PATH_MARKERS marker
# (refuse_mirror_path), or the image missing (run fetch-bundle). Exit 2 for ARGs that are not three 64-hex. Past every refusal and the identity
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
  refuse_mirror_path unpack-bundle || return
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
# target or cutover-state/ is a symlink, the cutover lock is busy, any MIRROR_PATH_MARKERS marker
# exists (refuse_mirror_path), cutover-done or a restored-* marker exists, or `compose --profile restored --profile ops ps -a -q openldap keycloak
# keycloak-backup openldap-backup` lists a container or fails: past a restore the targets are the
# restores' input, never emptied here. Then the unpacked marker goes first (a crash mid-delete
# leaves no unpacked over a partial target; unpack-started stays, so a reset can run again), each
# existing target is emptied but for lost+found by the pinned image's find (unpack's files are
# root-owned; --pull never, --network none; find -xdev, rm --one-file-system --preserve-root=all:
# the image is FROM keycloak-db's postgres bookworm digest, theOrg bb456ee Dockerfile.cutover-bundle
# L9, so GNU find and rm; a mount below a target is left, and the target then fails), and once both are verified empty the unpack-started
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
  refuse_mirror_path reset-cutover || return
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
      /t -xdev -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf --one-file-system --preserve-root=all {} + </dev/null || rc=$?
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
# gates it. Refused (exit 3) on a replica, with the cutover lock busy, once any MIRROR_PATH_MARKERS
# marker exists (refuse_mirror_path), and once cutover-done exists.
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
  refuse_mirror_path cutover-clean || return
  if [ -e "$STATE_DIR/$CUTOVER_DONE" ]; then
    echo "[ERROR] cutover-clean: refused: $STATE_DIR/$CUTOVER_DONE exists (the cutover is done); nothing changed" >&2
    return 3
  fi
  rm -f "$BUNDLE" "$CUT_DIR"/.bundle.* "$STATE_DIR"/.fetched.* || return 1
  echo "[INFO] cutover-clean: no $BUNDLE, no temp download; the fetched marker is kept"
}

# The restores (DEPLOY.md "Production on d05", cutover step 5, at theOrg bb456ee): the unpacked
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
# bb456ee): `--profile restored up -d --no-deps --wait SERVICE` over the restored data, with
# --wait-timeout START_WAIT_S (IDENTITY_PLATFORM_START_WAIT_S, default 300; asyla's, as up's). The
# value (start-openldap: IDP_LDAP_ADMIN_PASSWORD; start-keycloak: IDP_KEYCLOAK_DB_PASSWORD) is one
# line on this script's stdin (scripts/app_switch.sh writes it), read as leaf-issue reads its value,
# and reaches the docker compose process alone, in its environment under the names compose.yml
# passes by name (LDAP_ADMIN_PASSWORD and LDAP_CONFIG_PASSWORD; KC_DB_PASSWORD): never an argv, a
# file or a log. start-openldap then checks an admin bind with it (step 5: the admin password is
# then the copy's) in theOrg's stdin form (scripts/rotate_ldap_admin_lab.py at bb456ee):
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

# configure (DEPLOY.md "Production on d05", cutover step 6, at theOrg bb456ee): keycloak-configure
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
# Past the refusals, before apply, it removes counted, reset-off and configured, so a re-run leaves
# none stale (check-reset-off and count-check run again after it). On both 0 writes configured
# (date, apply ok, reconcile ok).
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
  # A re-run leaves no stale marker: counted (a count of the old configuration), reset-off (a check
  # of it) and configured go before apply; a failed run leaves none.
  if ! rm -f "$STATE_DIR/counted" "$STATE_DIR/reset-off" "$STATE_DIR/configured"; then
    unset -v ldap dex
    echo "[ERROR] $sw: could not remove $STATE_DIR/counted, reset-off and configured; no keycloak-configure run" >&2
    return 1
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

# check-reset-off (DEPLOY.md "Production on d05", cutover step 6, at theOrg bb456ee, right after
# configure): keycloak-configure's read-only check-reset-off, which GETs realm theorg over the admin
# API and exits 1 unless resetPasswordAllowed is false (an absent realm or field fails too); a
# failure stops the cutover before step 7. One value, IDP_DEPLOY_DEX_CLIENT_SECRET's, as one line on
# this script's stdin (scripts/app_switch.sh writes it), read as configure reads its values; the run
# gets it on its stdin alone in theOrg's form, exactly one line `VAULT_DEX_CLIENT_SECRET=<value>`
# (theOrg refuses a second line, the name in its environment or a terminal, exit 3), written by
# builtin printf into `builtin exec docker` (never an argv, an environment, a file or a log). Refused
# (exit 3, no docker run, nothing changed) with IDP_DEPLOY_DEX_CLIENT_SECRET in the environment, on
# a replica, cutover-state/ a symlink, the lock busy, a missing or invalid marker (cutover_gate:
# configure's markers and a valid configured), keycloak not running and healthy, a terminal on stdin
# or an empty read. Exit 2 for an ARG. Past the refusals, before the run, it removes reset-off, so
# a failed check leaves none. On 0 writes reset-off (date, resetPasswordAllowed false), which
# count-check (M5 path) and cutover-done (both paths) need; otherwise returns the run's exit (1: not
# false; 3: it refused its stdin) with no marker. Re-runnable (it only reads), after cutover-done too
# (configure, which removes reset-off, is).
do_check_reset_off() {
  local sw=check-reset-off h rc=0
  if [ -n "${IDP_DEPLOY_DEX_CLIENT_SECRET+x}" ]; then
    echo "[ERROR] $sw: refused: IDP_DEPLOY_DEX_CLIENT_SECRET is set in the environment; unset it and write the value as one line to $sw's stdin (scripts/app_switch.sh does); nothing changed" >&2
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
  h="$(kc_health </dev/null)"
  if [ "$h" != healthy ]; then
    echo "[ERROR] $sw: refused: keycloak is $h, not running and healthy (start-keycloak first); nothing changed" >&2
    return 3
  fi
  if [ -t 0 ]; then
    echo "[ERROR] $sw: refused: stdin is a terminal; $sw reads IDP_DEPLOY_DEX_CLIENT_SECRET's value as one line on stdin (scripts/app_switch.sh writes it); nothing changed" >&2
    return 3
  fi
  { set +x; } 2>/dev/null
  set +a
  unset -v dex
  local +x dex=""
  IFS= builtin read -r dex || true
  exec </dev/null
  if [[ -z $dex ]]; then
    unset -v dex
    echo "[ERROR] $sw: refused: no IDP_DEPLOY_DEX_CLIENT_SECRET value read on stdin; nothing changed" >&2
    return 3
  fi
  if ! rm -f "$STATE_DIR/reset-off"; then
    unset -v dex
    echo "[ERROR] $sw: could not remove $STATE_DIR/reset-off; no keycloak-configure run" >&2
    return 1
  fi
  echo "[INFO] $sw: keycloak-configure check-reset-off"
  # As configure's runs: run_compose's argv, the docker program in its own subshell.
  builtin printf 'VAULT_DEX_CLIENT_SECRET=%s\n' "$dex" \
    | (builtin exec docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" \
        --profile ops run --rm -T keycloak-configure check-reset-off) || rc=$?
  unset -v dex
  if [ "$rc" -ne 0 ]; then
    echo "[ERROR] $sw: keycloak-configure check-reset-off exited $rc (1: realm theorg's resetPasswordAllowed is not false, or the realm or field is absent; 3: it refused its stdin or a setting); no reset-off marker; the cutover stops before step 7" >&2
    return "$rc"
  fi
  write_state reset-off "date $(date -u +%Y-%m-%dT%H:%M:%SZ </dev/null)" "resetPasswordAllowed false"
}

# cutover-done: the go-live record, run by the operator after the cutover's verification (DEPLOY.md
# step 8). No value, no ARG (exit 2). Refused (exit 3, nothing written) on a replica, cutover-state/
# a symlink, the lock busy, a missing or invalid marker (cutover_gate: unpacked, both restored-*,
# both started-*, configured, reset-off and counted), an unpacked manifests-sha256 that is not 64 hex or a
# restored-* or counted naming another, and openldap or keycloak not running and healthy. Past an existing cutover-done:
# says so, exit 0, nothing written. Writes cutover-done (date, manifests-sha256): up then starts
# all three services and needs both values; the restores, starts, reset-cutover and cutover-clean
# refuse. On the mirror path (asyla #1101; cutover_gate: both mirror-restored-*, mirror-checked, both
# started-*, configured and reset-off) it writes cutover-done (date, source mirror, mirror-checked's two summary
# sha256s) instead, and up and backup then run as after M5.
do_cutover_done() {
  local sw=cutover-done m f h svc lines=()
  if [ $# -ne 0 ]; then
    echo "[ERROR] $sw: usage: $sw (no ARG)" >&2
    return 2
  fi
  if is_replica; then
    echo "[ERROR] $sw: refused: not on a replica ($(hostname -s </dev/null)); the cutover is d05's; nothing changed" >&2
    return 3
  fi
  cutover_lock "$sw" || return
  refuse_rolled_back "$sw" || return
  if [ -e "$STATE_DIR/$CUTOVER_DONE" ]; then
    echo "[INFO] $sw: $STATE_DIR/$CUTOVER_DONE exists already (date $(state_value "$CUTOVER_DONE" date)); nothing changed"
    return 0
  fi
  cutover_gate "$sw" || return
  # The gate passed on one path: mirror-checked is there only on the mirror path (asyla #1101).
  if [ -e "$STATE_DIR/mirror-checked" ]; then
    lines=("source mirror"
      "openldap-summary-sha256 $(state_value mirror-checked openldap-summary-sha256)"
      "keycloak-summary-sha256 $(state_value mirror-checked keycloak-summary-sha256)")
  else
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
    lines=("manifests-sha256 $m")
  fi
  for svc in openldap keycloak; do
    h="$(restored_health "$svc" </dev/null)"
    if [ "$h" != healthy ]; then
      echo "[ERROR] $sw: refused: $svc is $h, not running and healthy; nothing changed" >&2
      return 3
    fi
  done
  write_state "$CUTOVER_DONE" "date $(date -u +%Y-%m-%dT%H:%M:%SZ </dev/null)" "${lines[@]}" || return 1
  echo "[INFO] $sw: recorded; up now starts keycloak-db, openldap and keycloak and needs IDP_KEYCLOAK_DB_PASSWORD and IDP_LDAP_ADMIN_PASSWORD"
}

# count-check: DEPLOY.md cutover step 7, Counts (theOrg bb456ee): keycloak-backup backup on d05 into
# its empty count-check/, then its summary.txt compared with the Mini's (backup/summary.txt, from the
# bundle): the realm names, and per realm the users, the clients and the credentials by type must be
# equal. Only the `realm`, `users`, `clients`, `credentials` and `changesets` lines count, compared
# LC_ALL=C sorted; any other line is ignored. `changesets` is count(*) of Keycloak's Liquibase
# changelog (theOrg bb456ee scripts/keycloak_backup.sh:175-182), which restore already requires equal
# (:553, the whole summary): a difference means d05 ran a different Keycloak against the copy, which
# step 7 must stop on. No value, no ARG (exit 2); no stdin is read. keycloak-db's
# password is the running container's own (kc_db_password, as backup), on keycloak-backup backup's
# stdin alone; `run -v count-check:/backup` replaces the service's backup/ mount for that run (Compose
# v5.7.0, checked on ws01), so backup/ is never written. Before anything else is run, the Mini's
# backup/summary.txt is read once through keycloak-db's image (read-only) and its sha256 must equal
# unpacked's keycloak-summary-sha256 (theOrg bb456ee scripts/cutover_bundle.sh: the sha256 of
# keycloak/summary.txt), so the counts compared are the Mini's copy's; not equal: exit 1, no backup
# run, no marker. count-check/ is then emptied (its files are root-owned: find in keycloak-db's
# image, --pull never, --network none, as reset-cutover), and d05's summary is read through that
# image, read-only. After the backup (and whatever the comparison), the same find removes all of
# count-check/ but summary.txt, so no Keycloak dump stays on disk; anything else left: exit 1, no
# marker. Refused (exit 3, nothing changed) on a replica, count-check/, a target or cutover-state/
# a symlink, the lock busy, past cutover-done, and on a missing or invalid marker (cutover_gate:
# unpacked, both restored-*, both started-* and configured; unpacked's manifests-sha256 and
# keycloak-summary-sha256 64 hex). Equal: writes counted (date, the unpacked manifests-sha256,
# counts equal), which cutover-done needs; exit 0. Not equal: exit 1, both differing line sets
# printed (counts, not secrets), no marker. The backup failing: its exit, no marker. count-check/
# not emptied, keycloak-db's password not taken, or a summary unreadable or without a realm line:
# exit 1, no marker. Re-runnable until cutover-done; past the refusals a run first removes an
# existing counted.
do_count_check() {
  local sw=count-check m k raw sum rc=0 mini new
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
  k="$(state_value unpacked keycloak-summary-sha256)"
  if [[ ! $k =~ $SHA256_RE ]]; then
    echo "[ERROR] $sw: refused: cutover marker missing or invalid: unpacked (keycloak-summary-sha256 '$k' is not 64 hex) (in $STATE_DIR); nothing done" >&2
    return 3
  fi

  rm -f "$STATE_DIR/counted" || return 1
  # The Mini's summary first, read once: its bytes must be the unpacked copy's (cutover_bundle.sh's
  # keycloak-summary-sha256 is the sha256 of keycloak/summary.txt), and its counts come from that read.
  if ! raw="$(read_summary "$KC_TARGET")"; then
    echo "[ERROR] $sw: could not read the Mini's $KC_TARGET/summary.txt; no backup run, no counted marker" >&2
    return 1
  fi
  raw="${raw%x}"
  sum="$(builtin printf '%s' "$raw" | sha256_hex)"
  if [ "$sum" != "$k" ]; then
    echo "[ERROR] $sw: refused: $KC_TARGET/summary.txt is not the Mini's copy (its sha256 $sum is not unpacked's keycloak-summary-sha256 $k); no backup run, no counted marker" >&2
    return 1
  fi
  mini="$(count_lines "$raw")"
  if ! grep -q '^realm ' <<<"$mini"; then
    echo "[ERROR] $sw: could not read a realm line from the Mini's $KC_TARGET/summary.txt; no backup run, no counted marker" >&2
    return 1
  fi

  count_dir_clear "$sw" "$COUNT_DIR" || { echo "[ERROR] $sw: no counted marker" >&2; return 1; }

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
    count_dir_prune "$sw"
    return "$rc"
  fi

  if raw="$(read_summary "$COUNT_DIR")"; then new="$(count_lines "${raw%x}")"; else new=""; fi
  # No Keycloak dump stays on disk: all but summary.txt removed, whatever the comparison.
  count_dir_prune "$sw" || { echo "[ERROR] $sw: no counted marker" >&2; return 1; }
  if ! grep -q '^realm ' <<<"$new"; then
    echo "[ERROR] $sw: could not read a realm line from d05's $COUNT_DIR/summary.txt; no counted marker" >&2
    return 1
  fi
  if [ "$mini" != "$new" ]; then
    {
      echo "[ERROR] $sw: the counts differ (realm, users, clients, credentials, changesets lines); no counted marker"
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

# read_summary DIR: DIR/summary.txt read as root through keycloak-db's image (read-only, no pull, no
# network), its bytes then one x (so a command substitution keeps its trailing newlines; the caller
# strips the x); returns 1 when unread.
read_summary() {
  docker run --rm --pull never --network none --user 0:0 --entrypoint cat -v "$1:/s:ro" "$KC_DB_IMAGE" /s/summary.txt </dev/null || return 1
  builtin printf x
}

# count_lines TEXT: a summary's realm, users, clients, credentials and changesets lines, LC_ALL=C sorted.
count_lines() {
  builtin printf '%s\n' "$1" | { grep -E '^(realm|users|clients|credentials|changesets) ' || true; } | LC_ALL=C sort
}

# count_dir_clear SWITCH DIR: DIR made and emptied (lost+found aside; its files are root-owned) through
# keycloak-db's image (find, --pull never, --network none, as reset-cutover; find -xdev and GNU rm
# --one-file-system --preserve-root=all, so a mount -v binds below DIR is left, never emptied).
# Returns 1 when anything is left: no backup is run into it.
count_dir_clear() {
  local rc=0
  mkdir -p "$2" || return 1
  target_empty "$2" && return 0
  docker run --rm --network none --pull never --user 0:0 --entrypoint find -v "$2:/t" "$KC_DB_IMAGE" \
    /t -xdev -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf --one-file-system --preserve-root=all {} + </dev/null || rc=$?
  if ! target_empty "$2"; then
    echo "[ERROR] $1: $2 still holds files (find exit $rc); no backup run" >&2
    return 1
  fi
}

# count_dir_prune SWITCH [DIR]: DIR (count-check/ by default) emptied of all but summary.txt (and
# lost+found) through keycloak-db's image, as its emptying: no Keycloak or directory dump stays on
# disk. Returns 1, naming what is left, when anything else remains.
count_dir_prune() {
  local rc=0 names left dir="${2:-$COUNT_DIR}"
  docker run --rm --network none --pull never --user 0:0 --entrypoint find -v "$dir:/t" "$KC_DB_IMAGE" \
    /t -xdev -mindepth 1 -maxdepth 1 ! -name lost+found ! -name summary.txt -exec rm -rf --one-file-system --preserve-root=all {} + </dev/null || rc=$?
  if ! names="$(ls -A "$dir" </dev/null)"; then
    echo "[ERROR] $1: could not list $dir after removing all but summary.txt (find exit $rc)" >&2
    return 1
  fi
  left="$(grep -vxF -e lost+found -e summary.txt <<<"$names" || true)"
  if [ -n "$left" ]; then
    echo "[ERROR] $1: $dir still holds more than summary.txt (find exit $rc): $(tr '\n' ' ' <<<"$left")" >&2
    return 1
  fi
}

# backup (asyla #654 unit D; the operator's "Yes, mirror nightly", 2026-11-16). host-maintenance's
# nightly backup task runs `identity-platform.sh backup` (it looks for run_cmd's `backup)` line)
# with stdin /dev/null and MAINT_FOREGROUND=1, blocks until it exits and reads only the exit: 0
# counts as a fresh backup. So 0 only when all three steps passed, in this order (theOrg DEPLOY.md
# at bb456ee, "Production on d05": Backup; "Keycloak: backup, restore and verify"; "Directory:
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
# refused here (3) rather than by theOrg's own /backup/.lock (1). Runs alone. No stdin is read.
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
  refuse_rolled_back "$sw" || return

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

# manifest_names FILE [SWITCH]: the file names a theOrg manifest.sha256 lists, one per line; returns
# 1 (and says why, as SWITCH: backup by default) unless every line is "<64 hex>  <plain file name>"
# naming neither STATUS nor itself.
manifest_names() {
  local f="$1" who="${2:-backup}" line out=() re='^[0-9a-f]{64} [ *]([A-Za-z0-9][A-Za-z0-9._-]*)$'
  if [ ! -s "$f" ]; then
    echo "[ERROR] $who: $f is missing or empty" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $re ]] && [ "${BASH_REMATCH[1]}" != STATUS ] && [ "${BASH_REMATCH[1]}" != manifest.sha256 ]; then
      out+=("${BASH_REMATCH[1]}")
    else
      echo "[ERROR] $who: $f has a line that is not '<sha256>  <file name>'" >&2
      return 1
    fi
  done < "$f"
  printf '%s\n' "${out[@]}"
}

# mirror_copy NAME (openldap | keycloak): one copy to MIRROR_DIR/NAME, per theOrg's mirroring rule
# (DEPLOY.md at bb456ee, "Mirroring /backup"). The copy's files are root-owned and owner-only, so
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

# restore-mirror and restore-mirror-accept-age (asyla #1101; the operator's "Yes, switches",
# 2026-11-21): a rebuilt d05 (or test01 as its replica, for the restore proof) restored from the
# nightly NAS mirror (do_backup step 3), not from the Mini's cutover bundle. No value, no stdin, no
# ARG (app_switch.sh's switch_args takes an exact ARG count, so the age override is a second switch
# name, the coordinator's decision of 2026-11-21, not an ARG). The build is unchanged (restore =
# false): its up starts keycloak-db alone, empty; then the operator runs this, alone.
# Per copy still to restore (openldap first, then keycloak), in three passes, so that every refusal
# comes before any target is written:
#   1. Refusals (exit 3, nothing changed): IDP_KEYCLOAK_DB_PASSWORD in the environment (this switch
#      takes no value); one of its paths a symlink; the cutover lock busy; cutover-done or any M5 marker
#      in cutover-state/ (MIRROR_M5_MARKERS); a mirror-restored-* marker that is there but not valid
#      (mirror_marker_ok); both markers valid (nothing left to restore); an openldap or keycloak
#      container (or compose unable to tell); for openldap, openldap-backup/, openldap-data or
#      openldap-config holding more than lost+found; for keycloak, backup/ holding more, or
#      keycloak-db not running and healthy (theOrg's restore refuses a database with tables); the NAS
#      share not mounted; the mirror's STATUS not "OK <UTC ISO time>"; a STATUS older than
#      MIRROR_MAX_AGE_S (48 hours; the coordinator's rule), a STATUS more than MIRROR_MAX_AHEAD_S
#      (300 s) in the future, or the two copies' STATUS times (a copy restored already: its marker's)
#      more than MIRROR_MAX_SKEW_S (2 hours) apart, all three under restore-mirror (the switch
#      restore-mirror-accept-age restores it, with a warning; asyla #1101 review R2). Exit 2 for any ARG.
#   2. Stage (mirror_restage): the files the mirror's manifest.sha256 names, then the manifest, copied
#      as this user to mirror-stage/NAME (emptied first), checked there with sha256sum -c; then the
#      mirror's STATUS and manifest read again, and either changed (a backup wrote the mirror
#      meanwhile): exit 3, no target written; then STATUS staged last. The mirror is only read.
#   3. Restore (mirror_restore): the stage copied into the empty target as root in the copy's own
#      image (MIRROR_UNSTAGE_SH: mirror-stage.sh reversed: the named files, the manifest, sha256sum
#      -c, STATUS last; the target root-owned 0700, files 0600), then theOrg's restore, which
#      verifies the copy and refuses a target that is not empty (DEPLOY.md at bb456ee): openldap
#      with OPENLDAP_BACKUP_CONFIG_MOUNT=rw for that run, no secret; keycloak with keycloak-db's
#      password taken from the running container (kc_db_password) and written to the one-shot's
#      stdin alone. The restore's own exit passes through (3: it refused), with no marker. On 0,
#      mirror-restored-NAME (date, source mirror, the mirror's STATUS line, the restored
#      summary.txt's sha256). A valid marker is skipped on a re-run, so a run that restored openldap
#      and failed on keycloak restores keycloak alone next time (keycloak-db's password is taken
#      before backup/ is written; a failure after that leaves backup/ to be emptied first).
# Allowed on a replica (the restore proof): it reads the mirror through the replica's read-only
# NAS mount and writes only local disk. Runs alone, under the cutover lock (backup's too).
MIRROR_MAX_AGE_S=$((48 * 3600))
MIRROR_MAX_AHEAD_S=300
MIRROR_MAX_SKEW_S=$((2 * 3600))
MIRROR_STATUS_RE='^OK [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
MIRROR_M5_MARKERS=(fetched unpack-started unpacked restored-openldap restored-keycloak started-openldap started-keycloak configured reset-off counted "$CUTOVER_DONE" rolled-back)

# iso_epoch YYYY-MM-DDTHH:MM:SSZ: its seconds since 1970 (UTC), in bash arithmetic (no GNU date -d:
# the tests run on macOS); returns 1 for anything else.
iso_epoch() {
  local re='^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$' y m d hh mm ss era yoe doy doe
  [[ $1 =~ $re ]] || return 1
  y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
  hh=$((10#${BASH_REMATCH[4]})) mm=$((10#${BASH_REMATCH[5]})) ss=$((10#${BASH_REMATCH[6]}))
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] && [ "$d" -le 31 ] && [ "$hh" -le 23 ] \
    && [ "$mm" -le 59 ] && [ "$ss" -le 60 ] || return 1
  # Days from the civil date (H. Hinnant's days_from_civil), years from March.
  [ "$m" -gt 2 ] || y=$((y - 1))
  era=$((y / 400)) yoe=$((y - y / 400 * 400))
  doy=$(( (153 * ((m + 9) % 12) + 2) / 5 + d - 1 ))
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  echo $(( (era * 146097 + doe - 719468) * 86400 + hh * 3600 + mm * 60 + ss ))
}

# mirror_marker_ok NAME: STATE_DIR/mirror-restored-NAME is a valid marker (a date line, source
# mirror, an OK STATUS line, a 64-hex summary-sha256).
mirror_marker_ok() {
  local f="$STATE_DIR/mirror-restored-$1"
  [ -f "$f" ] && [ -s "$f" ] && grep -qE '^date [^ ]+$' "$f" && grep -qx 'source mirror' "$f" \
    && grep -qE '^status OK [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$f" \
    && grep -qE '^summary-sha256 [0-9a-f]{64}$' "$f"
}

# mirror_targets NAME: the dirs a copy's restore needs empty (lost+found aside): its backup dir (the
# restore's input) and, for openldap, the data and config volumes (keycloak's database is checked by
# theOrg's restore: it refuses one with tables).
mirror_targets() {
  case "$1" in
    openldap) printf '%s\n' "$OL_TARGET" "$APP_ROOT/openldap-data" "$APP_ROOT/openldap-config" ;;
    keycloak) printf '%s\n' "$KC_TARGET" ;;
  esac
}

do_restore_mirror() {   # do_restore_mirror ACCEPT_AGE(true|false) [ARG...]: the dispatcher sets ACCEPT_AGE
  local accept="$1" sw=restore-mirror n m d i todo=() lines=() ids h line t now age ts=() sl=() skew
  shift
  if $accept; then sw=restore-mirror-accept-age; fi
  if [ -n "${IDP_KEYCLOAK_DB_PASSWORD+x}" ]; then
    echo "[ERROR] $sw: refused: IDP_KEYCLOAK_DB_PASSWORD is set in the environment; $sw takes no value (keycloak-db's password comes from the running container); nothing changed" >&2
    return 3
  fi
  if [ $# -ne 0 ]; then
    echo "[ERROR] $sw: usage: $sw (no ARG; restore-mirror-accept-age restores a mirror older than $((MIRROR_MAX_AGE_S / 3600)) hours)" >&2
    return 2
  fi
  refuse_symlinks "$sw" "$STATE_DIR" "$KC_TARGET" "$OL_TARGET" "$APP_ROOT/openldap-data" "$APP_ROOT/openldap-config" \
    "$MIRROR_STAGE" "$MIRROR_STAGE/openldap" "$MIRROR_STAGE/keycloak" \
    "$MIRROR_DIR" "$MIRROR_DIR/openldap" "$MIRROR_DIR/keycloak" || return
  cutover_lock "$sw" || return
  for m in "${MIRROR_M5_MARKERS[@]}"; do
    if [ -e "$STATE_DIR/$m" ]; then
      echo "[ERROR] $sw: refused: $STATE_DIR/$m exists (an M5 cutover marker: this host's data is the cutover's, not a rebuild's); nothing changed" >&2
      return 3
    fi
  done
  for n in openldap keycloak; do
    if mirror_marker_ok "$n"; then
      echo "[INFO] $sw: $STATE_DIR/mirror-restored-$n is valid; $n is restored already, skipped"
    elif [ -e "$STATE_DIR/mirror-restored-$n" ]; then
      echo "[ERROR] $sw: refused: $STATE_DIR/mirror-restored-$n exists but is not a valid marker; nothing changed" >&2
      return 3
    else
      todo+=("$n")
    fi
  done
  if [ ${#todo[@]} -eq 0 ]; then
    echo "[ERROR] $sw: refused: both copies are restored from the mirror already (mirror-restored-openldap and mirror-restored-keycloak); nothing changed" >&2
    return 3
  fi
  if ! ids="$(run_compose --profile restored ps -a -q openldap keycloak </dev/null)"; then
    echo "[ERROR] $sw: refused: docker compose ps for openldap and keycloak failed (cannot tell whether either container exists); nothing changed" >&2
    return 3
  fi
  if [ -n "$ids" ]; then
    echo "[ERROR] $sw: refused: an openldap or keycloak container exists (a restore goes only into a host where neither has started); nothing changed" >&2
    return 3
  fi
  for n in "${todo[@]}"; do
    while IFS= read -r d; do
      if ! target_empty "$d"; then
        echo "[ERROR] $sw: refused: $d holds more than lost+found (or cannot be listed); $n restores only into empty dirs; nothing changed" >&2
        return 3
      fi
    done < <(mirror_targets "$n")
    if [ "$n" = keycloak ]; then
      h="$(db_health </dev/null)"
      if [ "$h" != healthy ]; then
        echo "[ERROR] $sw: refused: keycloak-db is $h, not running and healthy (run up first); nothing changed" >&2
        return 3
      fi
    fi
  done
  if ! mountpoint -q "$DOCKER_D1" </dev/null; then
    echo "[ERROR] $sw: refused: $DOCKER_D1 is not a mount point (the NAS share is not mounted); nothing changed" >&2
    return 3
  fi
  now="$(date -u +%s </dev/null)" || return 1
  for n in "${todo[@]}"; do
    line="$(head -n 1 "$MIRROR_DIR/$n/STATUS" 2>/dev/null </dev/null)" || line=""
    if [[ ! $line =~ $MIRROR_STATUS_RE ]]; then
      echo "[ERROR] $sw: refused: $MIRROR_DIR/$n/STATUS is missing or not 'OK <UTC time>' (a mirror cut off part-way has none); nothing changed" >&2
      return 3
    fi
    if ! t="$(iso_epoch "${line#OK }")"; then
      echo "[ERROR] $sw: refused: $MIRROR_DIR/$n/STATUS has no valid time ($line); nothing changed" >&2
      return 3
    fi
    age=$((now - t))
    if [ $((t - now)) -gt "$MIRROR_MAX_AHEAD_S" ]; then
      if ! $accept; then
        echo "[ERROR] $sw: refused: the $n mirror's STATUS is $((t - now)) seconds in the future ($line), more than $MIRROR_MAX_AHEAD_S (a clock is wrong); to restore it anyway: restore-mirror-accept-age; nothing changed" >&2
        return 3
      fi
      echo "[WARN] $sw: the $n mirror's STATUS is $((t - now)) seconds in the future ($line); restoring it anyway" >&2
    fi
    if [ "$age" -gt "$MIRROR_MAX_AGE_S" ]; then
      if ! $accept; then
        echo "[ERROR] $sw: refused: the $n mirror is $((age / 3600)) hours old ($line), older than $((MIRROR_MAX_AGE_S / 3600)); to restore it anyway: restore-mirror-accept-age; nothing changed" >&2
        return 3
      fi
      echo "[WARN] $sw: the $n mirror is $((age / 3600)) hours old ($line); restoring it anyway" >&2
    fi
    lines+=("$line")
  done
  # One night's pair: the two copies' STATUS times (a copy restored already: its marker's status
  # line) within MIRROR_MAX_SKEW_S of each other.
  for n in openldap keycloak; do
    line=""
    if [ -e "$STATE_DIR/mirror-restored-$n" ]; then
      line="$(grep -m 1 -E '^status OK ' "$STATE_DIR/mirror-restored-$n" </dev/null)" || line=""
      line="${line#status }"
    else
      for i in "${!todo[@]}"; do [ "${todo[$i]}" != "$n" ] || line="${lines[$i]}"; done
    fi
    if ! t="$(iso_epoch "${line#OK }")"; then
      echo "[ERROR] $sw: refused: no valid STATUS time for the $n copy ($line); nothing changed" >&2
      return 3
    fi
    ts+=("$t")
    sl+=("$line")
  done
  skew=$((ts[0] - ts[1]))
  [ "$skew" -ge 0 ] || skew=$((-skew))
  if [ "$skew" -gt "$MIRROR_MAX_SKEW_S" ]; then
    if ! $accept; then
      echo "[ERROR] $sw: refused: the openldap and keycloak STATUS times differ by $((skew / 60)) minutes (openldap: ${sl[0]}; keycloak: ${sl[1]}), more than $((MIRROR_MAX_SKEW_S / 3600)) hours (not one night's backup); to restore them anyway: restore-mirror-accept-age; nothing changed" >&2
      return 3
    fi
    echo "[WARN] $sw: the openldap and keycloak STATUS times differ by $((skew / 60)) minutes (openldap: ${sl[0]}; keycloak: ${sl[1]}); restoring anyway" >&2
  fi
  # Each stage is held to the STATUS line checked above (a newer one: refused, run again).
  for i in "${!todo[@]}"; do
    mirror_restage "${todo[$i]}" "${lines[$i]}" || return
  done
  for n in "${todo[@]}"; do
    mirror_restore "$n" || return
  done
  echo "[INFO] $sw: done: restored from $MIRROR_DIR (${todo[*]}); next: mirror-check"
}

# mirror_restage NAME STATUS_LINE: MIRROR_DIR/NAME to mirror-stage/NAME, as this user (the mirror's
# files are this user's, owner-only: mirror_copy). STATUS_LINE is the line pass 1 checked. Exit 3
# (no target written) for a manifest that is not theOrg's form or names no summary.txt, and when the
# mirror's STATUS or manifest changed while it was copied; 1 for a failed copy or check.
mirror_restage() {
  local sw=restore-mirror name="$1" s1="$2" src="$MIRROR_DIR/$1" st="$MIRROR_STAGE/$1" names n s2
  if ! names="$(manifest_names "$src/manifest.sha256" "$sw")"; then
    echo "[ERROR] $sw: refused: $src/manifest.sha256 is not a theOrg manifest; nothing restored" >&2
    return 3
  fi
  if ! grep -qx summary.txt <<<"$names"; then
    echo "[ERROR] $sw: refused: $src/manifest.sha256 names no summary.txt; nothing restored" >&2
    return 3
  fi
  rm -rf "$st" && (umask 077 && mkdir -p "$st") || { echo "[ERROR] $sw: could not empty $st; nothing restored" >&2; return 1; }
  for n in $names; do
    cp -p "$src/$n" "$st/$n" </dev/null || { echo "[ERROR] $sw: could not copy $src/$n to $st; nothing restored" >&2; return 1; }
  done
  cp -p "$src/manifest.sha256" "$st/manifest.sha256" </dev/null || { echo "[ERROR] $sw: could not copy $src/manifest.sha256; nothing restored" >&2; return 1; }
  if ! (cd "$st" && sha256sum --quiet -c manifest.sha256) </dev/null; then
    echo "[ERROR] $sw: the files staged in $st do not match the mirror's manifest.sha256; nothing restored" >&2
    return 1
  fi
  s2="$(head -n 1 "$src/STATUS" 2>/dev/null </dev/null)" || s2=""
  if [ "$s2" != "$s1" ] || ! cmp -s "$src/manifest.sha256" "$st/manifest.sha256"; then
    echo "[ERROR] $sw: refused: $src changed while it was copied (STATUS or manifest.sha256; a backup wrote the mirror?); run $sw again; nothing restored" >&2
    return 3
  fi
  cp -p "$src/STATUS" "$st/STATUS" </dev/null || { echo "[ERROR] $sw: could not copy $src/STATUS; nothing restored" >&2; return 1; }
  if [ "$(head -n 1 "$st/STATUS" </dev/null)" != "$s1" ]; then
    echo "[ERROR] $sw: refused: $src/STATUS changed while it was copied; run $sw again; nothing restored" >&2
    return 3
  fi
  echo "[INFO] $sw: $name staged from $src to $st and checked against its manifest ($s1)"
}

# The stage into an empty target, as root in the copy's image (mirror-stage.sh reversed): sh -c
# MIRROR_UNSTAGE_SH mirror-unstage /stage /backup NAME...; exit 3 when the target holds more than
# lost+found, 1 when a copy or the check fails (no STATUS written).
MIRROR_UNSTAGE_SH='set -eu
umask 077
s=$1 t=$2
shift 2
left=$(ls -A "$t" | grep -vx lost+found || true)
[ -z "$left" ] || { echo "[ERROR] mirror-unstage: $t is not empty; nothing copied" >&2; exit 3; }
chown 0:0 "$t"
chmod 0700 "$t"
for n in "$@"; do cp "$s/$n" "$t/$n"; done
cp "$s/manifest.sha256" "$t/manifest.sha256"
(cd "$t" && sha256sum -c manifest.sha256 >/dev/null) || { echo "[ERROR] mirror-unstage: the files in $t do not match its manifest.sha256; no STATUS written" >&2; exit 1; }
cp "$s/STATUS" "$t/.STATUS.tmp"
mv -f "$t/.STATUS.tmp" "$t/STATUS"'

# mirror_restore NAME: the staged copy into its target, theOrg's restore, then the marker.
mirror_restore() {
  local sw=restore-mirror name="$1" st="$MIRROR_STAGE/$1" tgt svc names n line sum rc=0 files=()
  { set +x; } 2>/dev/null
  set +a
  unset -v pw
  local +x pw=""
  case "$name" in
    openldap) tgt="$OL_TARGET" svc=openldap-backup ;;
    keycloak) tgt="$KC_TARGET" svc=keycloak-backup ;;
  esac
  names="$(manifest_names "$st/manifest.sha256" "$sw")" || return 1
  while IFS= read -r n; do files+=("$n"); done <<<"$names"   # no mapfile: bash 3.2 runs the tests
  line="$(head -n 1 "$st/STATUS" </dev/null)" || return 1
  if ! sum="$(file_sha256 "$st/summary.txt")" || [[ ! $sum =~ $SHA256_RE ]]; then
    echo "[ERROR] $sw: could not hash $st/summary.txt; $name not restored" >&2
    return 1
  fi
  # keycloak-db's password before the target is written, so a keycloak-db that went away fails
  # with backup/ still empty (a re-run then needs nothing emptied).
  if [ "$name" = keycloak ]; then
    kc_db_password "$sw" || { echo "[ERROR] $sw: keycloak not restored, $tgt not written, no marker" >&2; return 1; }
  fi
  mkdir -p "$tgt" || return 1
  echo "[INFO] $sw: $name: $st into $tgt as root in $svc's image (STATUS last)"
  docker run --rm --network none --pull never --user 0:0 --entrypoint sh \
    -v "$st:/stage:ro" -v "$tgt:/backup" "$REGISTRY/theorg/identity-platform-$svc:$IDENTITY_PLATFORM_TAG" \
    -c "$MIRROR_UNSTAGE_SH" mirror-unstage /stage /backup "${files[@]}" </dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    pw=""
    unset -v pw
    echo "[ERROR] $sw: copying the stage into $tgt exited $rc (3: it was not empty; 1: it may be part-written: reset-mirror empties it, then a re-run); $name not restored, no marker" >&2
    return "$rc"
  fi
  if [ "$name" = openldap ]; then
    echo "[INFO] $sw: openldap-backup restore of $OL_TARGET into openldap-data and openldap-config"
    ( export OPENLDAP_BACKUP_CONFIG_MOUNT=rw; run_compose --profile ops run --rm -T openldap-backup restore ) </dev/null || rc=$?
  else
    echo "[INFO] $sw: keycloak-backup restore of $KC_TARGET into keycloak-db (keycloak-db's password on its stdin)"
    # run_compose's argv, with `builtin exec docker` in its own subshell, as do_backup.
    builtin printf '%s\n' "$pw" \
      | (builtin exec docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" \
          --profile ops run --rm -T -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup restore) || rc=$?
    pw=""
    unset -v pw
  fi
  if [ "$rc" -ne 0 ]; then
    echo "[ERROR] $sw: $svc restore exited $rc (3: it refused a target that is not empty or, for keycloak, the stdin value; 2: a mount or usage problem; 1: it failed); no mirror-restored-$name marker; $tgt holds the copy: reset-mirror empties it and the restore's targets, then a re-run (README)" >&2
    return "$rc"
  fi
  write_state "mirror-restored-$name" "date $(date -u +%Y-%m-%dT%H:%M:%SZ </dev/null)" "source mirror" \
    "status $line" "summary-sha256 $sum"
}

# reset-mirror (asyla #1101, review R3): after a failed restore-mirror, the dirs of each copy whose
# restore did not finish emptied, so that restore-mirror can run again. No value, no stdin, no ARG
# (exit 2); runs alone, under the cutover lock; also on a replica (the restore proof's host). Every
# refusal comes before anything is stopped or deleted. Refused (exit 3, nothing changed): APP_ROOT
# the NAS share (DOCKER_D1) or below it, as given or resolved (pwd -P); one of its dirs a symlink;
# the cutover lock busy; mirror-checked, any M5 or later marker (MIRROR_M5_MARKERS: started-*,
# configured and cutover-done among them) or any started-*; an openldap, keycloak or backup one-shot
# container (or compose unable to tell); APP_ROOT, mirror-stage/ or one of the dirs a mount point (it
# empties only plain dirs on the data disk: a mount could be the NAS share); a copy with neither a
# valid mirror-restored-* marker nor anything restore-mirror leaves (mirror-stage/NAME, a
# mirror-restored-NAME) whose dirs hold data (restore-mirror did not write them). A copy with a
# valid mirror-restored-* marker finished: it is never touched. Exit 1, nothing changed, when
# mountpoint (util-linux) is not on PATH or keycloak-db's image is not here.
# Then per copy still to reset (openldap, then keycloak): for keycloak, keycloak-db stopped (compose
# stop: its container stays; theOrg's restore writes into its database) and checked not running;
# each of the copy's dirs (mirror_reset_dirs) emptied but for lost+found as root in keycloak-db's
# image (find, --pull never, --network none, as count_dir_clear; its GNU rm 9.1 also with
# --one-file-system --preserve-root=all, so a mount below a dir, which -v binds recursively, is
# skipped and left, never emptied: the list then fails the reset), listed again as root, and removed
# when empty (rmdir, as this user), so it is missing again, as on a fresh build: restore-mirror
# makes backup/ and openldap-backup/, theOrg's openldap restore its two dirs, and up's ensure_dirs
# keycloak-db/, whose postgres entrypoint then initialises an empty database (no PG_VERSION); a dir
# holding only lost+found is kept. Last, the copy's mirror-restored-NAME (an invalid one) and
# mirror-stage/NAME go, so a reset cut off part-way can run again. The NAS mirror is never read or
# written. Exit 1 when a dir still holds files or a step fails. Next (README): for keycloak, the
# build's up (it starts keycloak-db again); then restore-mirror.
KC_DB_DIR="$APP_ROOT/keycloak-db"
mirror_reset_dirs() {   # mirror_reset_dirs NAME: the dirs restore-mirror writes for that copy
  case "$1" in
    openldap) printf '%s\n' "$OL_TARGET" "$APP_ROOT/openldap-data" "$APP_ROOT/openldap-config" ;;
    keycloak) printf '%s\n' "$KC_TARGET" "$KC_DB_DIR" ;;
  esac
}

path_under() {   # path_under P ROOT: P is ROOT or below it (as strings); an empty ROOT is nothing
  [ -n "$2" ] || return 1
  case "$1/" in "${2%/}"/*) return 0 ;; esac
  return 1
}

# mirror_reset_dir DIR: emptied but for lost+found as root, listed again as root, removed when empty.
mirror_reset_dir() {
  local sw=reset-mirror d="$1" rc=0 names
  [ -e "$d" ] || return 0
  docker run --rm --network none --pull never --user 0:0 --entrypoint find -v "$d:/t" "$KC_DB_IMAGE" \
    /t -xdev -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf --one-file-system --preserve-root=all {} + </dev/null || rc=$?
  if ! names="$(docker run --rm --network none --pull never --user 0:0 --entrypoint ls -v "$d:/t:ro" "$KC_DB_IMAGE" -A /t </dev/null)"; then
    echo "[ERROR] $sw: could not list $d as root after emptying it (find exit $rc); the marker and stage kept: run $sw again" >&2
    return 1
  fi
  case "$names" in
    "")
      if ! rmdir "$d" </dev/null; then
        echo "[ERROR] $sw: $d is empty but could not be removed (rmdir, as this user: is $APP_ROOT this user's?); the marker and stage kept" >&2
        return 1
      fi
      echo "[INFO] $sw: $d emptied and removed" ;;
    lost+found) echo "[INFO] $sw: $d emptied (lost+found kept)" ;;
    *)
      echo "[ERROR] $sw: $d still holds files (find exit $rc): $(tr '\n' ' ' <<<"$names"); the marker and stage kept: run $sw again" >&2
      return 1 ;;
  esac
}

do_reset_mirror() {
  local sw=reset-mirror n d f ids ra="" rn="" todo=() dirs=()
  if [ $# -ne 0 ]; then
    echo "[ERROR] $sw: usage: $sw (no ARG)" >&2
    return 2
  fi
  # Never the NAS: APP_ROOT, as given and resolved, is not the share or below it.
  if [ -d "$APP_ROOT" ]; then ra="$(cd "$APP_ROOT" 2>/dev/null && pwd -P)" || ra=""; fi
  if [ -d "$DOCKER_D1" ]; then rn="$(cd "$DOCKER_D1" 2>/dev/null && pwd -P)" || rn=""; fi
  if path_under "$APP_ROOT" "$DOCKER_D1" || path_under "$ra" "$DOCKER_D1" || path_under "$ra" "$rn"; then
    echo "[ERROR] $sw: refused: $APP_ROOT${ra:+ ($ra)} is the NAS share $DOCKER_D1 or below it; $sw never deletes there; nothing changed" >&2
    return 3
  fi
  dirs=("$OL_TARGET" "$APP_ROOT/openldap-data" "$APP_ROOT/openldap-config" "$KC_TARGET" "$KC_DB_DIR"
    "$MIRROR_STAGE" "$MIRROR_STAGE/openldap" "$MIRROR_STAGE/keycloak")
  refuse_symlinks "$sw" "$STATE_DIR" "${dirs[@]}" || return
  cutover_lock "$sw" || return
  for f in "$STATE_DIR/mirror-checked" "${MIRROR_M5_MARKERS[@]/#/$STATE_DIR/}" "$STATE_DIR"/started-*; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      echo "[ERROR] $sw: refused: $f exists (mirror-checked, a start, configure or an M5 cutover marker: $sw empties only a restore that did not finish); nothing changed" >&2
      return 3
    fi
  done
  if ! ids="$(run_compose --profile restored --profile ops ps -a -q openldap keycloak keycloak-backup openldap-backup </dev/null)"; then
    echo "[ERROR] $sw: refused: docker compose ps for openldap, keycloak and the backup one-shots failed (cannot tell whether one exists); nothing changed" >&2
    return 3
  fi
  if [ -n "$ids" ]; then
    echo "[ERROR] $sw: refused: an openldap, keycloak or backup one-shot container exists (started, or a restore still running); nothing changed" >&2
    return 3
  fi
  if ! command -v mountpoint >/dev/null 2>&1; then
    echo "[ERROR] $sw: mountpoint (util-linux) is not on PATH; cannot tell a mount from a dir; nothing changed" >&2
    return 1
  fi
  for d in "$APP_ROOT" "${dirs[@]}"; do
    if [ -e "$d" ] && mountpoint -q "$d" </dev/null; then
      echo "[ERROR] $sw: refused: $d is a mount point ($sw empties only plain dirs on the data disk; a mount could be the NAS share); nothing changed" >&2
      return 3
    fi
  done
  for n in openldap keycloak; do
    if mirror_marker_ok "$n"; then
      echo "[INFO] $sw: $STATE_DIR/mirror-restored-$n is valid: $n's restore finished; not touched"
      continue
    fi
    if [ -e "$MIRROR_STAGE/$n" ] || [ -e "$STATE_DIR/mirror-restored-$n" ] || [ -L "$STATE_DIR/mirror-restored-$n" ]; then
      todo+=("$n")
      continue
    fi
    while IFS= read -r d; do
      [ "$d" != "$KC_DB_DIR" ] || continue   # the build's database: restore-mirror never ran into it
      if ! target_empty "$d"; then
        echo "[ERROR] $sw: refused: $d holds more than lost+found (or cannot be listed), and neither $MIRROR_STAGE/$n nor $STATE_DIR/mirror-restored-$n is there: restore-mirror did not write it; nothing changed" >&2
        return 3
      fi
    done < <(mirror_reset_dirs "$n")
  done
  if [ ${#todo[@]} -eq 0 ]; then
    echo "[INFO] $sw: nothing to reset (each copy finished, or restore-mirror left nothing of it); nothing changed"
    return 0
  fi
  if ! docker image inspect "$KC_DB_IMAGE" >/dev/null 2>&1 </dev/null; then
    echo "[ERROR] $sw: keycloak-db's image ($KC_DB_IMAGE) is not here, so the root-owned files cannot be removed; nothing changed" >&2
    return 1
  fi
  for n in "${todo[@]}"; do
    if [ "$n" = keycloak ]; then
      echo "[INFO] $sw: stopping keycloak-db (theOrg's keycloak restore writes into its database)"
      if ! run_compose stop keycloak-db </dev/null; then
        echo "[ERROR] $sw: docker compose stop keycloak-db failed; keycloak's dirs not emptied" >&2
        return 1
      fi
      if ! ids="$(run_compose ps -q keycloak-db </dev/null)" || [ -n "$ids" ]; then
        echo "[ERROR] $sw: keycloak-db is still running (or compose cannot tell); keycloak's dirs not emptied" >&2
        return 1
      fi
    fi
    while IFS= read -r d; do
      mirror_reset_dir "$d" || return 1
    done < <(mirror_reset_dirs "$n")
    rm -f "$STATE_DIR/mirror-restored-$n" && rm -rf "$MIRROR_STAGE/$n" || return 1
    if [ -e "$STATE_DIR/mirror-restored-$n" ] || [ -L "$STATE_DIR/mirror-restored-$n" ] || [ -e "$MIRROR_STAGE/$n" ]; then
      echo "[ERROR] $sw: $STATE_DIR/mirror-restored-$n or $MIRROR_STAGE/$n is still there" >&2
      return 1
    fi
    echo "[INFO] $sw: $n reset: its dirs empty, no mirror-restored-$n, no $MIRROR_STAGE/$n"
  done
  case " ${todo[*]} " in
    *" keycloak "*) echo "[INFO] $sw: done (${todo[*]}); keycloak-db is stopped with no data dir: next the build's up (README), then restore-mirror" ;;
    *) echo "[INFO] $sw: done (${todo[*]}); next: restore-mirror" ;;
  esac
}

# mirror-check (asyla #1101): restore-mirror's counterpart of count-check, run after both copies are
# restored from the mirror and before start-openldap (the proposal's step 2). No value, no stdin, no
# ARG (exit 2). Per copy, the restored summary.txt (backup/ and openldap-backup/, read once through
# keycloak-db's image, read-only: read_summary) must hash to its mirror-restored-* marker's
# summary-sha256 (else exit 1, no backup run); then a fresh backup of what was restored, into its own
# emptied dir (count_dir_clear; `run -v DIR:/backup` replaces the service's backup/ mount, as
# count-check, so backup/ and openldap-backup/ are never written): openldap-backup backup into
# openldap-count-check/ (no secret; openldap need not run) and keycloak-backup backup into
# count-check/ (keycloak-db's password from the running container, kc_db_password, on its stdin
# alone). Compared: keycloak's realm, users, clients, credentials and changesets lines (count_lines,
# as count-check), and openldap's whole summary (theOrg's summary.txt holds names, counts and the
# entryUUID digest only: no time, no attribute value). After each backup (whatever the comparison)
# its dir keeps only summary.txt (count_dir_prune), so no dump stays on disk; anything else left:
# exit 1, no marker. Refused (exit 3, nothing changed) with IDP_KEYCLOAK_DB_PASSWORD in the
# environment, a symlink, the lock busy, any M5 or later marker (MIRROR_M5_MARKERS: started-*,
# configured and cutover-done too: the check is of the copy as restored), either mirror-restored-*
# missing or invalid, and keycloak-db not running and healthy. Equal: mirror-checked (date, source
# mirror, openldap-summary-sha256, keycloak-summary-sha256, summaries equal), which start-openldap,
# start-keycloak, configure and cutover-done need on this path; exit 0. Not equal: exit 1, the
# differing lines printed (counts and digests, not secrets), no marker. A backup failing: its exit,
# no marker. Allowed on a replica (the restore proof). Re-runnable; past the refusals a run first
# removes an existing mirror-checked.
do_mirror_check() {
  local sw=mirror-check m n d h raw sum rc=0 ol_sum kc_sum ol_old ol_new kc_old kc_new
  { set +x; } 2>/dev/null
  set +a
  unset -v pw
  local +x pw=""
  if [ -n "${IDP_KEYCLOAK_DB_PASSWORD+x}" ]; then
    echo "[ERROR] $sw: refused: IDP_KEYCLOAK_DB_PASSWORD is set in the environment; $sw takes no value (keycloak-db's password comes from the running container); nothing changed" >&2
    return 3
  fi
  if [ $# -ne 0 ]; then
    echo "[ERROR] $sw: usage: $sw (no ARG)" >&2
    return 2
  fi
  refuse_symlinks "$sw" "$STATE_DIR" "$KC_TARGET" "$OL_TARGET" "$COUNT_DIR" "$OL_COUNT_DIR" \
    "$APP_ROOT/openldap-data" "$APP_ROOT/openldap-config" || return
  cutover_lock "$sw" || return
  for m in "${MIRROR_M5_MARKERS[@]}"; do
    if [ -e "$STATE_DIR/$m" ]; then
      echo "[ERROR] $sw: refused: $STATE_DIR/$m exists (an M5 cutover marker or a later step's: $sw checks the copies as restore-mirror left them, before start-openldap); nothing changed" >&2
      return 3
    fi
  done
  for n in openldap keycloak; do
    if ! mirror_marker_ok "$n"; then
      echo "[ERROR] $sw: refused: $STATE_DIR/mirror-restored-$n is missing or not a valid marker (restore-mirror first); nothing changed" >&2
      return 3
    fi
  done
  h="$(db_health </dev/null)"
  if [ "$h" != healthy ]; then
    echo "[ERROR] $sw: refused: keycloak-db is $h, not running and healthy (run up first); nothing changed" >&2
    return 3
  fi

  rm -f "$STATE_DIR/mirror-checked" || return 1
  # The restored summaries first, each read once: its bytes must be the ones restore-mirror hashed.
  for n in openldap keycloak; do
    if [ "$n" = openldap ]; then d="$OL_TARGET"; else d="$KC_TARGET"; fi
    if ! raw="$(read_summary "$d")"; then
      echo "[ERROR] $sw: could not read the restored $d/summary.txt; no backup run, no mirror-checked marker" >&2
      return 1
    fi
    raw="${raw%x}"
    sum="$(builtin printf '%s' "$raw" | sha256_hex)"
    if [ "$sum" != "$(state_value "mirror-restored-$n" summary-sha256)" ]; then
      echo "[ERROR] $sw: $d/summary.txt is not the restored copy's (its sha256 $sum is not mirror-restored-$n's summary-sha256); no backup run, no mirror-checked marker" >&2
      return 1
    fi
    if [ "$n" = openldap ]; then
      ol_sum="$sum" ol_old="$raw"
    else
      kc_sum="$sum" kc_old="$(count_lines "$raw")"
    fi
  done
  if [ -z "$ol_old" ]; then
    echo "[ERROR] $sw: the restored $OL_TARGET/summary.txt is empty; no backup run, no mirror-checked marker" >&2
    return 1
  fi
  if ! grep -q '^realm ' <<<"$kc_old"; then
    echo "[ERROR] $sw: could not read a realm line from the restored $KC_TARGET/summary.txt; no backup run, no mirror-checked marker" >&2
    return 1
  fi
  count_dir_clear "$sw" "$OL_COUNT_DIR" || { echo "[ERROR] $sw: no mirror-checked marker" >&2; return 1; }
  count_dir_clear "$sw" "$COUNT_DIR" || { echo "[ERROR] $sw: no mirror-checked marker" >&2; return 1; }

  echo "[INFO] $sw: openldap-backup backup into $OL_COUNT_DIR"
  run_compose --profile ops run --rm -T -v "$OL_COUNT_DIR:/backup" openldap-backup backup </dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[ERROR] $sw: openldap-backup backup exited $rc; no keycloak backup run, no mirror-checked marker" >&2
    count_dir_prune "$sw" "$OL_COUNT_DIR"
    return "$rc"
  fi
  if raw="$(read_summary "$OL_COUNT_DIR")"; then ol_new="${raw%x}"; else ol_new=""; fi
  count_dir_prune "$sw" "$OL_COUNT_DIR" || { echo "[ERROR] $sw: no mirror-checked marker" >&2; return 1; }

  echo "[INFO] $sw: keycloak-backup backup into $COUNT_DIR (keycloak-db's password on its stdin)"
  kc_db_password "$sw" || { echo "[ERROR] $sw: no keycloak backup run, no mirror-checked marker" >&2; return 1; }
  # run_compose's argv, with `builtin exec docker` in its own subshell, as do_backup.
  builtin printf '%s\n' "$pw" \
    | (builtin exec docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" \
        --profile ops run --rm -T -v "$COUNT_DIR:/backup" -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup backup) || rc=$?
  pw=""
  unset -v pw
  if [ "$rc" -ne 0 ]; then
    echo "[ERROR] $sw: keycloak-backup backup exited $rc; no mirror-checked marker" >&2
    count_dir_prune "$sw"
    return "$rc"
  fi
  if raw="$(read_summary "$COUNT_DIR")"; then kc_new="$(count_lines "${raw%x}")"; else kc_new=""; fi
  count_dir_prune "$sw" || { echo "[ERROR] $sw: no mirror-checked marker" >&2; return 1; }

  if [ -z "$ol_new" ]; then
    echo "[ERROR] $sw: could not read the fresh $OL_COUNT_DIR/summary.txt; no mirror-checked marker" >&2
    return 1
  fi
  if ! grep -q '^realm ' <<<"$kc_new"; then
    echo "[ERROR] $sw: could not read a realm line from the fresh $COUNT_DIR/summary.txt; no mirror-checked marker" >&2
    return 1
  fi
  rc=0
  if [ "$ol_old" != "$ol_new" ]; then
    mirror_check_diff openldap "$OL_TARGET" "$OL_COUNT_DIR" "$ol_old" "$ol_new"
    rc=1
  fi
  if [ "$kc_old" != "$kc_new" ]; then
    mirror_check_diff keycloak "$KC_TARGET" "$COUNT_DIR" "$kc_old" "$kc_new"
    rc=1
  fi
  [ "$rc" -eq 0 ] || return 1
  write_state mirror-checked "date $(date -u +%Y-%m-%dT%H:%M:%SZ </dev/null)" "source mirror" \
    "openldap-summary-sha256 $ol_sum" "keycloak-summary-sha256 $kc_sum" "summaries equal" || return 1
  echo "[INFO] $sw: openldap's summary and keycloak's counts equal the restored copies' ($(grep -c '^realm ' <<<"$kc_new") realm(s)); next: leaf-issue, then start-openldap"
}

# mirror_check_diff NAME RESTORED_DIR FRESH_DIR OLD NEW: the lines only in each summary, to stderr.
mirror_check_diff() {
  {
    if [ "$1" = keycloak ]; then
      echo "[ERROR] mirror-check: keycloak's counts differ (realm, users, clients, credentials, changesets lines); no mirror-checked marker"
    else
      echo "[ERROR] mirror-check: openldap's summaries differ; no mirror-checked marker"
    fi
    echo "  only in the restored $2/summary.txt:"
    LC_ALL=C comm -23 <(printf '%s\n' "$4" | LC_ALL=C sort) <(printf '%s\n' "$5" | LC_ALL=C sort) | sed 's/^/    /'
    echo "  only in the fresh $3/summary.txt:"
    LC_ALL=C comm -13 <(printf '%s\n' "$4" | LC_ALL=C sort) <(printf '%s\n' "$5" | LC_ALL=C sort) | sed 's/^/    /'
  } >&2
}

# mirror_checked_ok: STATE_DIR/mirror-checked is a valid marker: a date line, source mirror,
# summaries equal, and openldap-summary-sha256 and keycloak-summary-sha256 equal to the two
# mirror-restored-* markers' summary-sha256 (so it checked these restores, not earlier ones).
mirror_checked_ok() {
  local f="$STATE_DIR/mirror-checked" n v
  [ -f "$f" ] && [ -s "$f" ] && grep -qE '^date [^ ]+$' "$f" && grep -qx 'source mirror' "$f" \
    && grep -qx 'summaries equal' "$f" || return 1
  for n in openldap keycloak; do
    v="$(state_value mirror-checked "$n-summary-sha256")"
    [[ $v =~ $SHA256_RE ]] && [ "$v" = "$(state_value "mirror-restored-$n" summary-sha256)" ] || return 1
  done
}

# cutover_gate SWITCH: the markers a cutover switch needs; prints the missing or invalid ones and
# returns 3. unpacked counts only with a non-empty version equal to fetched's; started-openldap only
# with its "admin-bind ok" line; configured only with its "apply ok" and "reconcile ok" lines; a
# restored-* or started-keycloak marker only when it is a non-empty file; counted only with its
# "counts equal" line; reset-off only with its "resetPasswordAllowed false" line. configure needs
# both restored-* and both started-*; check-reset-off those and configured; count-check needs those,
# unpacked, configured and reset-off; cutover-done needs those and counted.
# The mirror path (asyla #1101): once any of MIRROR_PATH_MARKERS exists, start-openldap,
# start-keycloak, configure, check-reset-off and cutover-done need mirror-restored-openldap, mirror-restored-keycloak
# (mirror_marker_ok) and mirror-checked (mirror_checked_ok) in place of unpacked, both restored-* and
# counted, plus the same started-* and configured; restore-openldap, restore-keycloak and count-check
# are refused there. A marker of each path (MIRROR_PATH_MARKERS and M5_PATH_MARKERS) is refused by
# every gated switch: the two paths never mix.
MIRROR_PATH_MARKERS=(mirror-restored-openldap mirror-restored-keycloak mirror-checked)
M5_PATH_MARKERS=(fetched unpack-started unpacked restored-openldap restored-keycloak counted)
# refuse_mirror_path SWITCH: exit 3 when any of MIRROR_PATH_MARKERS exists (a file, or a symlink
# even dangling): fetch-bundle, unpack-bundle, reset-cutover and cutover-clean are the M5 path's,
# and a host restored from the mirror is never fetched into, unpacked into or emptied by them.
refuse_mirror_path() {
  local m
  for m in "${MIRROR_PATH_MARKERS[@]}"; do
    if [ -e "$STATE_DIR/$m" ] || [ -L "$STATE_DIR/$m" ]; then
      echo "[ERROR] $1: refused: $STATE_DIR/$m exists (cutover-state/ is on the mirror path: this host was restored from the NAS mirror; $1 is an M5 cutover switch); nothing changed" >&2
      return 3
    fi
  done
}

# refuse_rolled_back SWITCH: exit 3 while cutover-state/rolled-back exists (a file, or a symlink
# even dangling): rollback-stop stood d05's openldap and keycloak down after a rollback to the Mini,
# and nothing starts, restores, configures, checks, records or backs up d05's copy again until
# rollback-reset has emptied it. cutover_gate calls it first, so every gated switch refuses.
ROLLED_BACK=rolled-back
refuse_rolled_back() {
  if [ -e "$STATE_DIR/$ROLLED_BACK" ] || [ -L "$STATE_DIR/$ROLLED_BACK" ]; then
    echo "[ERROR] $1: refused: $STATE_DIR/$ROLLED_BACK exists (rollback-stop stood d05's openldap and keycloak down after a rollback to the Mini); run rollback-reset, then start over from unpack-bundle (README); nothing changed" >&2
    return 3
  fi
}

# rollback-stop (asyla #654; the Mini's 3-day rollback window): stand d05's openldap and keycloak
# down after a rollback to the Mini. No value, no stdin, no ARG (exit 2). The M5 path only. Refused
# (exit 3, nothing changed) on a replica, cutover-state/ a symlink, the lock busy, any mirror-path
# marker (refuse_mirror_path), and with no restored-* or started-* marker (no restore or start ran:
# nothing to stand down). Stops keycloak, then openldap (two compose stops, keycloak first, as it
# reads openldap), then checks that neither runs (compose ps -q); a stop failing or one still
# running: exit 1, no marker. Keeps every container, volume, data dir and marker for inspection;
# keycloak-db runs on. Writes rolled-back (date, keycloak openldap stopped), which refuses (exit 3)
# start-openldap, start-keycloak, the restores, configure, check-reset-off, count-check,
# cutover-done and backup, and up past cutover-done (exit 1), until rollback-reset. Allowed after
# cutover-done. Idempotent: run again it stops what runs, keeps the first rolled-back and exits 0.
# It touches no DNS and no tunnel: the operator runs it once traffic is back on the Mini (step 9
# undone), or before step 9.
do_rollback_stop() {
  local sw=rollback-stop f found="" svc ids
  if [ $# -ne 0 ]; then
    echo "[ERROR] $sw: usage: $sw (no ARG)" >&2
    return 2
  fi
  if is_replica; then
    echo "[ERROR] $sw: refused: not on a replica ($(hostname -s </dev/null)); the cutover is d05's; nothing changed" >&2
    return 3
  fi
  cutover_lock "$sw" || return
  refuse_mirror_path "$sw" || return
  for f in "$STATE_DIR"/restored-* "$STATE_DIR"/started-*; do
    if [ -e "$f" ]; then found="$f"; break; fi
  done
  if [ -z "$found" ]; then
    echo "[ERROR] $sw: refused: no restored-* or started-* marker in $STATE_DIR (no restore or start ran: nothing to stand down); nothing changed" >&2
    return 3
  fi
  for svc in keycloak openldap; do
    echo "[INFO] $sw: stopping $svc"
    if ! run_compose --profile restored stop "$svc" </dev/null; then
      echo "[ERROR] $sw: docker compose stop $svc failed; no $ROLLED_BACK marker" >&2
      return 1
    fi
  done
  if ! ids="$(run_compose --profile restored ps -q keycloak openldap </dev/null)" || [ -n "$ids" ]; then
    echo "[ERROR] $sw: keycloak or openldap is still running (or compose cannot tell); no $ROLLED_BACK marker" >&2
    return 1
  fi
  if [ -f "$STATE_DIR/$ROLLED_BACK" ]; then
    echo "[INFO] $sw: keycloak and openldap are stopped; $STATE_DIR/$ROLLED_BACK exists already (date $(state_value "$ROLLED_BACK" date)); kept"
    return 0
  fi
  write_state "$ROLLED_BACK" "date $(date -u +%Y-%m-%dT%H:%M:%SZ </dev/null)" "keycloak openldap stopped" || return 1
  echo "[INFO] $sw: keycloak and openldap stopped; their containers, volumes, data and the markers kept for inspection; keycloak-db runs on. Next, when d05's copy is to go: rollback-reset (README)"
}

# rollback_reset_dirs: what unpack-bundle, the restores, the starts and count-check wrote, and
# nothing else: backup/, openldap-backup/, openldap-data/, openldap-config/, keycloak-db's data
# dir, count-check/ and openldap-count-check/. Never openldap-tls/, ca/, cutover/ (the
# ciphertext), mirror-stage/ or the NAS mirror.
rollback_reset_dirs() {
  printf '%s\n' "$KC_TARGET" "$OL_TARGET" "$APP_ROOT/openldap-data" "$APP_ROOT/openldap-config" "$KC_DB_DIR" \
    "$COUNT_DIR" "$OL_COUNT_DIR"
}
# The cutover-state markers rollback-reset removes (rolled-back last); fetched is kept.
ROLLBACK_RESET_MARKERS=(unpack-started unpacked restored-openldap restored-keycloak started-openldap started-keycloak
  configured reset-off counted "$CUTOVER_DONE")

# rollback_reset_dir DIR: emptied as root but for lost+found (find -xdev, rm --one-file-system
# --preserve-root=all, as reset-mirror), then listed again as root; the dir itself is kept.
rollback_reset_dir() {
  local sw=rollback-reset d="$1" rc=0 names
  if [ ! -e "$d" ]; then
    echo "[INFO] $sw: $d is not there; nothing to empty"
    return 0
  fi
  docker run --rm --network none --pull never --user 0:0 --entrypoint find -v "$d:/t" "$KC_DB_IMAGE" \
    /t -xdev -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf --one-file-system --preserve-root=all {} + </dev/null || rc=$?
  if ! names="$(docker run --rm --network none --pull never --user 0:0 --entrypoint ls -v "$d:/t:ro" "$KC_DB_IMAGE" -A /t </dev/null)"; then
    echo "[ERROR] $sw: could not list $d as root after emptying it (find exit $rc); $ROLLED_BACK and every marker kept: run $sw again" >&2
    return 1
  fi
  case "$names" in
    "") echo "[INFO] $sw: $d emptied" ;;
    lost+found) echo "[INFO] $sw: $d emptied (lost+found kept)" ;;
    *)
      echo "[ERROR] $sw: $d still holds files (find exit $rc): $(tr '\n' ' ' <<<"$names"); $ROLLED_BACK and every marker kept: run $sw again" >&2
      return 1 ;;
  esac
}

# rollback-reset (asyla #654): after rollback-stop, empty d05's copy so the cutover can start over.
# Its own approval; no value, no stdin, no ARG (exit 2). The M5 path only. Refused (exit 3, nothing
# changed) on a replica, APP_ROOT the NAS share or below it, a symlink among cutover-state/ and the
# dirs, the lock busy, any mirror-path marker, no rolled-back marker (a regular file), compose
# unable to tell or an openldap, keycloak or ops one-shot container running, a dir that is not a
# dir, and APP_ROOT or a dir a mount point. Exit 1, nothing changed: mountpoint not on PATH or
# keycloak-db's image missing. Then: compose rm -f keycloak and openldap (checked gone); keycloak-db
# stopped (checked); each of rollback_reset_dirs emptied as root and checked (rollback_reset_dir);
# then every ROLLBACK_RESET_MARKERS marker removed, rolled-back last; fetched, the ciphertext,
# openldap-tls/, ca/ and the NAS mirror are never touched. A failure: exit 1 with rolled-back kept,
# so a re-run picks up where it stopped. Allowed after cutover-done (the 3-day window). Next
# (README): the build's apps phase (up re-creates keycloak-db on its empty data dir), then
# unpack-bundle again (or cutover-clean and fetch-bundle for a new bundle).
do_rollback_reset() {
  local sw=rollback-reset d m ids ra="" rn="" dirs=()
  if [ $# -ne 0 ]; then
    echo "[ERROR] $sw: usage: $sw (no ARG)" >&2
    return 2
  fi
  if is_replica; then
    echo "[ERROR] $sw: refused: not on a replica ($(hostname -s </dev/null)); the cutover is d05's; nothing changed" >&2
    return 3
  fi
  # Never the NAS: APP_ROOT, as given and resolved, is not the share or below it (as reset-mirror).
  if [ -d "$APP_ROOT" ]; then ra="$(cd "$APP_ROOT" 2>/dev/null && pwd -P)" || ra=""; fi
  if [ -d "$DOCKER_D1" ]; then rn="$(cd "$DOCKER_D1" 2>/dev/null && pwd -P)" || rn=""; fi
  if path_under "$APP_ROOT" "$DOCKER_D1" || path_under "$ra" "$DOCKER_D1" || path_under "$ra" "$rn"; then
    echo "[ERROR] $sw: refused: $APP_ROOT${ra:+ ($ra)} is the NAS share $DOCKER_D1 or below it; $sw never deletes there; nothing changed" >&2
    return 3
  fi
  while IFS= read -r d; do dirs+=("$d"); done < <(rollback_reset_dirs)
  refuse_symlinks "$sw" "$STATE_DIR" "${dirs[@]}" || return
  cutover_lock "$sw" || return
  refuse_mirror_path "$sw" || return
  if [ ! -f "$STATE_DIR/$ROLLED_BACK" ] || [ -L "$STATE_DIR/$ROLLED_BACK" ]; then
    echo "[ERROR] $sw: refused: no $STATE_DIR/$ROLLED_BACK (run rollback-stop first: it stands keycloak and openldap down); nothing changed" >&2
    return 3
  fi
  if ! ids="$(run_compose --profile restored --profile ops ps -q openldap keycloak keycloak-backup openldap-backup keycloak-configure </dev/null)"; then
    echo "[ERROR] $sw: refused: docker compose ps for openldap, keycloak and the ops one-shots failed (cannot tell whether one runs); nothing changed" >&2
    return 3
  fi
  if [ -n "$ids" ]; then
    echo "[ERROR] $sw: refused: an openldap, keycloak or ops one-shot container is running (rollback-stop first); nothing changed" >&2
    return 3
  fi
  for d in "${dirs[@]}"; do
    if [ -e "$d" ] && [ ! -d "$d" ]; then
      echo "[ERROR] $sw: refused: $d is not a directory; nothing changed" >&2
      return 3
    fi
  done
  if ! command -v mountpoint >/dev/null 2>&1; then
    echo "[ERROR] $sw: mountpoint (util-linux) is not on PATH; cannot tell a mount from a dir; nothing changed" >&2
    return 1
  fi
  for d in "$APP_ROOT" "${dirs[@]}"; do
    if [ -e "$d" ] && mountpoint -q "$d" </dev/null; then
      echo "[ERROR] $sw: refused: $d is a mount point ($sw empties only plain dirs on the data disk; a mount could be the NAS share); nothing changed" >&2
      return 3
    fi
  done
  if ! docker image inspect "$KC_DB_IMAGE" >/dev/null 2>&1 </dev/null; then
    echo "[ERROR] $sw: keycloak-db's image ($KC_DB_IMAGE) is not here, so the root-owned files cannot be removed; nothing changed" >&2
    return 1
  fi
  echo "[INFO] $sw: removing the keycloak and openldap containers"
  if ! run_compose --profile restored rm -f keycloak openldap </dev/null; then
    echo "[ERROR] $sw: docker compose rm -f keycloak openldap failed; nothing emptied; $ROLLED_BACK kept" >&2
    return 1
  fi
  if ! ids="$(run_compose --profile restored ps -a -q keycloak openldap </dev/null)" || [ -n "$ids" ]; then
    echo "[ERROR] $sw: a keycloak or openldap container is still there (or compose cannot tell); nothing emptied; $ROLLED_BACK kept" >&2
    return 1
  fi
  echo "[INFO] $sw: stopping keycloak-db (its data dir is emptied next)"
  if ! run_compose stop keycloak-db </dev/null; then
    echo "[ERROR] $sw: docker compose stop keycloak-db failed; nothing emptied; $ROLLED_BACK kept" >&2
    return 1
  fi
  if ! ids="$(run_compose ps -q keycloak-db </dev/null)" || [ -n "$ids" ]; then
    echo "[ERROR] $sw: keycloak-db is still running (or compose cannot tell); nothing emptied; $ROLLED_BACK kept" >&2
    return 1
  fi
  for d in "${dirs[@]}"; do
    rollback_reset_dir "$d" || return 1
  done
  for m in "${ROLLBACK_RESET_MARKERS[@]}" "$ROLLED_BACK"; do
    if ! rm -f "$STATE_DIR/$m" || [ -e "$STATE_DIR/$m" ] || [ -L "$STATE_DIR/$m" ]; then
      echo "[ERROR] $sw: could not remove $STATE_DIR/$m; run $sw again" >&2
      return 1
    fi
  done
  echo "[INFO] $sw: done: the keycloak and openldap containers removed, keycloak-db stopped, ${dirs[*]} empty (lost+found kept), no cutover marker but fetched; openldap-tls, ca, the bundle and the NAS mirror untouched. Next: the build's apps phase (up re-creates keycloak-db), then unpack-bundle (README)"
}

cutover_gate() {
  local m v fv need=() missing=() mir=() m5=() path=m5 what="cutover marker"
  refuse_rolled_back "$1" || return
  for m in "${MIRROR_PATH_MARKERS[@]}"; do [ ! -e "$STATE_DIR/$m" ] && [ ! -L "$STATE_DIR/$m" ] || mir+=("$m"); done
  for m in "${M5_PATH_MARKERS[@]}"; do [ ! -e "$STATE_DIR/$m" ] && [ ! -L "$STATE_DIR/$m" ] || m5+=("$m"); done
  if [ ${#mir[@]} -gt 0 ]; then
    if [ ${#m5[@]} -gt 0 ]; then
      echo "[ERROR] $1: refused: cutover-state/ mixes the mirror path (${mir[*]}) and the M5 cutover path (${m5[*]}) (in $STATE_DIR); nothing done" >&2
      return 3
    fi
    path=mirror what="mirror-path marker"
  fi
  case "$path:$1" in
    mirror:start-openldap) need=("${MIRROR_PATH_MARKERS[@]}") ;;
    mirror:start-keycloak) need=("${MIRROR_PATH_MARKERS[@]}" started-openldap) ;;
    mirror:configure) need=("${MIRROR_PATH_MARKERS[@]}" started-openldap started-keycloak) ;;
    mirror:check-reset-off) need=("${MIRROR_PATH_MARKERS[@]}" started-openldap started-keycloak configured) ;;
    mirror:cutover-done) need=("${MIRROR_PATH_MARKERS[@]}" started-openldap started-keycloak configured reset-off) ;;
    mirror:restore-keycloak|mirror:restore-openldap|mirror:count-check)
      echo "[ERROR] $1: refused: $1 is an M5 cutover switch and cutover-state/ is on the mirror path (${mir[*]}) (in $STATE_DIR); nothing done" >&2
      return 3 ;;
    m5:start-openldap) need=(unpacked restored-openldap) ;;
    m5:start-keycloak) need=(unpacked restored-keycloak started-openldap) ;;
    m5:configure) need=(restored-openldap restored-keycloak started-openldap started-keycloak) ;;
    m5:check-reset-off) need=(restored-openldap restored-keycloak started-openldap started-keycloak configured) ;;
    m5:count-check) need=(unpacked restored-openldap restored-keycloak started-openldap started-keycloak configured reset-off) ;;
    m5:cutover-done) need=(unpacked restored-openldap restored-keycloak started-openldap started-keycloak configured reset-off counted) ;;
    m5:restore-keycloak|m5:restore-openldap) need=(unpacked) ;;
    *) echo "[ERROR] cutover_gate: no gate for $1" >&2; return 3 ;;
  esac
  for m in "${need[@]}"; do
    if [ ! -f "$STATE_DIR/$m" ]; then
      missing+=("$m")
    elif [ ! -s "$STATE_DIR/$m" ]; then
      missing+=("$m (empty)")
    elif [ "$m" = mirror-restored-openldap ] || [ "$m" = mirror-restored-keycloak ]; then
      mirror_marker_ok "${m#mirror-restored-}" || missing+=("$m (not a valid marker)")
    elif [ "$m" = mirror-checked ]; then
      mirror_checked_ok || missing+=("mirror-checked (not summaries equal for these mirror-restored-* markers)")
    elif [ "$m" = unpacked ]; then
      v="$(state_value unpacked version)" fv="$(state_value fetched version)"
      [ -n "$v" ] && [ "$v" = "$fv" ] || missing+=("unpacked (version '$v' is not fetched's '$fv')")
    elif [ "$m" = started-openldap ] && ! grep -qx 'admin-bind ok' "$STATE_DIR/$m"; then
      missing+=("started-openldap (no admin-bind ok)")
    elif [ "$m" = configured ] && ! { grep -qx 'apply ok' "$STATE_DIR/$m" && grep -qx 'reconcile ok' "$STATE_DIR/$m"; }; then
      missing+=("configured (no apply ok and reconcile ok)")
    elif [ "$m" = reset-off ] && ! grep -qx 'resetPasswordAllowed false' "$STATE_DIR/$m"; then
      missing+=("reset-off (no resetPasswordAllowed false)")
    elif [ "$m" = counted ] && ! grep -qx 'counts equal' "$STATE_DIR/$m"; then
      missing+=("counted (no counts equal)")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "[ERROR] $1: refused: $what missing or invalid: ${missing[*]} (in $STATE_DIR); nothing done" >&2
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
  echo "  check-reset-off - M5 step 6, after configure: keycloak-configure check-reset-off (read-only: realm" >&2
  echo "                    theorg's resetPasswordAllowed must be false); reads IDP_DEPLOY_DEX_CLIENT_SECRET's" >&2
  echo "                    value as one line on stdin (scripts/app_switch.sh); keycloak must be healthy;" >&2
  echo "                    needs configure's markers and configured; writes reset-off on 0, which" >&2
  echo "                    count-check and cutover-done need; else its exit, no marker. Runs alone. Not on a replica" >&2
  echo "  count-check     - M5 step 7: keycloak-backup backup into the empty count-check/ (keycloak-db's" >&2
  echo "                    password from the running container, on its stdin), then its summary.txt's" >&2
  echo "                    realm, users, clients, credentials and changesets lines compared with" >&2
  echo "                    backup/summary.txt's; equal: writes counted, exit 0; not equal: exit 1, both" >&2
  echo "                    differing line sets printed. backup/summary.txt's sha256 must be unpacked's" >&2
  echo "                    keycloak-summary-sha256 (else exit 1, no backup); count-check/ keeps only" >&2
  echo "                    summary.txt after. No value, no ARG; needs unpacked, both restored-*," >&2
  echo "                    both started-*, configured and reset-off. Runs alone. Not on a replica" >&2
  echo "  cutover-done    - M5: record the go-live after the cutover's verification; no value, no ARG; needs" >&2
  echo "                    every marker (unpacked, both restored-*, both started-*, configured, reset-off," >&2
  echo "                    counted) and" >&2
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
  echo "                    replica or with the cutover lock busy. Runs alone" >&2
  echo "  restore-mirror  - After a rebuild (asyla #1101): restore both copies from the NAS mirror" >&2
  echo "                    ($MIRROR_DIR): each staged and checked, copied into the empty target, then" >&2
  echo "                    theOrg's restore; writes mirror-restored-openldap and mirror-restored-keycloak" >&2
  echo "                    (a valid one is skipped). No value, no ARG. Refused (exit 3) past any M5 marker," >&2
  echo "                    with a container or data present, keycloak-db unhealthy, the NAS unmounted, a" >&2
  echo "                    STATUS not OK, or a mirror older than 48 hours. Runs alone. Also on a replica" >&2
  echo "  restore-mirror-accept-age - restore-mirror, restoring a mirror older than 48 hours, a STATUS in the future or copies over 2 hours apart too (with a warning)" >&2
  echo "  reset-mirror    - After a failed restore-mirror: each copy whose restore did not finish has its dirs" >&2
  echo "                    emptied as root and removed (keycloak: keycloak-db stopped first, its data dir" >&2
  echo "                    too), then its marker and stage; a valid mirror-restored-* is never touched." >&2
  echo "                    Refused past mirror-checked, a start or any M5 marker. Next: for keycloak the" >&2
  echo "                    build's up, then restore-mirror. No value, no ARG. Runs alone. Also on a replica" >&2
  echo "  mirror-check    - After restore-mirror: fresh openldap-backup and keycloak-backup backups into the" >&2
  echo "                    emptied openldap-count-check/ and count-check/ (each keeps only summary.txt after)," >&2
  echo "                    compared with the restored summaries (openldap's whole summary; keycloak's realm," >&2
  echo "                    users, clients, credentials and changesets lines); equal: writes mirror-checked," >&2
  echo "                    which start-openldap, start-keycloak, configure, check-reset-off and cutover-done then take in place" >&2
  echo "                    of unpacked, both restored-* and counted; not equal: exit 1. No value, no ARG;" >&2
  echo "                    needs both mirror-restored-*, no M5 or later marker, keycloak-db healthy. Runs alone." >&2
  echo "                    Also on a replica" >&2
  echo "  rollback-stop   - M5, after a rollback to the Mini: stop keycloak, then openldap (containers, volumes," >&2
  echo "                    data and markers kept; keycloak-db runs on); writes rolled-back, which refuses the" >&2
  echo "                    starts, restores, configure, check-reset-off, count-check, cutover-done and backup" >&2
  echo "                    (3) and up past cutover-done (1). Needs a restored-* or started-* marker; refused on" >&2
  echo "                    the mirror path. Idempotent. No value, no ARG. Runs alone. Not on a replica" >&2
  echo "  rollback-reset  - M5, after rollback-stop: remove the keycloak and openldap containers, stop" >&2
  echo "                    keycloak-db, empty backup/, openldap-backup/, openldap-data/, openldap-config/," >&2
  echo "                    keycloak-db/, count-check/ and openldap-count-check/ as root (lost+found kept), then" >&2
  echo "                    every cutover marker but fetched; never openldap-tls, ca, the bundle or the NAS" >&2
  echo "                    mirror. Needs rolled-back and nothing running. Next: the build's apps phase, then" >&2
  echo "                    unpack-bundle. No value, no ARG. Runs alone. Not on a replica" >&2
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
  check-reset-off)
    do_check_reset_off "${@:2}" || exit $?
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
  restore-mirror)
    do_restore_mirror false "${@:2}" || exit $?
    exit 0
    ;;
  restore-mirror-accept-age)
    do_restore_mirror true "${@:2}" || exit $?
    exit 0
    ;;
  reset-mirror)
    do_reset_mirror "${@:2}" || exit $?
    exit 0
    ;;
  mirror-check)
    do_mirror_check "${@:2}" || exit $?
    exit 0
    ;;
  rollback-stop)
    do_rollback_stop "${@:2}" || exit $?
    exit 0
    ;;
  rollback-reset)
    do_rollback_reset "${@:2}" || exit $?
    exit 0
    ;;
esac

# leaf-issue runs alone: its stdin carries the provisioner password, and no other switch's
# children may run before it holding that pipe. So do the cutover switches (stdin or ARGs).
if [ $# -gt 1 ]; then
  for cmd in "$@"; do
    case "$cmd" in
      leaf-issue|fetch-bundle|unpack-bundle|reset-cutover|cutover-clean|restore-keycloak|restore-openldap|start-openldap|start-keycloak|configure|check-reset-off|count-check|cutover-done|backup|restore-mirror|restore-mirror-accept-age|reset-mirror|mirror-check|rollback-stop|rollback-reset)
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
