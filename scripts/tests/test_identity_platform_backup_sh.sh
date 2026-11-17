#!/bin/bash
# d05/apps/identity-platform/identity-platform.sh backup (asyla #654 unit D) and mirror-stage.sh,
# against stubs (docker, hostname, flock, mountpoint, and a cp that logs and then copies).
# backup is host-maintenance's nightly task: refused (exit 3, no docker call, nothing written) on a
# replica, before cutover-done, with a symlinked backup dir, with the cutover lock held, and combined
# with another switch. Past cutover-done: openldap-backup backup and verify, keycloak-db's
# POSTGRES_PASSWORD read from the running container with a one-key docker inspect template, written
# to keycloak-backup backup's stdin alone (never an argv, an environment, a file or the output, also
# under SHELLOPTS=xtrace and bash -x), keycloak-backup verify with no stdin, then each copy staged
# by mirror-stage.sh (run here by the docker stub with the real script) under flock -s and mirrored
# to the NAS dir: the mirror's STATUS removed first, the named files, manifest.sha256, the NAS copy
# checked against it, then STATUS last; .work, .prev, .lock and unnamed files never copied; the copy
# mounted read-only; a symlinked stage dir refused. Each step's failure exits 1 naming the
# step, with no call of a later step. Every value is a plain stand-in word made at run time.
# Run: bash scripts/tests/test_identity_platform_backup_sh.sh
set -uo pipefail
unset IDP_KEYCLOAK_DB_PASSWORD IDP_LDAP_ADMIN_PASSWORD POSTGRES_PASSWORD PGPASSWORD KC_DB_PASSWORD \
  STUB_OL_BACKUP_RC STUB_OL_VERIFY_RC STUB_KC_BACKUP_RC STUB_KC_VERIFY_RC STUB_NO_DB STUB_NO_PW \
  STUB_STAGE_RC STUB_NOT_MOUNTED STUB_CP_FAIL STUB_CP_CORRUPT STUB_FLOCK_W

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO/d05/apps/identity-platform"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }

mkdir -p "$T/home/scripts/docker" "$T/bin" "$T/app" "$T/dl" "$T/nas"
printf 'DOCKER_DL=%s\nDOCKER_D1=%s\n' "$T/dl" "$T/nas" > "$T/home/scripts/docker/common.env"
cp "$SRC"/{compose.yml,identity-platform.sh,mirror-stage.sh} "$T/app/"
ROOT="$T/dl/IdentityPlatform"
MIR="$T/nas/IdentityPlatform/mirror"
WORD="stand-in-db-word-$$"     # keycloak-db's stand-in value; only in $T/dbword and the checks
printf '%s' "$WORD" > "$T/dbword"
TAG="stand-in-tag"

# Every stub turns xtrace off first (SHELLOPTS=xtrace reaches them too), logs its call with $T
# shortened to T, and dumps its environment to $T/envdump (read only by the checks).
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
echo "docker $*" | sed -E "s#-f [^ ]*/compose.yml#-f compose.yml#; s# --project-directory [^ ]*##; s#$STUB_T#T#g" >> "$STUB_LOG"
env >> "$STUB_T/envdump"
case "$*" in
  *"--profile ops run --rm -T openldap-backup backup") exit "${STUB_OL_BACKUP_RC:-0}" ;;
  *"--profile ops run --rm -T openldap-backup verify") exit "${STUB_OL_VERIFY_RC:-0}" ;;
  *"ps -q --status running keycloak-db") [ -n "${STUB_NO_DB:-}" ] || echo dbid ;;
  "inspect -f "*POSTGRES_PASSWORD*" dbid")
    [ -n "${STUB_NO_PW:-}" ] || printf '%s=%s\n' POSTGRES_PASSWORD "$(cat "$STUB_T/dbword")" ;;
  *"--profile ops run --rm -T -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup backup")
    cat > "$STUB_T/kcstdin"; exit "${STUB_KC_BACKUP_RC:-0}" ;;
  *"--profile ops run --rm -T keycloak-backup verify")
    echo "VERIFYSTDIN $(wc -c | tr -d ' ')" >> "$STUB_LOG"; exit "${STUB_KC_VERIFY_RC:-0}" ;;
  # mirror-stage.sh in the copy's image: run here, the real script on the mounted host dirs.
  "run --rm --network none --pull never --user 0:0 --entrypoint sh "*)
    [ -z "${STUB_STAGE_RC:-}" ] || exit "$STUB_STAGE_RC"
    s="" st="" scr=""
    for a in "$@"; do
      case "$a" in
        *:/backup:ro) s="${a%:/backup:ro}" ;; *:/stage) st="${a%:/stage}" ;; *:/mirror-stage.sh:ro) scr="${a%:/mirror-stage.sh:ro}" ;;
      esac
    done
    n=$#
    exec sh "$scr" "$s" "$st" "${@:n-1:1}" "${@:n:1}" ;;
esac
exit 0
EOF
cat > "$T/bin/hostname" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
[ "$1" = -s ] && echo "$STUB_HOST"
EOF
# flock: `-n FD` is a real non-blocking flock(2) on the inherited fd (python3's fcntl; util-linux
# flock is not on macOS); `-s -w N FD` (mirror-stage.sh's) is logged, then a real shared flock(2)
# polled non-blocking until N seconds (N overridden by STUB_FLOCK_W); any other form is logged and taken.
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
if [ "${1:-}" = -s ] && [ "${2:-}" = -w ] && [[ ${3:-} =~ ^[0-9]+$ ]] && [[ ${4:-} =~ ^[0-9]+$ ]]; then
  exec python3 -I -c 'import fcntl, sys, time
end = time.monotonic() + float(sys.argv[2])
while True:
    try:
        fcntl.flock(int(sys.argv[1]), fcntl.LOCK_SH | fcntl.LOCK_NB)
        sys.exit(0)
    except BlockingIOError:
        if time.monotonic() >= end:
            sys.exit(1)
        time.sleep(0.1)' "$4" "${STUB_FLOCK_W:-$3}"
fi
exit 0
EOF
cat > "$T/bin/mountpoint" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
echo "mountpoint $*" | sed "s#$STUB_T#T#g" >> "$STUB_LOG"
[ -z "${STUB_NOT_MOUNTED:-}" ]
EOF
# cp: logs its call; for a copy into the mirror, logs STATUS-PRESENT when the mirror still has a
# STATUS while another file is copied in, fails a copy of STUB_CP_FAIL's name, and appends a byte
# to the NAS copy of STUB_CP_CORRUPT's name (a copy that did not land intact); then copies.
cat > "$T/bin/cp" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
dst="${!#}"
echo "cp $*" | sed "s#$STUB_T#T#g" >> "$STUB_LOG"
case "$dst" in
  "$STUB_T/nas/"*)
    b="${dst##*/}"
    [ "$b" = STATUS ] || [ ! -e "${dst%/*}/STATUS" ] || echo "STATUS-PRESENT $b" >> "$STUB_LOG"
    [ "$b" != "${STUB_CP_FAIL:-}" ] || exit 1
    if [ "$b" = "${STUB_CP_CORRUPT:-}" ]; then /bin/cp "$@" && printf x >> "$dst"; exit; fi ;;
esac
exec /bin/cp "$@"
EOF
chmod +x "$T/bin/docker" "$T/bin/hostname" "$T/bin/flock" "$T/bin/mountpoint" "$T/bin/cp"
hash -r   # cp is hashed from the copies above; the check must see PATH's first cp
for s in docker hostname flock mountpoint cp; do
  [ "$(PATH="$T/bin:$PATH" command -v "$s")" = "$T/bin/$s" ] || { echo "stub $s not runnable in $T/bin" >&2; exit 2; }
done

run() {   # run [ENV=V...] -- SWITCH...: output in $OUT, calls in $T/log, status returned; d05 unless STUB_HOST
  local pre=() rc
  while [ "$1" != -- ]; do pre+=("$1"); shift; done
  shift
  : > "$T/log"; : > "$T/envdump"; rm -f "$T/kcstdin"
  OUT="$(env ${pre[@]+"${pre[@]}"} HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_T="$T" \
    STUB_HOST="${STUB_HOST:-d05}" IDENTITY_PLATFORM_TAG_OVERRIDE="$TAG" \
    bash ${BASH_OPTS:-} "$T/app/identity-platform.sh" "$@" </dev/null 2>&1)"
  rc=$?
  return "$rc"
}

# One theOrg copy: the named files, manifest.sha256 (sha256sum format), STATUS OK, plus what a mirror
# never takes: .lock, .work/, .prev/ and a file the manifest does not name.
make_copy() {   # make_copy DIR FILE...
  local d="$1" f
  shift
  mkdir -p "$d/.work" "$d/.prev"
  for f in "$@"; do printf 'stand-in %s body\n' "$f" > "$d/$f"; done
  (cd "$d" && sha256sum "$@" > manifest.sha256)
  echo "OK 2026-11-16T03:45:00Z" > "$d/STATUS"
  : > "$d/.lock"
  echo "OK old" > "$d/.prev/STATUS"
  echo partial > "$d/.work/keycloak.dump"
  echo stray > "$d/notes.txt"
}
OL_FILES=(config.ldif data.ldif summary.txt)
KC_FILES=(keycloak.dump summary.txt)
setup() {   # a d05 past cutover-done, both copies made by a backup, an old mirror with a STATUS
  rm -rf "$T/dl"/* "$T/nas"/*
  mkdir -p "$ROOT/cutover-state" "$MIR/openldap"
  echo "date 2026-11-16T00:00:00Z" > "$ROOT/cutover-state/cutover-done"
  make_copy "$ROOT/openldap-backup" "${OL_FILES[@]}"
  make_copy "$ROOT/backup" "${KC_FILES[@]}"
  echo "OK old" > "$MIR/openldap/STATUS"
}
snap() { find "$T/dl" "$T/nas" ! -path "$ROOT/cutover-state/.lock" | LC_ALL=C sort; }
docker_lines() { grep '^docker ' "$T/log"; }
no_word() {   # the value in no output, argv, environment or file under the host's dirs
  ! printf '%s' "$OUT" | grep -qF "$WORD" && ! grep -qF "$WORD" "$T/log" "$T/envdump" \
    && ! grep -rqF "$WORD" "$T/dl" "$T/nas"
}

# --- the host-maintenance contract ---
grep -qE '^\s*backup\)' "$SRC/identity-platform.sh" && ok "run_cmd has the backup) line host-maintenance looks for" \
  || bad "no ^\\s*backup) line"
run --; echo "$OUT" | grep -q '^  backup ' && ok "usage lists backup" || bad "usage has no backup line"

# --- the happy path: exact calls ---
C="docker compose -f compose.yml"
IMG="gitea.asyla.org/theorg/identity-platform"
U="$(id -u) $(id -g)"
EXPECT="$C --profile ops run --rm -T openldap-backup backup
$C --profile ops run --rm -T openldap-backup verify
$C ps -q --status running keycloak-db
docker inspect -f {{range .Config.Env}}{{if eq (index (split . \"=\") 0) \"POSTGRES_PASSWORD\"}}{{.}}{{end}}{{end}} dbid
$C --profile ops run --rm -T -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup backup
$C --profile ops run --rm -T keycloak-backup verify
docker run --rm --network none --pull never --user 0:0 --entrypoint sh -v T/dl/IdentityPlatform/openldap-backup:/backup:ro -v T/dl/IdentityPlatform/mirror-stage/openldap:/stage -v T/app/mirror-stage.sh:/mirror-stage.sh:ro $IMG-openldap-backup:$TAG /mirror-stage.sh /backup /stage $U
docker run --rm --network none --pull never --user 0:0 --entrypoint sh -v T/dl/IdentityPlatform/backup:/backup:ro -v T/dl/IdentityPlatform/mirror-stage/keycloak:/stage -v T/app/mirror-stage.sh:/mirror-stage.sh:ro $IMG-keycloak-backup:$TAG /mirror-stage.sh /backup /stage $U"

check_mirror() {   # check_mirror NAME FILE...: mirror and stage hold exactly the copy; cp order
  local name="$1" f want got order
  shift
  want="$(printf '%s\n' "$@" manifest.sha256 STATUS | LC_ALL=C sort)"
  for d in "$MIR/$name" "$ROOT/mirror-stage/$name"; do
    got="$(ls -A "$d" | LC_ALL=C sort)"
    [ "$got" = "$want" ] || { echo "contents of $d: $got"; return 1; }
    for f in "$@" manifest.sha256 STATUS; do
      cmp -s "$ROOT/$([ "$name" = openldap ] && echo openldap-backup || echo backup)/$f" "$d/$f" || { echo "$d/$f differs"; return 1; }
    done
  done
  for d in "T/nas/IdentityPlatform/mirror/$name" "T/dl/IdentityPlatform/mirror-stage/$name"; do
    order="$(grep '^cp ' "$T/log" | awk -v d="$d/" 'index($NF, d) == 1 { sub(".*/", "", $NF); print $NF }')"
    [ "$order" = "$(printf '%s\n' "$@" manifest.sha256 STATUS)" ] || { echo "cp order into $d: $order"; return 1; }
  done
}

setup
run -- backup; rc=$?
[ "$rc" -eq 0 ] && [ "$(docker_lines)" = "$EXPECT" ] \
  && ok "backup: exit 0 and exactly the eight docker calls, in order" || bad "backup happy path" "rc=$rc; $OUT; $(docker_lines)"
[ "$(cat "$T/kcstdin" 2>/dev/null)" = "$WORD" ] && [ "$(wc -l < "$T/kcstdin" | tr -d ' ')" = 1 ] \
  && ok "keycloak-backup backup's stdin is keycloak-db's value, one line" || bad "keycloak-backup stdin"
grep -qx "VERIFYSTDIN 0" "$T/log" && ok "keycloak-backup verify gets no stdin" || bad "verify stdin" "$(grep VERIFYSTDIN "$T/log")"
no_word && ok "the value is in no output, argv, environment or file" || bad "the value leaked"
check_mirror openldap "${OL_FILES[@]}" >"$T/cm" && ok "openldap: mirror and stage hold exactly the named files, manifest and STATUS; STATUS copied last" \
  || bad "openldap mirror" "$(cat "$T/cm")"
check_mirror keycloak "${KC_FILES[@]}" >"$T/cm" && ok "keycloak: mirror and stage hold exactly the named files, manifest and STATUS; STATUS copied last" \
  || bad "keycloak mirror" "$(cat "$T/cm")"
! grep -q STATUS-PRESENT "$T/log" && ok "the old mirror's STATUS was removed before any file was copied in" || bad "STATUS present during the copy"
! grep -qE '/(\.work|\.prev|\.lock|notes\.txt)' <(grep '^cp ' "$T/log") \
  && ok ".work, .prev, .lock and unnamed files are never copied" || bad "excluded file copied" "$(grep '^cp ' "$T/log")"
[ "$(grep -c '^flock -s -w 1800 9$' "$T/log")" = 2 ] \
  && [ "$(grep -n '' "$T/log" | grep -m1 'flock -s' | cut -d: -f1)" -lt "$(grep -n '' "$T/log" | grep -m1 '^[0-9]*:cp ' | cut -d: -f1)" ] \
  && ok "each stage copy runs under flock -s on the copy's .lock" || bad "stage flock" "$(cat "$T/log")"
grep -qx "mountpoint -q T/nas" "$T/log" && ok "the NAS share is checked as a mount point" || bad "mountpoint check"
[ "$(stat -f '%Lp' "$ROOT/mirror-stage/keycloak" 2>/dev/null || stat -c '%a' "$ROOT/mirror-stage/keycloak")" = 700 ] \
  && ok "the stage is owner-only" || bad "stage mode"

# --- leak checks under xtrace ---
for mode in shellopts bashx; do
  setup
  if [ "$mode" = shellopts ]; then run SHELLOPTS=xtrace -- backup; else BASH_OPTS=-x run -- backup; fi; rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$T/kcstdin" 2>/dev/null)" = "$WORD" ] && no_word \
    && ok "under $mode: exit 0, the value only on keycloak-backup's stdin" || bad "xtrace ($mode)" "rc=$rc"
done

# --- refusals: exit 3, no docker call, nothing written ---
refused() {   # refused DESC PATTERN [ENV=V...] -- SWITCH...
  local desc="$1" pat="$2" before rc
  shift 2
  before="$(snap)"
  run "$@"; rc=$?
  [ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "$pat" && [ -z "$(docker_lines)" ] && [ "$(snap)" = "$before" ] \
    && ok "refused (3, no docker call, nothing written): $desc" || bad "refusal: $desc" "rc=$rc; $OUT; $(docker_lines)"
}
setup
STUB_HOST=test01 refused "on a replica" "backup: refused: not on a replica" -- backup
setup
rm -rf "$ROOT/cutover-state"
refused "before cutover-done (no cutover-state/)" "backup: refused: no $ROOT/cutover-state/cutover-done" -- backup
[ ! -e "$ROOT/cutover-state" ] && ok "before cutover-done: cutover-state/ not made" || bad "cutover-state made"
setup
rm -f "$ROOT/cutover-state/cutover-done"
refused "before cutover-done" "backup: refused: no $ROOT/cutover-state/cutover-done" -- backup
setup
mv "$ROOT/backup" "$ROOT/backup.real" && ln -s backup.real "$ROOT/backup"
refused "backup/ a symlink" "backup: refused: $ROOT/backup is a symlink" -- backup
for n in openldap keycloak; do
  setup
  mkdir -p "$ROOT/mirror-stage/elsewhere" && ln -s elsewhere "$ROOT/mirror-stage/$n"
  refused "mirror-stage/$n a symlink" "backup: refused: $ROOT/mirror-stage/$n is a symlink" -- backup
done
setup
refused "combined (backup verify)" "backup: refused: run it alone" -- backup verify
refused "combined (verify backup)" "backup: refused: run it alone" -- verify backup
setup
exec 7> "$ROOT/cutover-state/.lock"
if "$T/bin/flock" -n 7; then
  refused "the cutover lock held" "backup: refused: another cutover switch is running" -- backup
else
  bad "could not take the cutover lock for the lock-held case"
fi
exec 7>&-

# --- each step's failure: exit 1 naming it, no call of a later step ---
step_skips() {   # step_skips DESC PATTERN CALLS [ENV=V...]: CALLS = the docker calls made; mirror untouched
  local desc="$1" pat="$2" n="$3" rc
  shift 3
  setup
  run "$@" -- backup; rc=$?
  [ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "$pat" && [ "$(docker_lines)" = "$(printf '%s\n' "$EXPECT" | head -n "$n")" ] \
    && [ "$(cat "$MIR/openldap/STATUS")" = "OK old" ] && [ ! -e "$MIR/keycloak" ] && ! grep -q '^cp ' "$T/log" && no_word \
    && ok "fails (1, later steps skipped, mirror untouched): $desc" || bad "step failure: $desc" "rc=$rc; $OUT; $(docker_lines)"
}
step_skips "openldap-backup backup" "step 1 failed: openldap-backup backup (exit 1)" 1 STUB_OL_BACKUP_RC=1
step_skips "openldap-backup verify" "step 1 failed: openldap-backup verify (exit 1)" 2 STUB_OL_VERIFY_RC=1
step_skips "keycloak-db not running" "step 2 failed: keycloak-db's password" 3 STUB_NO_DB=1
step_skips "keycloak-db without POSTGRES_PASSWORD" "step 2 failed: keycloak-db's password" 4 STUB_NO_PW=1
step_skips "keycloak-backup backup" "step 2 failed: keycloak-backup backup (exit 1)" 5 STUB_KC_BACKUP_RC=1
step_skips "keycloak-backup verify" "step 2 failed: keycloak-backup verify (exit 1)" 6 STUB_KC_VERIFY_RC=1
step_skips "the NAS share not mounted" "step 3 failed: mirror (exit 1)" 6 STUB_NOT_MOUNTED=1
step_skips "openldap's stage run fails" "step 3 failed: mirror of openldap" 7 STUB_STAGE_RC=1

# mirror-stage.sh refusals (the real script, through the stub): no STATUS staged or mirrored.
stage_fails() {   # stage_fails DESC PATTERN FIXUP
  local desc="$1" pat="$2" rc
  setup
  eval "$3"
  run -- backup; rc=$?
  [ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "$pat" && echo "$OUT" | grep -qF "step 3 failed: mirror of openldap" \
    && [ ! -e "$ROOT/mirror-stage/openldap/STATUS" ] && [ "$(docker_lines | grep -c '^docker run ')" = 1 ] \
    && ok "stage refuses (1, nothing staged, keycloak not mirrored): $desc" || bad "stage: $desc" "rc=$rc; $OUT"
}
stage_fails "the copy's STATUS not OK" "openldap-backup/STATUS is missing or not OK" 'echo FAILED > "$ROOT/openldap-backup/STATUS"'
stage_fails "no .lock" "openldap-backup/.lock is missing" 'rm -f "$ROOT/openldap-backup/.lock"'
stage_fails "a manifest line naming a path" "has a line that is not" 'echo "$(printf %064d 0)  ../x" >> "$ROOT/openldap-backup/manifest.sha256"'
stage_fails "a manifest naming STATUS" "names STATUS" 'echo "$(printf %064d 0)  STATUS" >> "$ROOT/openldap-backup/manifest.sha256"'
stage_fails "a file not matching the manifest" "do not match" 'echo changed >> "$ROOT/openldap-backup/data.ldif"'
# A stale stage (a STATUS and a stray file from an older run) is emptied first.
setup
mkdir -p "$ROOT/mirror-stage/openldap" && echo "OK stale" > "$ROOT/mirror-stage/openldap/STATUS" && echo x > "$ROOT/mirror-stage/openldap/old.ldif"
run -- backup; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$ROOT/mirror-stage/openldap/old.ldif" ] && [ ! -e "$MIR/openldap/old.ldif" ] \
  && ok "a stale stage is emptied before staging" || bad "stale stage" "rc=$rc; $OUT"

# A mirror copy cut off part-way leaves no STATUS (the old one already removed).
setup
run STUB_CP_FAIL=data.ldif -- backup; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "step 3 failed: mirror of openldap" && [ ! -e "$MIR/openldap/STATUS" ] \
  && [ ! -e "$MIR/keycloak" ] && ok "a mirror cut off part-way has no STATUS; keycloak not started" || bad "partial mirror" "rc=$rc; $OUT"
# keycloak's copy failing after openldap's mirror: openldap's mirror is complete, keycloak's has no STATUS.
setup
run STUB_CP_FAIL=keycloak.dump -- backup; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "step 3 failed: mirror of keycloak" && [ -e "$MIR/openldap/STATUS" ] \
  && [ ! -e "$MIR/keycloak/STATUS" ] && ok "keycloak's mirror failing: exit 1, its mirror without STATUS" || bad "keycloak partial" "rc=$rc; $OUT"
# A NAS copy that did not land intact (a byte more than the stage's): checked against the manifest, no STATUS.
setup
run STUB_CP_CORRUPT=data.ldif -- backup; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "do not match its manifest.sha256; no STATUS written there" \
  && echo "$OUT" | grep -qF "step 3 failed: mirror of openldap" && [ ! -e "$MIR/openldap/STATUS" ] && [ ! -e "$MIR/keycloak" ] \
  && ok "a NAS copy not matching its manifest: exit 1, no STATUS there; keycloak not started" || bad "corrupt NAS copy" "rc=$rc; $OUT"

# A backup still holding its copy's lock (LOCK_EX on .lock): the stage's flock -s waits, then fails.
setup
exec 8< "$ROOT/openldap-backup/.lock"
if "$T/bin/flock" -n 8; then
  run STUB_FLOCK_W=1 -- backup; rc=$?
  [ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "could not take $ROOT/openldap-backup/.lock shared" \
    && echo "$OUT" | grep -qF "step 3 failed: mirror of openldap" && grep -qx 'flock -s -w 1800 9' "$T/log" \
    && [ ! -e "$ROOT/mirror-stage/openldap/STATUS" ] && [ "$(cat "$MIR/openldap/STATUS")" = "OK old" ] && [ ! -e "$MIR/keycloak" ] \
    && ok "the copy's lock held: the stage waits, fails, stages and mirrors nothing" || bad "copy lock held" "rc=$rc; $OUT"
else
  bad "could not take openldap-backup/.lock for the copy-lock-held case"
fi
exec 8<&-

# A re-run over a complete mirror: exit 0, the same contents.
setup
run -- backup >/dev/null; run -- backup; rc=$?
[ "$rc" -eq 0 ] && check_mirror keycloak "${KC_FILES[@]}" >/dev/null && ! grep -q STATUS-PRESENT "$T/log" \
  && ok "a second run over a complete mirror: exit 0, STATUS removed first again" || bad "re-run" "rc=$rc; $OUT"

[ "$fail" -eq 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
