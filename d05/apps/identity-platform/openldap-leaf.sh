#!/usr/bin/env bash
# The directory's TLS leaf on d05 (ldap.asyla.org; SANs ldap.asyla.org, openldap), from step-ca's
# JWK provisioner `ldap` (certificate-management DEPLOY.md), into ${IDENTITY_PLATFORM_ROOT}/openldap-tls.
# A host script, copied to d05 by asyla as Caddyfile.example is (DEPLOY.md, "Production on d05:
# directory (R10)", is the contract; tests/test_openldap_leaf.py holds it).
#
#     LDAP_PROVISIONER_PASSWORD=... openldap-leaf.sh issue   # first leaf, or one that is no longer valid
#     openldap-leaf.sh renew                                  # every 3h: renew at half life, reload slapd
#
# issue: the deployer reads secret/v2/certificate-management/step-ca/provisioners/ldap (field
#   `password`) from OpenBao in its own process and hands it over in this script's environment.
#   It reaches docker by name (`-e LDAP_PROVISIONER_PASSWORD`) and step on stdin
#   (`--provisioner-password-file /dev/stdin`, fed by bash's builtin printf): never an argv, a file
#   or a log. Docker keeps the value in the one-off's configuration while it exists; `--rm` removes
#   it when step ends. Refused while openldap-tls holds a leaf that is still valid (renew it).
#   Run it before openldap's first start: osixia/openldap 1.5.0 makes a self-signed leaf when both
#   ldap.crt and ldap.key are missing.
#   The final renames (ldap.key, then ldap.crt, then ca.crt) are each atomic, the three together
#   are not: the marker openldap-tls/.openldap-leaf-swap stays until the last is done. An issue
#   stopped between them is reported (exit 1), renew refuses while the marker is there, and the
#   next issue runs even over an ldap.crt that verifies.
# renew: no provisioner secret (refused when LDAP_PROVISIONER_PASSWORD is set). First the leaf on
#   disk must verify against ${IDENTITY_PLATFORM_ROOT}/ca/root_ca.crt for ldap.asyla.org, as for
#   issue's refusal: one that does not (osixia's self-signed leaf when openldap started before
#   issue, another name, or expired) is refused, exit 3 (run issue). Then step-ca renews over mTLS
#   with the current leaf once half its life is gone (`needs-renewal --expires-in 50%`; operator
#   2026-10-10: renew at half life, keep leaves short). The leaf stays 24h. A failed renewal is
#   exit 1: retry or repair the CA while the leaf still verifies, run issue once it has expired.
# Both, after any change and on every renew run: when openldap runs (compose labels project
#   identity-platform, service openldap) and the leaf it serves is not the one on disk, slapd is told
#   to reload it with an `ldapmodify` over ldapi:/// that replaces olcTLSCertificateFile and
#   olcTLSCertificateKeyFile with their current values (slapd 2.4.57 reloads on that change and does
#   not watch the files: measured 2026-10-10, AGENTS.md "TLS leaf renewal at half life"). No restart.
#   Still different afterwards: exit 1.
# One run at a time: an exclusive flock(1) (util-linux) on ${IDENTITY_PLATFORM_ROOT}/.openldap-leaf.lock,
#   held until the script exits, so a scheduled renew and an issue by hand never write the same
#   .new files. A run that finds it held is refused (exit 3); without flock nothing runs (exit 1).
#
# step runs in the pinned smallstep/step-cli (multi-arch index digest) on identity-platform-net
# (egress to ca.asyla.org), as root so that it can write files the image's openldap user (911)
# owns. Each new file is written as a .new beside its target, given its owner (911:911) and mode
# (ldap.key 0600, ldap.crt and ca.crt 0644), and only then renamed over the target: a chown that
# fails (userns-remap, rootless docker, root squash) replaces nothing. No `docker compose`: every
# compose command needs LDAP_ADMIN_PASSWORD, and this needs no directory secret.
#
# Environment: IDENTITY_PLATFORM_ROOT (required), STEP_CA_URL (default https://ca.asyla.org:9000),
# the root at ${IDENTITY_PLATFORM_ROOT}/ca/root_ca.crt. A lab may set OPENLDAP_LEAF_NETWORK and
# OPENLDAP_LEAF_PROJECT (defaults identity-platform-net, identity-platform).
# Exit: 0 done (or nothing due); 1 a step failed; 2 usage; 3 refused.
set -euo pipefail

STEP_CLI_IMAGE="smallstep/step-cli:0.30.2@sha256:c75414251d4d8234945fb01e1374707dcc6a7adced88679bae4f0fd526331e74"
LEAF_NAME="ldap.asyla.org"
SANS="ldap.asyla.org openldap"
NOT_AFTER="24h"
RENEW_AT="50%"
SWAP=".openldap-leaf-swap"
# Inside the openldap container (osixia/openldap 1.5.0, LDAP_TLS_*_FILENAME in the compose example).
SERVED="openldap:636"

say() { printf 'openldap-leaf: %s\n' "$*" >&2; }
die() { local code="$1"; shift; say "$*"; exit "$code"; }

usage() { say "usage: openldap-leaf.sh issue|renew (issue needs LDAP_PROVISIONER_PASSWORD)"; exit 2; }

[ "$#" -eq 1 ] || usage
MODE="$1"
case "$MODE" in issue|renew) ;; *) usage ;; esac

ROOT="${IDENTITY_PLATFORM_ROOT:-}"
[ -n "$ROOT" ] || die 2 "IDENTITY_PLATFORM_ROOT is not set"
CA_URL="${STEP_CA_URL:-https://ca.asyla.org:9000}"
NETWORK="${OPENLDAP_LEAF_NETWORK:-identity-platform-net}"
PROJECT="${OPENLDAP_LEAF_PROJECT:-identity-platform}"
TLS_DIR="$ROOT/openldap-tls"
CA_DIR="$ROOT/ca"
LOCK="$ROOT/.openldap-leaf.lock"
[ -d "$TLS_DIR" ] || die 1 "no directory $TLS_DIR"
[ -f "$CA_DIR/root_ca.crt" ] || die 1 "no step-ca root at $CA_DIR/root_ca.crt"

# The lock, on fd 9 for the rest of the run.
command -v flock >/dev/null 2>&1 || die 1 "flock (util-linux) is not on PATH: refusing to run without the lock"
exec 9>>"$LOCK" || die 1 "cannot open the lock file $LOCK"
flock -n 9 || die 3 "refused: another openldap-leaf.sh run holds $LOCK; try again once it has ended"

# One-off step-cli: openldap-tls read-write at /certs, ca/ read-only at /ca, as root.
step_run() {
  local net="$1"; shift
  docker run --rm --network "$net" --user 0 --cpus 1 \
    -v "$TLS_DIR:/certs" -v "$CA_DIR:/ca:ro" "$@"
}

# A leaf on disk that verifies against the root, for ldap.asyla.org, now.
leaf_valid() {
  step_run none "$STEP_CLI_IMAGE" step certificate verify /certs/ldap.crt \
    --roots /ca/root_ca.crt --host "$LEAF_NAME" >/dev/null 2>&1
}

# 0 when an earlier issue stopped between its renames (the marker is there), 1 when not.
swap_left() {
  local rc=0
  step_run none "$STEP_CLI_IMAGE" test -e "/certs/$SWAP" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) die 1 "could not look for $TLS_DIR/$SWAP (exit $rc)" ;;
  esac
}

needs_renewal() {
  step_run none "$STEP_CLI_IMAGE" step certificate needs-renewal /certs/ldap.crt --expires-in "$RENEW_AT" \
    >/dev/null 2>&1
}

issue() {
  [ -n "${LDAP_PROVISIONER_PASSWORD:-}" ] || die 3 "issue needs LDAP_PROVISIONER_PASSWORD in the environment (OpenBao secret/v2/certificate-management/step-ca/provisioners/ldap, field password)"
  if swap_left; then
    say "an earlier issue stopped between its renames ($TLS_DIR/$SWAP): issuing again"
  elif leaf_valid; then
    die 3 "refused: $TLS_DIR/ldap.crt is a valid leaf for $LEAF_NAME; renew it instead"
  fi
  local sans=() s rc=0
  for s in $SANS; do sans+=(--san "$s"); done
  say "issuing $LEAF_NAME (${NOT_AFTER}) from $CA_URL"
  # shellcheck disable=SC2016  # expanded inside the container, not here
  step_run "$NETWORK" -e LDAP_PROVISIONER_PASSWORD "$STEP_CLI_IMAGE" bash -c '
      set -euo pipefail
      umask 077
      rm -f /certs/ldap.crt.new /certs/ldap.key.new /certs/ca.crt.new
      printf "%s" "$LDAP_PROVISIONER_PASSWORD" | step ca certificate "$1" /certs/ldap.crt.new /certs/ldap.key.new \
        --provisioner ldap --provisioner-password-file /dev/stdin --not-after "$2" \
        --ca-url "$3" --root /ca/root_ca.crt --force "${@:5}"
      cp /ca/root_ca.crt /certs/ca.crt.new
      chown 911:911 /certs/ldap.crt.new /certs/ldap.key.new /certs/ca.crt.new
      chmod 0600 /certs/ldap.key.new
      chmod 0644 /certs/ldap.crt.new /certs/ca.crt.new
      # Every file is complete and owned; the renames are the one window (see the header).
      : > "/certs/$4"
      mv -f /certs/ldap.key.new /certs/ldap.key
      mv -f /certs/ldap.crt.new /certs/ldap.crt
      mv -f /certs/ca.crt.new /certs/ca.crt
      rm -f "/certs/$4"
      ' _ "$LEAF_NAME" "$NOT_AFTER" "$CA_URL" "$SWAP" "${sans[@]}" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if swap_left; then
      die 1 "issue stopped between its renames (exit $rc): ldap.key may not match ldap.crt; run issue again"
    fi
    die 1 "issue failed (exit $rc) before replacing any file: step-ca at $CA_URL unreachable or refused, or the owner 911:911 could not be set (userns-remap, rootless docker, root squash)"
  fi
  say "issued: $TLS_DIR/ldap.crt"
}

renew() {
  [ -z "${LDAP_PROVISIONER_PASSWORD+x}" ] || die 3 "refused: renew needs no provisioner password; unset LDAP_PROVISIONER_PASSWORD"
  local rc=0
  if swap_left; then
    die 3 "refused: an earlier issue stopped between its renames ($TLS_DIR/$SWAP), so ldap.key may not match ldap.crt: run issue"
  fi
  if ! leaf_valid; then
    needs_renewal || rc=$?
    [ "$rc" -ne 2 ] || die 3 "no leaf at $TLS_DIR/ldap.crt: run issue"
    die 3 "refused: $TLS_DIR/ldap.crt does not verify against $CA_DIR/root_ca.crt for $LEAF_NAME (expired, another issuer such as osixia's self-signed leaf, or another name): run issue"
  fi
  needs_renewal || rc=$?
  case "$rc" in
    0)
      say "due (${RENEW_AT} of its life left or less): renewing from $CA_URL"
      # shellcheck disable=SC2016  # expanded inside the container, not here
      step_run "$NETWORK" "$STEP_CLI_IMAGE" bash -c '
          set -euo pipefail
          umask 077
          rm -f /certs/ldap.crt.new
          step ca renew /certs/ldap.crt /certs/ldap.key --out /certs/ldap.crt.new \
            --ca-url "$1" --root /ca/root_ca.crt --force
          chown 911:911 /certs/ldap.crt.new
          chmod 0644 /certs/ldap.crt.new
          mv -f /certs/ldap.crt.new /certs/ldap.crt
          ' _ "$CA_URL" || rc=$?
      if [ "$rc" -ne 0 ]; then
        if leaf_valid; then
          die 1 "renew failed (exit $rc), nothing replaced; $TLS_DIR/ldap.crt still verifies, so it has not expired: step-ca at $CA_URL unreachable or refused, or the owner 911:911 could not be set; retry, or repair the CA"
        fi
        die 1 "renew failed (exit $rc) and $TLS_DIR/ldap.crt no longer verifies (expired): run issue"
      fi
      say "renewed: $TLS_DIR/ldap.crt" ;;
    1) say "not due" ;;
    2) die 3 "no leaf at $TLS_DIR/ldap.crt: run issue" ;;
    *) die 1 "needs-renewal failed (exit $rc)" ;;
  esac
}

openldap_container() {
  local ids n
  ids="$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=openldap")" || die 1 "docker ps failed"
  n="$(printf '%s\n' "$ids" | grep -c . || true)"
  [ "$n" -le 1 ] || die 1 "more than one running openldap container in project $PROJECT"
  printf '%s' "$ids"
}

file_fingerprint() {
  step_run none "$STEP_CLI_IMAGE" step certificate fingerprint /certs/ldap.crt
}

served_fingerprint() {
  # A read of what slapd presents, not a trust decision: an expired or wrong leaf must still be
  # read so that it can be replaced.
  step_run "$NETWORK" "$STEP_CLI_IMAGE" step certificate fingerprint "https://$SERVED" \
    --servername "$LEAF_NAME" --insecure
}

# The LDIF that replaces both TLS file attributes with the values slapd already has.
reload_ldif() {
  local c="$1" cur crt key
  cur="$(docker exec "$c" ldapsearch -Y EXTERNAL -H ldapi:/// -Q -LLL -o ldif-wrap=no \
    -b cn=config -s base olcTLSCertificateFile olcTLSCertificateKeyFile)" \
    || die 1 "could not read cn=config's TLS settings in $c"
  crt="$(printf '%s\n' "$cur" | sed -n 's/^olcTLSCertificateFile: //p')"
  key="$(printf '%s\n' "$cur" | sed -n 's/^olcTLSCertificateKeyFile: //p')"
  [ -n "$crt" ] && [ -n "$key" ] || die 1 "cn=config in $c has no olcTLSCertificateFile/KeyFile"
  printf 'dn: cn=config\nchangetype: modify\nreplace: olcTLSCertificateFile\nolcTLSCertificateFile: %s\n-\nreplace: olcTLSCertificateKeyFile\nolcTLSCertificateKeyFile: %s\n-\n' "$crt" "$key"
}

sync_served() {
  local c want got ldif i
  c="$(openldap_container)"
  if [ -z "$c" ]; then
    say "openldap is not running: it reads the leaf at its next start"
    return 0
  fi
  want="$(file_fingerprint)" || die 1 "could not read the fingerprint of $TLS_DIR/ldap.crt"
  got="$(served_fingerprint || true)"
  if [ "$got" = "$want" ]; then
    say "openldap serves the leaf on disk ($want)"
    return 0
  fi
  say "openldap serves ${got:-nothing readable}, the file is $want: reloading slapd's TLS settings"
  ldif="$(reload_ldif "$c")"
  printf '%s\n' "$ldif" | docker exec -i "$c" ldapmodify -Y EXTERNAL -H ldapi:/// -Q >/dev/null \
    || die 1 "ldapmodify in $c failed"
  for i in 1 2 3 4 5; do
    got="$(served_fingerprint || true)"
    if [ "$got" = "$want" ]; then
      say "openldap now serves $want (no restart)"
      return 0
    fi
    sleep 1
  done
  die 1 "openldap still serves ${got:-nothing readable} after the reload, not $want"
}

"$MODE"
sync_served
