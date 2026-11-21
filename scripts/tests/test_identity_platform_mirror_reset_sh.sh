#!/bin/bash
# d05/apps/identity-platform/identity-platform.sh reset-mirror (asyla #1101, review R3): after a
# failed restore-mirror, each copy whose restore did not finish emptied so restore-mirror can run
# again, against stubs (docker, hostname, flock, mountpoint). The docker stub runs the switch's
# root find and ls on the mounted host dir, as keycloak-db's image would (the tests are not root).
# Happy path: exactly the docker calls, in order (compose ps, image inspect, per dir find then ls;
# keycloak-db stopped and checked before keycloak's dirs); each dir emptied and removed, a dir with
# lost+found kept with it alone; the copy's marker and stage removed; a copy with a valid
# mirror-restored-* marker untouched; the NAS mirror never changed; also on a replica; a re-run and
# a fresh build (the build's database, no stage, no marker) have nothing to reset.
# Refusals (exit 3, nothing changed): APP_ROOT the NAS share or below it (as given, through a
# symlinked DOCKER_DL, or a symlinked DOCKER_D1), each symlinked dir, the lock held, mirror-checked
# and each M5 marker (a file or a dangling link), any started-*, compose unable to tell, a one-shot
# container, APP_ROOT or a dir a mount point, a copy's data with no stage and no marker, combined
# with another switch. Exit 2 for an ARG. Exit 1: mountpoint not on PATH or keycloak-db's image
# missing (nothing changed), compose stop failing or keycloak-db still running (nothing deleted), the
# root find leaving files or the root ls failing (the marker and stage kept).
# Every value is a plain stand-in word.
# Run: bash scripts/tests/test_identity_platform_mirror_reset_sh.sh
set -uo pipefail
unset STUB_PS_RC STUB_IDS STUB_STOP_RC STUB_DB_STAYS STUB_NO_IMAGE STUB_FIND_KEEP STUB_LS_RC STUB_MOUNTS \
  STUB_BIN DOCKER_DL DOCKER_D1

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO/d05/apps/identity-platform"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0 oks=0
ok()  { echo "ok   $1"; oks=$((oks + 1)); }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }

mkdir -p "$T/home/scripts/docker" "$T/bin" "$T/bin-nomp" "$T/app" "$T/dl" "$T/nas"
env_file() {   # env_file DOCKER_DL DOCKER_D1
  printf 'DOCKER_DL=%s\nDOCKER_D1=%s\n' "$1" "$2" > "$T/home/scripts/docker/common.env"
}
env_file "$T/dl" "$T/nas"
cp "$SRC"/{compose.yml,identity-platform.sh,mirror-stage.sh} "$T/app/"
ROOT="$T/dl/IdentityPlatform"
MIR="$T/nas/IdentityPlatform/mirror"
SW="$ROOT/cutover-state"
STAGE="$ROOT/mirror-stage"
IMG="$(grep -m 1 '^KC_DB_IMAGE=' "$SRC/identity-platform.sh" | cut -d '"' -f 2)"
[ -n "$IMG" ] || { echo "no KC_DB_IMAGE in identity-platform.sh" >&2; exit 2; }

# Every stub turns xtrace off first and logs its call with $T shortened to T. docker answers only
# the calls reset-mirror makes (any other: exit 97, so an unexpected call fails the check).
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
echo "docker $*" | sed -E "s#-f [^ ]*/compose.yml#-f compose.yml#; s# --project-directory [^ ]*##; s#$STUB_T#T#g" >> "$STUB_LOG"
d=""
for a in "$@"; do case "$a" in *:/t) d="${a%:/t}" ;; *:/t:ro) d="${a%:/t:ro}" ;; esac; done
case "$*" in
  *"--profile restored --profile ops ps -a -q openldap keycloak keycloak-backup openldap-backup")
    [ -z "${STUB_PS_RC:-}" ] || exit "$STUB_PS_RC"
    [ -z "${STUB_IDS:-}" ] || echo "$STUB_IDS" ;;
  *" stop keycloak-db")
    [ -z "${STUB_STOP_RC:-}" ] || exit "$STUB_STOP_RC"
    : > "$STUB_T/db-stopped" ;;
  *" ps -q keycloak-db")
    { [ -e "$STUB_T/db-stopped" ] && [ -z "${STUB_DB_STAYS:-}" ]; } || echo dbid ;;
  "image inspect "*) [ -z "${STUB_NO_IMAGE:-}" ] || exit 1 ;;
  "run --rm --network none --pull never --user 0:0 --entrypoint find -v "*":/t "*" /t -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf --one-file-system --preserve-root=all {} +")
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
  : > "$T/log"; rm -f "$T/db-stopped"
  OUT="$(env ${pre[@]+"${pre[@]}"} HOME="$T/home" PATH="${STUB_BIN:-$T/bin}:$PATH" STUB_LOG="$T/log" \
    STUB_T="$T" STUB_HOST="${STUB_HOST:-d05}" IDENTITY_PLATFORM_TAG_OVERRIDE=stand-in-tag \
    bash "$T/app/identity-platform.sh" "$@" </dev/null 2>&1)"
  rc=$?
  return "$rc"
}

# Paths (with $T shortened), modes, mtimes, link targets and sha256s under each root; .lock aside.
snap_of() {
  python3 -I -c 'import hashlib, os, sys
t = sys.argv[1]
for r in sys.argv[2:]:
    for d, ds, fs in os.walk(r):
        ds.sort()
        for n in sorted(ds + fs):
            p = os.path.join(d, n)
            if n == ".lock":
                continue
            st = os.lstat(p)
            link = os.readlink(p) if os.path.islink(p) else ""
            h = hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.isfile(p) and not link else ""
            print(p.replace(t, "T"), oct(st.st_mode), st.st_mtime_ns, link, h)' "$T" "$@"
}
snap() { snap_of "$T/dl" "$T/nas"; }
snap_kc() { snap_of "$ROOT/backup" "$ROOT/keycloak-db" "$STAGE/keycloak" "$SW"; }
snap_nas() { snap_of "$T/nas"; }
put() {   # put DIR FILE...: stand-in files in DIR
  local d="$1" f
  shift
  mkdir -p "$d"
  for f in "$@"; do printf 'stand-in %s body\n' "$f" > "$d/$f"; done
}
# A host after a failed restore-mirror of both copies: each copy staged, its backup dir written,
# openldap's volumes and keycloak's database part-written, no marker; the NAS mirror intact.
setup() {
  rm -rf "$T/dl"/* "$T/nas"/*
  mkdir -p "$SW" "$ROOT/openldap-data/lost+found" "$ROOT/backup/lost+found"
  : > "$SW/.lock"
  put "$STAGE/openldap" data.ldif summary.txt manifest.sha256 STATUS
  put "$STAGE/keycloak" keycloak.dump summary.txt manifest.sha256 STATUS
  put "$ROOT/openldap-backup" data.ldif summary.txt
  put "$ROOT/openldap-data" data.mdb
  put "$ROOT/openldap-config/cn=config" olcDatabase.ldif
  put "$ROOT/backup" keycloak.dump summary.txt
  put "$ROOT/keycloak-db" PG_VERSION
  put "$ROOT/keycloak-db/base/1" relation
  put "$MIR/openldap" data.ldif summary.txt manifest.sha256 STATUS
  put "$MIR/keycloak" keycloak.dump summary.txt manifest.sha256 STATUS
}
# A fresh build: the build's database, empty targets, no stage, no marker.
fresh() {
  setup
  rm -rf "$STAGE"/* "$ROOT/openldap-backup" "$ROOT/openldap-data/data.mdb" "$ROOT/openldap-config" \
    "$ROOT/backup/keycloak.dump" "$ROOT/backup/summary.txt"
}
valid_marker() {   # valid_marker NAME: a mirror-restored-NAME as restore-mirror writes it
  printf 'date 2026-11-20T00:00:00Z\nsource mirror\nstatus OK 2026-11-19T23:00:00Z\nsummary-sha256 %s\n' \
    "$(printf 'a%.0s' {1..64})" > "$SW/mirror-restored-$1"
}
bad_marker() { printf 'date 2026-11-20T00:00:00Z\nsource stand-in\n' > "$SW/mirror-restored-$1"; }
docker_lines() { grep '^docker ' "$T/log"; }
no_act() { ! docker_lines | grep -qE ' run | stop |image inspect'; }
only() {   # only DIR NAMES: DIR holds exactly NAMES (ls -A, one line)
  [ -d "$1" ] && [ "$(ls -A "$1" | LC_ALL=C sort | tr '\n' ' ')" = "$2" ]
}
ol_reset() {
  [ ! -e "$ROOT/openldap-backup" ] && [ ! -e "$ROOT/openldap-config" ] && only "$ROOT/openldap-data" "lost+found " \
    && [ ! -e "$STAGE/openldap" ] && [ ! -e "$SW/mirror-restored-openldap" ]
}
kc_reset() {
  only "$ROOT/backup" "lost+found " && [ ! -e "$ROOT/keycloak-db" ] && [ ! -e "$STAGE/keycloak" ] \
    && [ ! -e "$SW/mirror-restored-keycloak" ]
}
C="docker compose -f compose.yml"
PS="$C --profile restored --profile ops ps -a -q openldap keycloak keycloak-backup openldap-backup"
pair() {   # pair DIR: the root find then the root ls of one dir (T-relative), as logged
  printf '%s\n' \
    "docker run --rm --network none --pull never --user 0:0 --entrypoint find -v $1:/t $IMG /t -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf --one-file-system --preserve-root=all {} +" \
    "docker run --rm --network none --pull never --user 0:0 --entrypoint ls -v $1:/t:ro $IMG -A /t"
}
R="T/dl/IdentityPlatform"

# --- happy path ---
for host in d05 test01; do
  setup; nas="$(snap_nas)"
  STUB_HOST=$host run -- reset-mirror; rc=$?
  want="$(printf '%s\n' "$PS" "docker image inspect $IMG"; pair "$R/openldap-backup"; pair "$R/openldap-data"
    pair "$R/openldap-config"; printf '%s\n' "$C stop keycloak-db" "$C ps -q keycloak-db"; pair "$R/backup"
    pair "$R/keycloak-db")"
  [ "$rc" -eq 0 ] && [ "$(docker_lines)" = "$want" ] \
    && ok "$host, both copies: exit 0, exactly the calls in order (keycloak-db stopped and checked first)" \
    || bad "$host both copies: calls" "rc=$rc; $OUT; $(docker_lines)"
  ol_reset && kc_reset && [ "$(snap_nas)" = "$nas" ] \
    && ok "$host, both copies: dirs removed (lost+found kept alone), markers and stages gone, NAS unchanged" \
    || bad "$host both copies: state" "$(ls -AR "$ROOT")"
  echo "$OUT" | grep -qF "keycloak-db is stopped with no data dir: next the build's up" \
    && ok "$host, both copies: the last line names the build's up, then restore-mirror" || bad "$host next line" "$OUT"
done
run -- reset-mirror; rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -qF "nothing to reset" && [ "$(docker_lines)" = "$PS" ] \
  && ok "a re-run: nothing to reset (0), compose ps only" || bad "re-run" "rc=$rc; $OUT; $(docker_lines)"

setup; valid_marker keycloak; kc="$(snap_kc)"; nas="$(snap_nas)"
run -- reset-mirror; rc=$?
want="$(printf '%s\n' "$PS" "docker image inspect $IMG"; pair "$R/openldap-backup"; pair "$R/openldap-data"
  pair "$R/openldap-config")"
[ "$rc" -eq 0 ] && [ "$(docker_lines)" = "$want" ] && ol_reset && [ "$(snap_kc)" = "$kc" ] && [ "$(snap_nas)" = "$nas" ] \
  && echo "$OUT" | grep -qF "mirror-restored-keycloak is valid" && echo "$OUT" | grep -qF "next: restore-mirror" \
  && ok "keycloak finished (valid marker): openldap alone reset, keycloak and keycloak-db untouched, no stop" \
  || bad "valid keycloak marker" "rc=$rc; $OUT; $(docker_lines)"

setup; valid_marker openldap; rm -rf "$STAGE/keycloak"; bad_marker keycloak
before="$(snap_of "$ROOT/openldap-backup" "$ROOT/openldap-data" "$ROOT/openldap-config" "$STAGE/openldap")"
ol_marker="$(cat "$SW/mirror-restored-openldap")"
run -- reset-mirror; rc=$?
want="$(printf '%s\n' "$PS" "docker image inspect $IMG" "$C stop keycloak-db" "$C ps -q keycloak-db"
  pair "$R/backup"; pair "$R/keycloak-db")"
[ "$rc" -eq 0 ] && [ "$(docker_lines)" = "$want" ] && kc_reset \
  && [ "$(snap_of "$ROOT/openldap-backup" "$ROOT/openldap-data" "$ROOT/openldap-config" "$STAGE/openldap")" = "$before" ] \
  && [ "$(cat "$SW/mirror-restored-openldap")" = "$ol_marker" ] \
  && ok "keycloak with an invalid marker and no stage: reset (marker removed); openldap's valid copy untouched" \
  || bad "invalid keycloak marker" "rc=$rc; $OUT; $(docker_lines)"

setup; ln -s "$T/nowhere" "$SW/mirror-restored-openldap"; rm -rf "$STAGE/openldap"
run -- reset-mirror; rc=$?
[ "$rc" -eq 0 ] && ol_reset && [ ! -L "$SW/mirror-restored-openldap" ] && kc_reset \
  && ok "openldap's marker a dangling link (no stage): reset, the link removed" || bad "dangling marker" "rc=$rc; $OUT"

fresh; before="$(snap)"
run -- reset-mirror; rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -qF "nothing to reset" && [ "$(docker_lines)" = "$PS" ] && [ "$(snap)" = "$before" ] \
  && ok "a fresh build (the build's database, no stage, no marker): nothing to reset (0), keycloak-db untouched" \
  || bad "fresh build" "rc=$rc; $OUT; $(docker_lines)"

# --- refusals: exit 3, nothing changed ---
refused() {   # refused DESC PATTERN [ENV=V...] -- SWITCH...: no docker call at all
  local desc="$1" pat="$2" before rc
  shift 2
  before="$(snap)"
  run "$@"; rc=$?
  [ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "$pat" && [ -z "$(docker_lines)" ] && [ "$(snap)" = "$before" ] \
    && ok "refused (3, no docker call, nothing changed): $desc" || bad "refusal: $desc" "rc=$rc; $OUT; $(docker_lines)"
}
refused_ro() {   # refused_ro DESC PATTERN [ENV=V...] -- SWITCH...: compose ps at most
  local desc="$1" pat="$2" before rc
  shift 2
  before="$(snap)"
  run "$@"; rc=$?
  [ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "$pat" && no_act && [ "$(snap)" = "$before" ] \
    && ok "refused (3, no run or stop, nothing changed): $desc" || bad "refusal: $desc" "rc=$rc; $OUT; $(docker_lines)"
}

setup; env_file "$T/dl" "$T/dl"
refused "DOCKER_D1 the data disk's root (APP_ROOT below it)" "is the NAS share $T/dl or below it" -- reset-mirror
setup; env_file "$T/dl" "$ROOT"
refused "APP_ROOT the share itself" "is the NAS share $ROOT or below it" -- reset-mirror
setup; ln -s "$T/nas" "$T/nas-link"; env_file "$T/nas-link" "$T/nas"
put "$T/nas/IdentityPlatform/openldap-backup" data.ldif
refused "APP_ROOT resolving onto the share (DOCKER_DL a link to it)" "is the NAS share $T/nas or below it" -- reset-mirror
setup; ln -s "$T/dl" "$T/d1-link"; env_file "$T/dl" "$T/d1-link"
refused "DOCKER_D1 a link to the data disk (resolved)" "is the NAS share $T/d1-link or below it" -- reset-mirror
rm -f "$T/nas-link" "$T/d1-link"; env_file "$T/dl" "$T/nas"

for p in "$SW" "$ROOT/openldap-backup" "$ROOT/openldap-data" "$ROOT/openldap-config" "$ROOT/backup" \
  "$ROOT/keycloak-db" "$STAGE" "$STAGE/openldap" "$STAGE/keycloak"; do
  setup; mv "$p" "$p.real"; ln -s "$p.real" "$p"
  refused "${p#"$T"/} a symlink" "refused: $p is a symlink" -- reset-mirror
done

setup
exec 7> "$SW/.lock"
if "$T/bin/flock" -n 7; then
  refused "the cutover lock held" "reset-mirror: refused: another cutover switch is running" -- reset-mirror
else
  bad "the test could not take the cutover lock"
fi
exec 7>&-

for m in mirror-checked fetched unpack-started unpacked restored-openldap restored-keycloak started-openldap \
  started-keycloak configured counted cutover-done started-stand-in; do
  setup; : > "$SW/$m"
  refused "$m exists" "refused: $SW/$m exists" -- reset-mirror
done
setup; ln -s "$T/nowhere" "$SW/mirror-checked"
refused "mirror-checked a dangling link" "refused: $SW/mirror-checked exists" -- reset-mirror

setup
refused_ro "compose cannot tell" "refused: docker compose ps for openldap, keycloak and the backup one-shots failed" \
  STUB_PS_RC=1 -- reset-mirror
refused_ro "a one-shot container exists" "refused: an openldap, keycloak or backup one-shot container exists" \
  STUB_IDS=stand-in-id -- reset-mirror
for p in "$ROOT" "$ROOT/openldap-backup" "$ROOT/openldap-data" "$ROOT/openldap-config" "$ROOT/backup" \
  "$ROOT/keycloak-db" "$STAGE" "$STAGE/openldap" "$STAGE/keycloak"; do
  refused_ro "${p#"$T"/} a mount point" "refused: $p is a mount point" STUB_MOUNTS="$p" -- reset-mirror
done

setup; rm -rf "$STAGE/openldap"
refused_ro "openldap's data with no stage and no marker (keycloak to reset)" \
  "refused: $ROOT/openldap-backup holds more than lost+found" -- reset-mirror
setup; rm -rf "$ROOT/openldap-backup" "$ROOT/openldap-config" "$STAGE/openldap"
refused_ro "openldap-data with data, no stage, no marker" "refused: $ROOT/openldap-data holds more than lost+found" -- reset-mirror
setup; rm -rf "$STAGE/keycloak"
refused_ro "keycloak's backup/ with data, no stage, no marker (openldap to reset)" \
  "refused: $ROOT/backup holds more than lost+found" -- reset-mirror

setup
refused "combined (verify reset-mirror)" "reset-mirror: refused: run it alone" -- verify reset-mirror
for args in "x" "a b"; do
  setup; before="$(snap)"
  # shellcheck disable=SC2086
  run -- reset-mirror $args; rc=$?
  [ "$rc" -eq 2 ] && echo "$OUT" | grep -qF "usage: reset-mirror (no ARG)" && [ -z "$(docker_lines)" ] && [ "$(snap)" = "$before" ] \
    && ok "reset-mirror $args: exit 2, no docker call, nothing changed" || bad "ARG: $args" "rc=$rc; $OUT"
done

# --- exit 1 ---
if [ -n "$(PATH="$T/bin-nomp:$PATH" command -v mountpoint)" ]; then
  echo "skip mountpoint missing: a mountpoint is on this PATH"
else
  setup; before="$(snap)"
  STUB_BIN="$T/bin-nomp" run -- reset-mirror; rc=$?
  [ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "mountpoint (util-linux) is not on PATH" && no_act && [ "$(snap)" = "$before" ] \
    && ok "mountpoint not on PATH: exit 1, nothing changed" || bad "no mountpoint" "rc=$rc; $OUT"
fi
setup; before="$(snap)"
run STUB_NO_IMAGE=1 -- reset-mirror; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "($IMG) is not here" && [ "$(docker_lines)" = "$(printf '%s\n' "$PS" "docker image inspect $IMG")" ] \
  && [ "$(snap)" = "$before" ] && ok "keycloak-db's image missing: exit 1, nothing changed" || bad "no image" "rc=$rc; $OUT"
setup; valid_marker openldap; before="$(snap)"
run STUB_STOP_RC=1 -- reset-mirror; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "docker compose stop keycloak-db failed" && ! docker_lines | grep -q ' run ' \
  && [ "$(snap)" = "$before" ] && ok "compose stop failing: exit 1, keycloak's dirs not emptied" || bad "stop fails" "rc=$rc; $OUT"
setup; valid_marker openldap; before="$(snap)"
run STUB_DB_STAYS=1 -- reset-mirror; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "keycloak-db is still running" && ! docker_lines | grep -q ' run ' \
  && [ "$(snap)" = "$before" ] && ok "keycloak-db still running after the stop: exit 1, nothing deleted" || bad "db stays" "rc=$rc; $OUT"
setup; bad_marker openldap
run STUB_FIND_KEEP=1 -- reset-mirror; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "$ROOT/openldap-backup still holds files" && [ -d "$STAGE/openldap" ] \
  && [ -e "$SW/mirror-restored-openldap" ] && [ -e "$ROOT/openldap-backup/data.ldif" ] && [ -e "$ROOT/keycloak-db/PG_VERSION" ] \
  && ! docker_lines | grep -q ' stop ' \
  && ok "the root find leaving files: exit 1, the marker and stage kept, keycloak not reached" || bad "find keeps" "rc=$rc; $OUT"
setup
run STUB_LS_RC=1 -- reset-mirror; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "could not list $ROOT/openldap-backup as root" && [ -d "$STAGE/openldap" ] \
  && [ -d "$ROOT/openldap-backup" ] && [ -d "$STAGE/keycloak" ] \
  && ok "the root ls failing: exit 1, the dir not removed, the stages kept" || bad "ls fails" "rc=$rc; $OUT"
run -- reset-mirror; rc=$?
[ "$rc" -eq 0 ] && ol_reset && kc_reset && ok "a reset cut off part-way (that ls failure) runs again to the end" \
  || bad "re-run after a failure" "rc=$rc; $OUT"

echo "checks ok: $oks"
[ "$fail" -eq 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
