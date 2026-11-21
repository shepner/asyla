#!/bin/bash
# d05/apps/identity-platform/identity-platform.sh rollback-stop and rollback-reset (asyla #654: a
# rollback to the Mini inside its 3-day window), against stubs (docker, hostname, flock,
# mountpoint). The docker stub keeps container state in files (running-*, exists-*) and runs the
# switch's root find and ls on the mounted host dir, as keycloak-db's image would (the tests are not
# root).
# rollback-stop: exactly compose stop keycloak, stop openldap, ps -q; rolled-back written; every
# dir, container and other marker kept; keycloak-db not stopped; idempotent (the first rolled-back
# kept); also past cutover-done. Refusals (3, nothing changed): replica, symlinked cutover-state/,
# lock held, each mirror-path marker, no restored-*/started-* marker, combined; exit 2 for an ARG;
# exit 1 with no marker: a stop failing (openldap not stopped after keycloak's fails), one still
# running, compose ps failing. While rolled-back exists: the starts, the restores, configure,
# check-reset-off, count-check, cutover-done and backup refuse (3) with no docker call, and up past
# cutover-done refuses (1).
# rollback-reset: exactly the docker calls in order (ps of the services, image inspect, rm -f, ps -a,
# stop keycloak-db, ps keycloak-db, then per present dir the root find with the safe-delete flags and
# the root ls); only backup/, openldap-backup/, openldap-data/, openldap-config/, keycloak-db/,
# count-check/ and openldap-count-check/ emptied (lost+found kept, the dirs kept), a symlink inside
# one removed without touching its target; every marker but fetched removed; nothing else under the
# data root or on the NAS changed (openldap-tls/, ca/, cutover/bundle.tar.age, the mirror). Refusals
# (3, nothing changed): replica, APP_ROOT on the NAS share, each symlinked dir, lock held, each
# mirror-path marker, no rolled-back (or a symlink), compose ps failing, keycloak, openldap or a
# one-shot running, a dir that is a file, APP_ROOT or a dir a mount point, combined; exit 2 for an
# ARG; exit 1 nothing changed: no mountpoint, no image; exit 1 with rolled-back and the markers kept:
# rm failing, a container left, keycloak-db's stop failing or it still running, the find leaving
# files, the ls failing; a re-run then finishes; after a reset a re-run refuses (no rolled-back).
# Every value is a plain stand-in word.
# Run: bash scripts/tests/test_identity_platform_rollback_sh.sh
set -uo pipefail
unset STUB_PS_RC STUB_STAYS STUB_STOP_FAIL STUB_ONESHOT STUB_RM_RC STUB_RM_STAYS STUB_DB_STOP_RC STUB_DB_STAYS \
  STUB_NO_IMAGE STUB_FIND_KEEP STUB_LS_RC STUB_MOUNTS STUB_BIN DOCKER_DL DOCKER_D1 \
  IDP_KEYCLOAK_DB_PASSWORD IDP_LDAP_ADMIN_PASSWORD IDP_DEPLOY_DEX_CLIENT_SECRET

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO/d05/apps/identity-platform"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0 oks=0
ok()  { echo "ok   $1"; oks=$((oks + 1)); }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }

mkdir -p "$T/home/scripts/docker" "$T/bin" "$T/bin-nomp" "$T/app" "$T/dl" "$T/nas" "$T/st"
env_file() {   # env_file DOCKER_DL DOCKER_D1
  printf 'DOCKER_DL=%s\nDOCKER_D1=%s\n' "$1" "$2" > "$T/home/scripts/docker/common.env"
}
env_file "$T/dl" "$T/nas"
cp "$SRC"/{compose.yml,identity-platform.sh,mirror-stage.sh} "$T/app/"
ROOT="$T/dl/IdentityPlatform"
MIR="$T/nas/IdentityPlatform/mirror"
SW="$ROOT/cutover-state"
IMG="$(grep -m 1 '^KC_DB_IMAGE=' "$SRC/identity-platform.sh" | cut -d '"' -f 2)"
[ -n "$IMG" ] || { echo "no KC_DB_IMAGE in identity-platform.sh" >&2; exit 2; }

# Every stub turns xtrace off first and logs its call with $T shortened to T. docker answers only
# the calls the two switches make (any other: exit 97, so an unexpected call fails the check).
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
echo "docker $*" | sed -E "s#-f [^ ]*/compose.yml#-f compose.yml#; s# --project-directory [^ ]*##; s#$STUB_T#T#g" >> "$STUB_LOG"
st="$STUB_T/st"
d=""
for a in "$@"; do case "$a" in *:/t) d="${a%:/t}" ;; *:/t:ro) d="${a%:/t:ro}" ;; esac; done
case "$*" in
  *"--profile restored stop keycloak"|*"--profile restored stop openldap")
    svc="${*: -1}"
    [ "${STUB_STOP_FAIL:-}" != "$svc" ] || exit 1
    rm -f "$st/running-$svc" ;;
  *"--profile restored ps -q keycloak openldap")
    [ -z "${STUB_PS_RC:-}" ] || exit "$STUB_PS_RC"
    [ -z "${STUB_STAYS:-}" ] || echo stayid
    for s in keycloak openldap; do [ ! -e "$st/running-$s" ] || echo "id-$s"; done ;;
  *"--profile restored --profile ops ps -q openldap keycloak keycloak-backup openldap-backup keycloak-configure")
    [ -z "${STUB_PS_RC:-}" ] || exit "$STUB_PS_RC"
    [ -z "${STUB_ONESHOT:-}" ] || echo oneshotid
    for s in keycloak openldap; do [ ! -e "$st/running-$s" ] || echo "id-$s"; done ;;
  *"--profile restored rm -f keycloak openldap")
    [ -z "${STUB_RM_RC:-}" ] || exit "$STUB_RM_RC"
    rm -f "$st/exists-keycloak" "$st/exists-openldap" ;;
  *"--profile restored ps -a -q keycloak openldap")
    [ -z "${STUB_RM_STAYS:-}" ] || echo stayid
    for s in keycloak openldap; do [ ! -e "$st/exists-$s" ] || echo "id-$s"; done ;;
  *" stop keycloak-db")
    [ -z "${STUB_DB_STOP_RC:-}" ] || exit "$STUB_DB_STOP_RC"
    rm -f "$st/running-keycloak-db" ;;
  *" ps -q keycloak-db")
    { [ ! -e "$st/running-keycloak-db" ] && [ -z "${STUB_DB_STAYS:-}" ]; } || echo dbid ;;
  "image inspect "*) [ -z "${STUB_NO_IMAGE:-}" ] || exit 1 ;;
  "run --rm --network none --pull never --user 0:0 --entrypoint find -v "*":/t "*" /t -xdev -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf --one-file-system --preserve-root=all {} +")
    [ -z "${STUB_FIND_KEEP:-}" ] || exit 1
    find "$d" -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} + ;;
  "run --rm --network none --pull never --user 0:0 --entrypoint ls -v "*":/t:ro "*" -A /t")
    [ -z "${STUB_LS_RC:-}" ] || exit "$STUB_LS_RC"
    ls -A "$d" ;;
  *) echo "stub: unexpected docker call" >&2; exit 97 ;;
esac
exit 0
EOF
cat > "$T/bin/hostname" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
[ "$1" = -s ] && echo "$STUB_HOST"
EOF
# flock: `-n FD` is a real non-blocking flock(2) on the inherited fd (python3's fcntl; util-linux
# flock is not on macOS); any other form is logged and taken.
cat > "$T/bin/flock" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
if [ "${1:-}" = -n ] && [[ ${2:-} =~ ^[0-9]+$ ]]; then
  exec python3 -I -c 'import fcntl, sys
try:
    fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(1)' "$2"
fi
echo "flock $*" >> "$STUB_LOG"
exit 0
EOF
# mountpoint: true only for a path in STUB_MOUNTS (space-separated).
cat > "$T/bin/mountpoint" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
echo "mountpoint $*" | sed "s#$STUB_T#T#g" >> "$STUB_LOG"
p="${*: -1}"
for m in ${STUB_MOUNTS:-}; do [ "$m" != "$p" ] || exit 0; done
exit 1
EOF
chmod +x "$T/bin/docker" "$T/bin/hostname" "$T/bin/flock" "$T/bin/mountpoint"
for s in docker hostname flock; do ln -s "$T/bin/$s" "$T/bin-nomp/$s"; done
hash -r
for s in docker hostname flock mountpoint; do
  [ "$(PATH="$T/bin:$PATH" command -v "$s")" = "$T/bin/$s" ] || { echo "stub $s not runnable in $T/bin" >&2; exit 2; }
done

run() {   # run [ENV=V...] -- SWITCH...: output in $OUT, calls in $T/log, status returned; d05 unless STUB_HOST
  local pre=() rc
  while [ "$1" != -- ]; do pre+=("$1"); shift; done
  shift
  : > "$T/log"
  OUT="$(env ${pre[@]+"${pre[@]}"} HOME="$T/home" PATH="${STUB_BIN:-$T/bin}:$PATH" STUB_LOG="$T/log" \
    STUB_T="$T" STUB_HOST="${STUB_HOST:-d05}" IDENTITY_PLATFORM_TAG_OVERRIDE=stand-in-tag \
    bash "$T/app/identity-platform.sh" "$@" </dev/null 2>&1)"
  rc=$?
  return "$rc"
}

# Paths (with $T shortened), modes, mtimes, link targets and sha256s under each root; .lock aside.
# SNAP_SKIP (space-separated paths): subtrees left out.
snap_of() {
  SNAP_SKIP="${SNAP_SKIP:-}" python3 -I -c 'import hashlib, os, sys
t = sys.argv[1]
skip = set(os.environ["SNAP_SKIP"].split())
for r in sys.argv[2:]:
    for d, ds, fs in os.walk(r):
        ds[:] = sorted(x for x in ds if os.path.join(d, x) not in skip)
        for n in sorted(ds + fs):
            p = os.path.join(d, n)
            if n == ".lock" or p in skip:
                continue
            st = os.lstat(p)
            link = os.readlink(p) if os.path.islink(p) else ""
            h = hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.isfile(p) and not link else ""
            print(p.replace(t, "T"), oct(st.st_mode), st.st_mtime_ns, link, h)' "$T" "$@"
}
snap() { snap_of "$T/dl" "$T/nas"; }
RESET_DIRS="$ROOT/backup $ROOT/openldap-backup $ROOT/openldap-data $ROOT/openldap-config $ROOT/keycloak-db $ROOT/count-check $ROOT/openldap-count-check"
# Everything but the dirs rollback-reset empties and cutover-state/ (the data root itself included).
snap_outside() { SNAP_SKIP="$RESET_DIRS $SW" snap_of "$T/dl" "$T/nas"; }
st_snap() { ls -A "$T/st" | LC_ALL=C sort | tr '\n' ' '; }
put() {   # put DIR FILE...: stand-in files in DIR
  local d="$1" f
  shift
  mkdir -p "$d"
  for f in "$@"; do printf 'stand-in %s body\n' "$f" > "$d/$f"; done
}
mark() {   # mark NAME LINE...: a cutover-state marker
  local n="$1"
  shift
  printf '%s\n' "$@" > "$SW/$n"
}
H64="$(printf 'a%.0s' {1..64})"
# An M5 host after the cutover's restores, starts, configure, check-reset-off and count-check
# (cutover-done too unless PRE), keycloak, openldap and keycloak-db running, with the files a
# rollback-reset must never touch: openldap-tls/, ca/, the bundle, the leaf status, the NAS mirror.
setup() {
  rm -rf "$T/dl"/* "$T/nas"/* "$T/st"/*
  : > "$T/st/running-keycloak"; : > "$T/st/running-openldap"; : > "$T/st/running-keycloak-db"
  : > "$T/st/exists-keycloak"; : > "$T/st/exists-openldap"
  mkdir -p "$SW" "$ROOT/openldap-data/lost+found" "$ROOT/backup/lost+found"
  : > "$SW/.lock"
  mark fetched "version m5-0123456789ab" "sha256 $H64"
  mark unpack-started "version m5-0123456789ab" "manifests-sha256 $H64"
  mark unpacked "version m5-0123456789ab" "manifests-sha256 $H64" "keycloak-summary-sha256 $H64" "openldap-summary-sha256 $H64"
  mark restored-openldap "date 2026-11-21T00:00:00Z" "manifests-sha256 $H64"
  mark restored-keycloak "date 2026-11-21T00:00:00Z" "manifests-sha256 $H64"
  mark started-openldap "date 2026-11-21T00:00:00Z" "admin-bind ok"
  mark started-keycloak "date 2026-11-21T00:00:00Z"
  mark configured "date 2026-11-21T00:00:00Z" "apply ok" "reconcile ok"
  mark reset-off "date 2026-11-21T00:00:00Z" "resetPasswordAllowed false"
  mark counted "date 2026-11-21T00:00:00Z" "manifests-sha256 $H64" "counts equal"
  [ -n "${PRE:-}" ] || mark cutover-done "date 2026-11-21T00:00:00Z" "manifests-sha256 $H64"
  put "$ROOT/backup" keycloak.dump summary.txt
  put "$ROOT/openldap-backup" data.ldif summary.txt
  put "$ROOT/openldap-data" data.mdb
  put "$ROOT/openldap-config/cn=config" olcDatabase.ldif
  put "$ROOT/keycloak-db" PG_VERSION
  put "$ROOT/keycloak-db/base/1" relation
  put "$ROOT/count-check" summary.txt
  put "$ROOT/openldap-tls" leaf.crt leaf.key
  put "$ROOT/ca" root_ca.crt
  put "$ROOT/cutover" bundle.tar.age
  put "$ROOT" leaf-status.json
  put "$MIR/openldap" data.ldif summary.txt manifest.sha256 STATUS
  put "$MIR/keycloak" keycloak.dump summary.txt manifest.sha256 STATUS
}
# What rollback-stop leaves: keycloak and openldap stopped, rolled-back written.
stopped() {
  setup
  rm -f "$T/st/running-keycloak" "$T/st/running-openldap"
  mark rolled-back "date 2026-11-21T01:00:00Z" "keycloak openldap stopped"
}
docker_lines() { grep '^docker ' "$T/log"; }
no_act() { ! docker_lines | grep -qE ' run | stop | rm |image inspect'; }
only() {   # only DIR NAMES: DIR holds exactly NAMES (ls -A, one line)
  [ -d "$1" ] && [ "$(ls -A "$1" | LC_ALL=C sort | tr '\n' ' ')" = "$2" ]
}
C="docker compose -f compose.yml"
R="T/dl/IdentityPlatform"
pair() {   # pair DIR: the root find then the root ls of one dir (T-relative), as logged
  printf '%s\n' \
    "docker run --rm --network none --pull never --user 0:0 --entrypoint find -v $1:/t $IMG /t -xdev -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf --one-file-system --preserve-root=all {} +" \
    "docker run --rm --network none --pull never --user 0:0 --entrypoint ls -v $1:/t:ro $IMG -A /t"
}
MP="mirror-restored-openldap mirror-restored-keycloak mirror-checked"

# ===================== rollback-stop =====================
STOP_CALLS="$(printf '%s\n' "$C --profile restored stop keycloak" "$C --profile restored stop openldap" "$C --profile restored ps -q keycloak openldap")"
for pre in "" 1; do
  PRE=$pre setup; nas="$(snap_of "$T/nas")"
  # cutover-state/'s own mtime changes with the new marker: its entries are compared instead.
  before="$(SNAP_SKIP="$SW" snap_of "$T/dl")"; before_sw="$(SNAP_SKIP="$SW/rolled-back" snap_of "$SW")"
  run -- rollback-stop; rc=$?
  when="past cutover-done"; [ -z "$pre" ] || when="before cutover-done"
  [ "$rc" -eq 0 ] && [ "$(docker_lines)" = "$STOP_CALLS" ] \
    && grep -qE '^date [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$SW/rolled-back" \
    && grep -qx 'keycloak openldap stopped' "$SW/rolled-back" && [ "$(wc -l < "$SW/rolled-back" | tr -d ' ')" -eq 2 ] \
    && [ "$(SNAP_SKIP="$SW" snap_of "$T/dl")" = "$before" ] && [ "$(SNAP_SKIP="$SW/rolled-back" snap_of "$SW")" = "$before_sw" ] \
    && [ "$(snap_of "$T/nas")" = "$nas" ] \
    && [ "$(st_snap)" = "exists-keycloak exists-openldap running-keycloak-db " ] \
    && ok "rollback-stop $when: stop keycloak, then openldap, then ps; rolled-back written; every dir, marker and container kept; keycloak-db runs on" \
    || bad "rollback-stop happy ($when)" "rc=$rc; $OUT; $(cat "$T/log")"
done
# Idempotent: again, with both stopped already: the same calls, exit 0, the first rolled-back kept.
before="$(snap)"
run -- rollback-stop; rc=$?
[ "$rc" -eq 0 ] && [ "$(docker_lines)" = "$STOP_CALLS" ] && [ "$(snap)" = "$before" ] \
  && echo "$OUT" | grep -qF "exists already (date " \
  && ok "rollback-stop again: exit 0, nothing running, the first rolled-back kept unchanged" \
  || bad "rollback-stop re-run" "rc=$rc; $OUT"
# A host where only restore-openldap ran: still stands down (nothing may run by now).
setup; rm -f "$SW"/restored-keycloak "$SW"/started-* "$SW"/configured "$SW"/reset-off "$SW"/counted "$SW"/cutover-done
run -- rollback-stop; rc=$?
[ "$rc" -eq 0 ] && [ -f "$SW/rolled-back" ] && ok "rollback-stop with restored-openldap alone: runs (0)" || bad "stop restored-openldap alone" "rc=$rc; $OUT"

stop_refused() {   # stop_refused CODE WHAT PATTERN: after a run; nothing changed, no docker call
  [ "$rc" -eq "$1" ] && echo "$OUT" | grep -qF "$3" && [ -z "$(docker_lines)" ] && [ "$(snap)" = "$before" ] \
    && [ "$(st_snap)" = "$st0" ] && ok "rollback-stop $2: exit $1, no docker call, nothing changed" \
    || bad "rollback-stop $2" "rc=$rc; $OUT; $(cat "$T/log")"
}
setup; before="$(snap)"; st0="$(st_snap)"
run -- rollback-stop extra; rc=$?
stop_refused 2 "with an ARG" "usage: rollback-stop (no ARG)"
STUB_HOST=test01 run -- rollback-stop; rc=$?
stop_refused 3 "on a replica" "rollback-stop: refused: not on a replica (test01)"
run -- verify rollback-stop; rc=$?
stop_refused 3 "combined with another switch" "rollback-stop: refused: run it alone"
for m in $MP; do
  setup; : > "$SW/$m"; before="$(snap)"; st0="$(st_snap)"
  run -- rollback-stop; rc=$?
  stop_refused 3 "with $m (the mirror path)" "rollback-stop: refused: $SW/$m exists (cutover-state/ is on the mirror path"
done
setup; rm -f "$SW"/restored-* "$SW"/started-*; before="$(snap)"; st0="$(st_snap)"
run -- rollback-stop; rc=$?
stop_refused 3 "with no restored-* or started-* marker" "rollback-stop: refused: no restored-* or started-* marker"
setup; mv "$SW" "$SW.real"; ln -s "$SW.real" "$SW"; before="$(snap)"; st0="$(st_snap)"
run -- rollback-stop; rc=$?
stop_refused 3 "with cutover-state/ a symlink" "refused: $SW is a symlink"
setup; before="$(snap)"; st0="$(st_snap)"
exec 7> "$SW/.lock"
if "$T/bin/flock" -n 7; then
  run -- rollback-stop; rc=$?
  stop_refused 3 "with the cutover lock held" "rollback-stop: refused: another cutover switch is running"
else
  bad "the test could not take the cutover lock"
fi
exec 7>&-
# exit 1, no marker
setup; before="$(snap)"
run STUB_STOP_FAIL=keycloak -- rollback-stop; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "docker compose stop keycloak failed" && [ ! -e "$SW/rolled-back" ] \
  && [ "$(docker_lines)" = "$C --profile restored stop keycloak" ] && [ "$(snap)" = "$before" ] \
  && ok "rollback-stop with keycloak's stop failing: exit 1, openldap not stopped, no marker" || bad "stop keycloak fails" "rc=$rc; $OUT"
setup; before="$(snap)"
run STUB_STOP_FAIL=openldap -- rollback-stop; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "docker compose stop openldap failed" && [ ! -e "$SW/rolled-back" ] && [ "$(snap)" = "$before" ] \
  && ok "rollback-stop with openldap's stop failing: exit 1, no marker" || bad "stop openldap fails" "rc=$rc; $OUT"
setup; before="$(snap)"
run STUB_STAYS=1 -- rollback-stop; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "keycloak or openldap is still running" && [ ! -e "$SW/rolled-back" ] && [ "$(snap)" = "$before" ] \
  && ok "rollback-stop with a container still running after the stops: exit 1, no marker" || bad "stop stays" "rc=$rc; $OUT"
setup; before="$(snap)"
run STUB_PS_RC=1 -- rollback-stop; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "keycloak or openldap is still running (or compose cannot tell)" && [ ! -e "$SW/rolled-back" ] \
  && [ "$(snap)" = "$before" ] && ok "rollback-stop with compose ps failing: exit 1, no marker" || bad "stop ps fails" "rc=$rc; $OUT"

# --- while rolled-back exists: the switches that would start, change or record d05's copy refuse ---
blocked() {   # blocked CODE SWITCH WHAT PATTERN
  [ "$rc" -eq "$1" ] && echo "$OUT" | grep -qF "$4" && [ -z "$(docker_lines)" ] && [ "$(snap)" = "$before" ] \
    && ok "$2 while rolled-back exists ($3): exit $1, no docker call, nothing changed" \
    || bad "$2 blocked ($3)" "rc=$rc; $OUT; $(cat "$T/log")"
}
PRE=1 stopped; before="$(snap)"
for sw in start-openldap start-keycloak restore-openldap restore-keycloak configure check-reset-off count-check cutover-done; do
  run -- "$sw"; rc=$?
  blocked 3 "$sw" "before cutover-done" "$sw: refused: $SW/rolled-back exists"
done
stopped; before="$(snap)"
for sw in start-openldap start-keycloak configure check-reset-off cutover-done backup; do
  run -- "$sw"; rc=$?
  blocked 3 "$sw" "past cutover-done" "$sw: refused: $SW/rolled-back exists"
done
run -- up; rc=$?
blocked 1 up "past cutover-done" "up: refused: $SW/rolled-back exists"
UPV=x   # a stand-in start_env value, set through a variable so no fixture reads as a secret
run IDP_KEYCLOAK_DB_PASSWORD="$UPV" IDP_LDAP_ADMIN_PASSWORD="$UPV" -- up; rc=$?
blocked 1 up "past cutover-done, both start_env values set" "up: refused: $SW/rolled-back exists"
PRE=1 stopped
run -- up; rc=$?
[ "$rc" -eq 1 ] && ! echo "$OUT" | grep -qF "rolled-back exists" && echo "$OUT" | grep -qF "IDP_KEYCLOAK_DB_PASSWORD is not in this process's environment" \
  && ok "up before cutover-done with rolled-back: not refused for it (keycloak-db alone; here no password: exit 1)" \
  || bad "up pre rolled-back" "rc=$rc; $OUT"

# ===================== rollback-reset =====================
RS_HEAD="$(printf '%s\n' "$C --profile restored --profile ops ps -q openldap keycloak keycloak-backup openldap-backup keycloak-configure" \
  "docker image inspect $IMG" "$C --profile restored rm -f keycloak openldap" "$C --profile restored ps -a -q keycloak openldap" \
  "$C stop keycloak-db" "$C ps -q keycloak-db")"
reset_done() {   # each listed dir empty (lost+found kept where it was), cutover-state/ holds fetched alone
  only "$ROOT/backup" "lost+found " && only "$ROOT/openldap-backup" "" && only "$ROOT/openldap-data" "lost+found " \
    && only "$ROOT/openldap-config" "" && only "$ROOT/keycloak-db" "" && only "$ROOT/count-check" "" \
    && only "$SW" ".lock fetched " && [ "$(cat "$SW/fetched")" = "$(printf 'version m5-0123456789ab\nsha256 %s' "$H64")" ]
}
# Happy path, past cutover-done (the 3-day window) and before it; with openldap-count-check/ and
# a symlink in backup/ pointing at openldap-tls/ (the link goes, its target stays).
for pre in "" 1; do
  PRE=$pre stopped; ln -s "$ROOT/openldap-tls" "$ROOT/backup/tls-link"; outside="$(snap_outside)"
  run -- rollback-reset; rc=$?
  want="$(printf '%s\n' "$RS_HEAD"; for d in backup openldap-backup openldap-data openldap-config keycloak-db count-check; do pair "$R/$d"; done)"
  when="past cutover-done"; [ -z "$pre" ] || when="before cutover-done"
  [ "$rc" -eq 0 ] && [ "$(docker_lines)" = "$want" ] && reset_done && [ "$(snap_outside)" = "$outside" ] \
    && [ "$(st_snap)" = "" ] && [ -f "$ROOT/openldap-tls/leaf.key" ] && [ -f "$ROOT/cutover/bundle.tar.age" ] \
    && ok "rollback-reset $when: the exact docker calls (find -xdev, rm --one-file-system --preserve-root=all); only the seven dirs emptied (lost+found kept), a symlink in one removed with its target kept; fetched alone kept; openldap-tls, ca, the bundle, the leaf status and the NAS mirror unchanged" \
    || bad "rollback-reset happy ($when)" "rc=$rc; $OUT; $(cat "$T/log"); $(ls -A "$SW")"
done
stopped; put "$ROOT/openldap-count-check" summary.txt data.ldif; outside="$(snap_outside)"
run -- rollback-reset; rc=$?
want="$(printf '%s\n' "$RS_HEAD"; for d in backup openldap-backup openldap-data openldap-config keycloak-db count-check openldap-count-check; do pair "$R/$d"; done)"
[ "$rc" -eq 0 ] && [ "$(docker_lines)" = "$want" ] && reset_done && only "$ROOT/openldap-count-check" "" && [ "$(snap_outside)" = "$outside" ] \
  && ok "rollback-reset with openldap-count-check/ present: it is emptied too, nothing else changed" \
  || bad "rollback-reset openldap-count-check" "rc=$rc; $OUT"
# After a reset: a re-run refuses (no rolled-back), nothing changed.
before="$(snap)"
run -- rollback-reset; rc=$?
[ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "rollback-reset: refused: no $SW/rolled-back" && [ -z "$(docker_lines)" ] && [ "$(snap)" = "$before" ] \
  && ok "rollback-reset again after a reset: refused (3), no docker call, nothing changed" || bad "reset re-run" "rc=$rc; $OUT"
# A dir that is gone is skipped (no docker run for it).
stopped; rm -rf "$ROOT/count-check" "$ROOT/openldap-config"
run -- rollback-reset; rc=$?
want="$(printf '%s\n' "$RS_HEAD"; for d in backup openldap-backup openldap-data keycloak-db; do pair "$R/$d"; done)"
[ "$rc" -eq 0 ] && [ "$(docker_lines)" = "$want" ] && [ ! -e "$ROOT/count-check" ] && [ ! -e "$ROOT/openldap-config" ] && only "$SW" ".lock fetched " \
  && ok "rollback-reset with count-check/ and openldap-config/ gone: skipped (not created), the rest reset" || bad "reset missing dirs" "rc=$rc; $OUT"

reset_refused() {   # reset_refused CODE WHAT PATTERN: after a run; nothing changed, no act
  [ "$rc" -eq "$1" ] && echo "$OUT" | grep -qF "$3" && no_act && [ "$(snap)" = "$before" ] && [ "$(st_snap)" = "$st0" ] \
    && ok "rollback-reset $2: exit $1, nothing changed" || bad "rollback-reset $2" "rc=$rc; $OUT; $(cat "$T/log")"
}
stopped; before="$(snap)"; st0="$(st_snap)"
run -- rollback-reset extra; rc=$?
reset_refused 2 "with an ARG" "usage: rollback-reset (no ARG)"
STUB_HOST=test01 run -- rollback-reset; rc=$?
reset_refused 3 "on a replica" "rollback-reset: refused: not on a replica (test01)"
run -- verify rollback-reset; rc=$?
reset_refused 3 "combined with another switch" "rollback-reset: refused: run it alone"
stopped; rm -f "$SW/rolled-back"; before="$(snap)"; st0="$(st_snap)"
run -- rollback-reset; rc=$?
reset_refused 3 "with no rolled-back" "rollback-reset: refused: no $SW/rolled-back"
stopped; mv "$SW/rolled-back" "$T/rb-target"; ln -s "$T/rb-target" "$SW/rolled-back"; before="$(snap)"; st0="$(st_snap)"
run -- rollback-reset; rc=$?
reset_refused 3 "with rolled-back a symlink" "rollback-reset: refused: no $SW/rolled-back"
rm -f "$T/rb-target"
for m in $MP; do
  stopped; : > "$SW/$m"; before="$(snap)"; st0="$(st_snap)"
  run -- rollback-reset; rc=$?
  reset_refused 3 "with $m (the mirror path)" "rollback-reset: refused: $SW/$m exists (cutover-state/ is on the mirror path"
done
stopped; before="$(snap)"; st0="$(st_snap)"
run STUB_PS_RC=1 -- rollback-reset; rc=$?
reset_refused 3 "with compose ps failing" "docker compose ps for openldap, keycloak and the ops one-shots failed"
for svc in keycloak openldap; do
  stopped; : > "$T/st/running-$svc"; before="$(snap)"; st0="$(st_snap)"
  run -- rollback-reset; rc=$?
  reset_refused 3 "with $svc running" "rollback-reset: refused: an openldap, keycloak or ops one-shot container is running"
done
stopped; before="$(snap)"; st0="$(st_snap)"
run STUB_ONESHOT=1 -- rollback-reset; rc=$?
reset_refused 3 "with an ops one-shot running" "rollback-reset: refused: an openldap, keycloak or ops one-shot container is running"
for d in backup openldap-backup openldap-data openldap-config keycloak-db count-check openldap-count-check cutover-state; do
  stopped; mkdir -p "$ROOT/$d"; mv "$ROOT/$d" "$ROOT/$d.real"; ln -s "$ROOT/$d.real" "$ROOT/$d"; before="$(snap)"; st0="$(st_snap)"
  run -- rollback-reset; rc=$?
  reset_refused 3 "with $d/ a symlink" "rollback-reset: refused: $ROOT/$d is a symlink"
  [ -z "$(docker_lines)" ] || bad "rollback-reset with $d a symlink called docker" "$(cat "$T/log")"
done
stopped; rm -rf "$ROOT/count-check"; printf 'stand-in\n' > "$ROOT/count-check"; before="$(snap)"; st0="$(st_snap)"
run -- rollback-reset; rc=$?
reset_refused 3 "with count-check a file" "rollback-reset: refused: $ROOT/count-check is not a directory"
for d in "$ROOT" $RESET_DIRS; do
  stopped; mkdir -p "$ROOT/openldap-count-check"; before="$(snap)"; st0="$(st_snap)"
  run STUB_MOUNTS="$d" -- rollback-reset; rc=$?
  reset_refused 3 "with ${d#"$T"/} a mount point" "rollback-reset: refused: $d is a mount point"
done
# APP_ROOT the NAS share or below it: as given, and through a symlinked DOCKER_DL.
env_file "$T/nas" "$T/nas"; ROOT_SAVE="$ROOT"
stopped; mkdir -p "$T/nas/IdentityPlatform/cutover-state"; before="$(snap)"; st0="$(st_snap)"
run -- rollback-reset; rc=$?
reset_refused 3 "with APP_ROOT on the NAS share" "is the NAS share $T/nas or below it"
rm -rf "$T/nas/IdentityPlatform/cutover-state"
ln -s "$T/nas" "$T/dl-link"; env_file "$T/dl-link" "$T/nas"; before="$(snap)"
run -- rollback-reset; rc=$?
reset_refused 3 "with DOCKER_DL a symlink to the NAS share" "is the NAS share $T/nas or below it"
rm -f "$T/dl-link"; env_file "$T/dl" "$T/nas"; ROOT="$ROOT_SAVE"
stopped; before="$(snap)"; st0="$(st_snap)"
exec 7> "$SW/.lock"
if "$T/bin/flock" -n 7; then
  run -- rollback-reset; rc=$?
  reset_refused 3 "with the cutover lock held" "rollback-reset: refused: another cutover switch is running"
else
  bad "the test could not take the cutover lock"
fi
exec 7>&-
# exit 1, nothing changed
if [ -n "$(PATH="$T/bin-nomp:$PATH" command -v mountpoint)" ]; then
  echo "skip mountpoint missing: a mountpoint is on this PATH"
else
  stopped; before="$(snap)"; st0="$(st_snap)"
  STUB_BIN="$T/bin-nomp" run -- rollback-reset; rc=$?
  reset_refused 1 "with mountpoint not on PATH" "mountpoint (util-linux) is not on PATH"
fi
stopped; before="$(snap)"; st0="$(st_snap)"
run STUB_NO_IMAGE=1 -- rollback-reset; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "($IMG) is not here" && [ "$(docker_lines | tail -n 1)" = "docker image inspect $IMG" ] \
  && ! docker_lines | grep -qE ' run | stop | rm ' && [ "$(snap)" = "$before" ] && [ "$(st_snap)" = "$st0" ] \
  && ok "rollback-reset with keycloak-db's image missing: exit 1, nothing changed" || bad "reset no image" "rc=$rc; $OUT"
# exit 1 part-way: rolled-back and every marker kept, nothing past the failure; a re-run finishes.
partial() {   # partial WHAT PATTERN NO_RUN: after a run
  [ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "$2" && [ -f "$SW/rolled-back" ] && [ -f "$SW/cutover-done" ] && [ -f "$SW/restored-keycloak" ] \
    && { [ -z "$3" ] || ! docker_lines | grep -q ' run '; } \
    && ok "rollback-reset with $1: exit 1, rolled-back and the markers kept" || bad "rollback-reset $1" "rc=$rc; $OUT; $(cat "$T/log")"
}
stopped; before="$(snap)"
run STUB_RM_RC=1 -- rollback-reset; rc=$?
partial "compose rm failing" "docker compose rm -f keycloak openldap failed" 1
[ "$(snap)" = "$before" ] || bad "rm failing changed files"
run STUB_RM_STAYS=1 -- rollback-reset; rc=$?
partial "a container left after rm" "a keycloak or openldap container is still there" 1
run STUB_DB_STOP_RC=1 -- rollback-reset; rc=$?
partial "keycloak-db's stop failing" "docker compose stop keycloak-db failed" 1
run STUB_DB_STAYS=1 -- rollback-reset; rc=$?
partial "keycloak-db still running" "keycloak-db is still running" 1
[ "$(snap)" = "$before" ] || bad "a failure before the deletes changed files"
run STUB_FIND_KEEP=1 -- rollback-reset; rc=$?
partial "the root find leaving files" "$ROOT/backup still holds files" ""
[ -f "$ROOT/backup/keycloak.dump" ] && [ -f "$ROOT/keycloak-db/PG_VERSION" ] || bad "find keeps: a later dir was emptied"
run STUB_LS_RC=1 -- rollback-reset; rc=$?
partial "the root ls failing" "could not list $ROOT/backup as root" ""
[ -f "$ROOT/keycloak-db/PG_VERSION" ] || bad "ls fails: keycloak-db emptied past the failure"
run -- rollback-reset; rc=$?
[ "$rc" -eq 0 ] && reset_done && ok "rollback-reset cut off part-way runs again to the end" || bad "reset re-run after failures" "rc=$rc; $OUT"

echo "checks ok: $oks"
[ "$fail" -eq 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
