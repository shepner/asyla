#!/bin/bash
# Proof of identity-platform's rebuild path (asyla #1101; d05/apps/identity-platform/README.md,
# "Rebuild from the nas01 mirror (#1101)") on test01 built as a d05 replica: `restore-mirror` and then
# `mirror-check` restore both copies from a copy of the nas01 mirror and compare fresh summaries with
# the restored ones. The operator allowed production identity data on test01 for this proof, with
# test01 destroyed afterwards ("Yes, then destroy", 2026-11-21): it holds Keycloak's signing keys and
# the directory's password hashes once restore-mirror ran, so this wrapper destroys test01 at the end,
# pass or fail (`build_host.py test01 destroy --apply`; test01 is disposable).
#
# Which mirror. The replica mounts the NAS read-only (build/setup/nfs.sh), so d05's mirror
# /mnt/nas/data1/docker/IdentityPlatform/mirror can only be read here. The proof does not even read
# it in place: it copies both copies from the read-only mount into a tmpfs under its temp dir, adds a
# stand-in file to each that no manifest names (the restore must leave it out), remounts the tmpfs
# read-only, and runs identity-platform.sh with a common.env whose DOCKER_D1 is that tmpfs. The
# production mirror is never an input; its manifest.sha256 and STATUS hashes and its size/mtime
# listing are taken before and after and must be equal. d05's nightly backup writes that mirror:
# run the proof outside it, or a difference may be d05's own (read d05's host-maintenance history).
#
# Asserted: restore-mirror exits 0 and writes mirror-restored-openldap and mirror-restored-keycloak
# (`source mirror`, the copy's STATUS line, its summary.txt sha256); the stand-ins reach no dir under
# /mnt/docker/IdentityPlatform; mirror-check exits 0 and writes mirror-checked (`summaries equal`, the
# two summary sha256s equal to the copy's); a second restore-mirror exits 3 and changes no marker;
# the copy and the production mirror are unchanged.
#
# Not proven (a replica runs neither, and gets no secret): leaf-issue, start-openldap (the copy's
# admin bind), start-keycloak, configure, cutover-done, and d05's own updater (test01 runs its own).
#
# Before it, in this order (each the operator's; test01 must be a fresh build, never a re-used one):
#   1. This branch on GitLab master (the replica runs ~/scripts/d05 as test01's updater installs it
#      from master; the proof refuses when that identity-platform.sh is not this checkout's).
#   2. Destroy the test01 that exists, while this checkout's test01/host.toml is still the hello spec,
#      so its Gitea and GitLab runner entries go with it (a replica spec has no runner to delete);
#      "no such VM" when there is none:
#        cd ~/local/asyla && python3 core/tools/credentials.py exec GITLAB_TOKEN GITEA_TOKEN ASYLA_HOSTS_DEPLOY_USER ASYLA_HOSTS_DEPLOY_TOKEN -- python3 projects/asyla-hosts/scripts/build_host.py test01 destroy --apply
#   3. A commit on master that makes test01 a d05 replica, reverted after the proof (as the ns01 and
#      ns02 proofs, 67a7a3b / 698ef60), pulled into this checkout: in test01/host.toml, remove the
#      hello [[secret]]s, [host_maintenance], the hello [[app]], [[external]], [runner],
#      [[gitlab_runner.runners]] and [node_exporter].textfile_sources, and add
#        [replica]
#        of = "d05"
#        start_apps = true          # up starts keycloak-db with a throwaway password
#        apps = ["identity-platform"]
#      The wrapper refuses unless this checkout's test01/host.toml says that.
#   4. Build test01 fresh (memory: a retry starts from a destroyed test01, never a re-used one):
#        cd ~/local/asyla && python3 core/tools/credentials.py exec GITLAB_TOKEN GITEA_TOKEN ASYLA_HOSTS_DEPLOY_USER ASYLA_HOSTS_DEPLOY_TOKEN THEORG_REGISTRY_PULL_TOKEN -- python3 projects/asyla-hosts/scripts/build_host.py test01 build --apply
#      (identity-platform's pull_token_env names THEORG_REGISTRY_PULL_TOKEN, for the replica's image
#      pull before its egress is blocked.) Accept test01's new host key for docker@test01 after the build.
#      A retry of the proof is: the wrapper's own destroy (below), then this build again.
#
# Usage, from the workstation (no secret: the proof reads none):
#   cd ~/local/asyla/projects/asyla-hosts && scripts/tests/test_identity_platform_mirror_restore_test01.sh [--accept-age]
#
#   --accept-age   run restore-mirror-accept-age instead of restore-mirror (the mirror is older than
#                  48 hours; say so in the report).
#
# Afterwards: revert the replica commit on master. The log is under
# ~/.local/state/asyla/d05-1101/. Exit 0 when every case passed, 1 when one failed or the destroy
# failed, 2 when refused before test01 was touched. The on-host part refuses to run anywhere but
# test01.

set -uo pipefail

SELF=scripts/tests/test_identity_platform_mirror_restore_test01.sh
IP_REL=d05/apps/identity-platform/identity-platform.sh

if [ "${1:-}" != "--on-host" ]; then
  RESTORE_SW=restore-mirror
  case "${1:-}" in
    "") ;;
    --accept-age) RESTORE_SW=restore-mirror-accept-age ;;
    *) echo "usage: $0 [--accept-age]" >&2; exit 2 ;;
  esac
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  if ! python3 -c 'import sys, tomllib
r = tomllib.load(open(sys.argv[1], "rb")).get("replica", {})
sys.exit(0 if r.get("of") == "d05" and "identity-platform" in r.get("apps", ["identity-platform"]) else 1)' \
      "$REPO/test01/host.toml"; then
    echo "test01/host.toml here is not [replica] of = \"d05\" with identity-platform: refusing (see the header, step 2)" >&2
    exit 2
  fi
  want="$(shasum -a 256 "$REPO/$IP_REL" | cut -d' ' -f1)"
  logdir="$HOME/.local/state/asyla/d05-1101"
  mkdir -p "$logdir" || exit 2
  log="$logdir/test01-proof-$(date -u +%Y%m%dT%H%M%SZ).log"
  echo "log: $log"
  COPYFILE_DISABLE=1 tar -C "$REPO" -cf - "$SELF" |
    ssh -o BatchMode=yes -o ConnectTimeout=10 -i ~/.ssh/docker_rsa docker@test01 "
      set -e
      [ \"\$(hostname -s)\" = test01 ] || { echo 'not test01: refusing' >&2; exit 2; }
      D=\$(mktemp -d /tmp/idp-mirror-proof.XXXXXX)
      tar -C \"\$D\" -xf - 2>/dev/null
      exec bash \"\$D/$SELF\" --on-host \"\$D\" $want $RESTORE_SW" 2>&1 | tee "$log"
  rc=${PIPESTATUS[1]}
  echo "proof exit: $rc" | tee -a "$log"
  # The operator's "Yes, then destroy": pass or fail, test01 holds production identity data now.
  echo "destroying test01 (build_host.py test01 destroy --apply)" | tee -a "$log"
  if ! (cd "$REPO" && python3 scripts/build_host.py test01 destroy --apply) 2>&1 | tee -a "$log"; then
    echo "FAIL  build_host.py test01 destroy failed: destroy test01 now (header, step 2's command)" | tee -a "$log"
    exit 1
  fi
  if (cd "$REPO" && python3 scripts/build_host.py test01 destroy --apply) 2>&1 | tee -a "$log" | grep -x 'no such VM' >/dev/null; then   # no -q: under pipefail an early exit could SIGPIPE tee
    echo "ok    test01 is destroyed (a second destroy finds no VM)" | tee -a "$log"
  else
    echo "FAIL  test01 still exists after the destroy: destroy it by hand now" | tee -a "$log"
    exit 1
  fi
  echo "next: revert the test01 replica commit on master" | tee -a "$log"
  exit "$rc"
fi

# ---- on test01 ----
D="$2" WANT_SHA="$3" RESTORE_SW="$4"
refuse() { echo "$1: refusing" >&2; exit 2; }
[ "$(hostname -s)" = test01 ] || refuse "not test01"
case "$D" in /tmp/idp-mirror-proof.*) ;; *) refuse "unexpected dir $D" ;; esac
[[ "$WANT_SHA" =~ ^[0-9a-f]{64}$ ]] || refuse "bad identity-platform.sh sha256 [$WANT_SHA]"
case "$RESTORE_SW" in restore-mirror|restore-mirror-accept-age) ;; *) refuse "bad switch [$RESTORE_SW]" ;; esac

REAL_HOME="$HOME"
IP_SH="$REAL_HOME/scripts/$IP_REL"
REAL_D1=/mnt/nas/data1/docker
REAL="$REAL_D1/IdentityPlatform/mirror"
APP_ROOT=/mnt/docker/IdentityPlatform
STATE="$APP_ROOT/cutover-state"
COPY_D1="$D/d1"
COPY="$COPY_D1/IdentityPlatform/mirror"
STANDIN=proof-standin-not-in-manifest.txt
MARKERS=(mirror-restored-openldap mirror-restored-keycloak mirror-checked)

# Set before the guards ($D is checked above), so a refusal below leaves no $D in /tmp either.
cleanup() {
  mountpoint -q "$COPY_D1" 2>/dev/null && sudo -n umount "$COPY_D1"
  rm -rf "$D"
  echo "cleanup: $D exists: $([ -e "$D" ] && echo yes || echo no); the restored data in $APP_ROOT goes with test01's destroy"
}
trap cleanup EXIT

[ -f "$IP_SH" ] || refuse "no $IP_SH (test01 is not a d05 replica)"
got="$(sha256sum "$IP_SH" | cut -d' ' -f1)"
[ "$got" = "$WANT_SHA" ] || refuse "$IP_SH is not this checkout's (sha256 ${got:0:12}, want ${WANT_SHA:0:12}): is the branch on master, and test01 built after it?"
findmnt -no OPTIONS "$REAL_D1" 2>/dev/null | tr ',' '\n' | grep -qx ro \
  || refuse "$REAL_D1 is not mounted read-only (a replica's NAS mount is: build/setup/nfs.sh)"
for n in openldap keycloak; do
  [ -f "$REAL/$n/STATUS" ] && [ -f "$REAL/$n/manifest.sha256" ] || refuse "$REAL/$n has no STATUS or manifest.sha256"
done
left="$(ls -A "$STATE" 2>/dev/null | grep -vx .lock || true)"
[ -z "$left" ] || refuse "$STATE holds $(echo "$left" | tr '\n' ' '): not a fresh build; destroy test01 and build it again"

mirror_state() {  # DIR: each copy's manifest.sha256 and STATUS sha256, then every entry with size and mtime
  local n
  for n in openldap keycloak; do
    sha256sum "$1/$n/manifest.sha256" "$1/$n/STATUS" 2>&1
  done
  find "$1" -printf '%P %s %T@\n' 2>&1 | sort
}
marker_state() { local m; for m in "${MARKERS[@]}"; do sha256sum "$STATE/$m" 2>&1; done; }
mval() { sed -n "s/^$2 //p" "$STATE/$1" 2>/dev/null | head -n 1; }   # mval MARKER KEY

fails=0
check() {  # check NAME CONDITION
  if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1: expected $2"; fails=$((fails + 1)); fi
}
run_ip() {  # run_ip SWITCH: RC and OUT; HOME is the temp one, so common.env's DOCKER_D1 is the copy
  OUT="$(HOME="$D/home" DOCKER_CONFIG="$REAL_HOME/.docker" bash "$IP_SH" "$1" </dev/null 2>&1)"
  RC=$?
  echo "      $1: exit $RC; its last lines:"
  tail -n 25 <<<"$OUT" | sed 's/^/        /'
}

echo "host: $(hostname -s); $IP_SH sha256 ${got:0:12}; $REAL_D1 mounted ro"
BEFORE="$(mirror_state "$REAL")"
echo "production mirror before: $(head -n 4 <<<"$BEFORE" | cut -c1-16 | tr '\n' ' ')($(wc -l <<<"$BEFORE") lines)"
for n in openldap keycloak; do echo "      $n STATUS: $(head -n 1 "$REAL/$n/STATUS")"; done

# The copy: a tmpfs this user can write, filled from the read-only mount, then made read-only.
size_mb="$(du -sm "$REAL" | cut -f1)"
[ "$size_mb" -lt 3000 ] || refuse "the mirror is ${size_mb} MB; the tmpfs copy is sized for under 3000"
mkdir "$COPY_D1" "$D/home" || exit 2
sudo -n mount -t tmpfs -o "size=$((size_mb * 2 + 256))m,mode=0755,uid=$(id -u),gid=$(id -g)" idp-mirror-copy "$COPY_D1" \
  || refuse "could not mount a tmpfs at $COPY_D1"
mkdir -p "$COPY" && cp -pR "$REAL/openldap" "$REAL/keycloak" "$COPY/" || refuse "could not copy $REAL"
for n in openldap keycloak; do
  (cd "$COPY/$n" && sha256sum --quiet -c manifest.sha256) || refuse "the copy of $n does not match its manifest"
  printf 'stand-in: no manifest names this file, so the restore must leave it out\n' > "$COPY/$n/$STANDIN" \
    || refuse "could not write the $n stand-in"
done
sudo -n mount -o remount,ro "$COPY_D1" || refuse "could not remount $COPY_D1 read-only"
check "the copy is read-only (a write is refused)" '! touch "$COPY_D1/.probe" 2>/dev/null'
COPY_BEFORE="$(mirror_state "$COPY")"
declare -A STATUS_LINE SUM
for n in openldap keycloak; do
  STATUS_LINE[$n]="$(head -n 1 "$COPY/$n/STATUS")"
  SUM[$n]="$(sha256sum "$COPY/$n/summary.txt" | cut -d' ' -f1)"
done

# common.env as installed, with DOCKER_D1 pointed at the copy (identity-platform.sh reads it from
# $HOME/scripts/docker/common.env, which sets DOCKER_D1 unconditionally).
mkdir -p "$D/home/scripts/docker"
grep -v '^DOCKER_D1=' "$REAL_HOME/scripts/docker/common.env" > "$D/home/scripts/docker/common.env"
printf 'DOCKER_D1=%s\n' "$COPY_D1" >> "$D/home/scripts/docker/common.env"
grep -qx "DOCKER_D1=$COPY_D1" "$D/home/scripts/docker/common.env" || refuse "could not point DOCKER_D1 at the copy"

run_ip "$RESTORE_SW"
check "$RESTORE_SW exits 0" '[ "$RC" -eq 0 ]'
for n in openldap keycloak; do
  m="mirror-restored-$n"
  check "$m is written, source mirror" '[ -s "$STATE/$m" ] && grep -qx "source mirror" "$STATE/$m"'
  check "$m names the copy's STATUS (${STATUS_LINE[$n]})" 'grep -qxF "status ${STATUS_LINE[$n]}" "$STATE/$m"'
  check "$m names the copy's summary.txt sha256 (${SUM[$n]:0:12})" '[ "$(mval "$m" summary-sha256)" = "${SUM[$n]}" ]'
done
found="$(sudo -n find "$APP_ROOT" -name "$STANDIN" 2>&1)"
check "the stand-ins reached no dir under $APP_ROOT" '[ -z "$found" ]'

run_ip mirror-check
check "mirror-check exits 0" '[ "$RC" -eq 0 ]'
check "mirror-checked is written: source mirror, summaries equal" \
  '[ -s "$STATE/mirror-checked" ] && grep -qx "source mirror" "$STATE/mirror-checked" && grep -qx "summaries equal" "$STATE/mirror-checked"'
check "mirror-checked's openldap summary sha256 is the copy's" '[ "$(mval mirror-checked openldap-summary-sha256)" = "${SUM[openldap]}" ]'
check "mirror-checked's keycloak summary sha256 is the copy's" '[ "$(mval mirror-checked keycloak-summary-sha256)" = "${SUM[keycloak]}" ]'

MARKS="$(marker_state)"
run_ip "$RESTORE_SW"
check "a second $RESTORE_SW is refused (exit 3)" '[ "$RC" -eq 3 ]'
check "the second run changed no marker" '[ "$(marker_state)" = "$MARKS" ]'

check "the copy is unchanged" '[ "$(mirror_state "$COPY")" = "$COPY_BEFORE" ]'
AFTER="$(mirror_state "$REAL")"
if [ "$AFTER" = "$BEFORE" ]; then
  echo "ok    the production mirror $REAL is unchanged (manifest and STATUS hashes, size/mtime listing)"
else
  echo "FAIL  the production mirror $REAL changed during the proof (d05's nightly backup, or a write: read d05's host-maintenance history)"
  diff <(echo "$BEFORE") <(echo "$AFTER") | head -n 20 | sed 's/^/        /'
  fails=$((fails + 1))
fi

echo "not proven here (a replica): leaf-issue, start-openldap's admin bind, start-keycloak, configure, cutover-done, d05's updater"
if [ "$fails" -eq 0 ]; then
  echo "all cases passed"
else
  echo "$fails case(s) failed"
  exit 1
fi
