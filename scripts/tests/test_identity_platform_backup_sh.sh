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
# step, with no call of a later step.
# count-check (cutover step 7): refused (exit 3, no docker call, nothing changed) on a replica, a
# symlinked count-check/ or target, the lock held, past cutover-done, each gate marker missing, an
# unpacked manifests-sha256 or keycloak-summary-sha256 not 64 hex, combined; exit 2 for an ARG.
# Otherwise the Mini's backup/summary.txt read first, read-only: its sha256 not unpacked's
# keycloak-summary-sha256 is exit 1 with no backup run; then count-check/ emptied (find, only when it
# holds files), keycloak-db's value on `run -v count-check:/backup ... backup`'s stdin alone (also
# under xtrace), d05's summary read read-only, and count-check/ pruned to summary.txt (no dump left;
# a failed prune: exit 1); equal (order ignored; changesets compared): counted (date, manifests-sha256,
# counts equal); not equal: exit 1, both line sets, no counted; the backup failing: its exit, no
# d05 read, pruned. Every value is a plain stand-in word made at run time.
# Run: bash scripts/tests/test_identity_platform_backup_sh.sh
set -uo pipefail
unset IDP_KEYCLOAK_DB_PASSWORD IDP_LDAP_ADMIN_PASSWORD POSTGRES_PASSWORD PGPASSWORD KC_DB_PASSWORD \
  STUB_OL_BACKUP_RC STUB_OL_VERIFY_RC STUB_KC_BACKUP_RC STUB_KC_VERIFY_RC STUB_NO_DB STUB_NO_PW \
  STUB_STAGE_RC STUB_NOT_MOUNTED STUB_CP_FAIL STUB_CP_CORRUPT STUB_FLOCK_W STUB_FIND_RC STUB_NO_SUMMARY

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
  # count-check's backup into the -v dir: its stdin kept; writes a stand-in dump, a manifest, a
  # STATUS and a .work dir (also before a failure), then $STUB_T/newsummary there as summary.txt.
  *"--profile ops run --rm -T -v "*":/backup -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup backup")
    cat > "$STUB_T/kcstdin"
    for a in "$@"; do case "$a" in *:/backup) d="${a%:/backup}" ;; esac; done
    mkdir -p "$d/.work"; echo stand-in-dump > "$d/keycloak.dump"
    [ -z "${STUB_KC_BACKUP_RC:-}" ] || exit "$STUB_KC_BACKUP_RC"
    echo stand-in-manifest > "$d/manifest.sha256"; echo OK > "$d/STATUS"
    [ -n "${STUB_NO_SUMMARY:-}" ] || cat "$STUB_T/newsummary" > "$d/summary.txt"
    exit 0 ;;
  # count-check's find in keycloak-db's image (the emptying and the prune), run here on the host
  # dir with its own expression (after `-v DIR:/t IMAGE /t`).
  "run --rm --network none --pull never --user 0:0 --entrypoint find "*)
    [ -z "${STUB_FIND_RC:-}" ] || exit "$STUB_FIND_RC"
    for a in "$@"; do case "$a" in *:/t) d="${a%:/t}" ;; esac; done
    find "$d" "${@:15}"
    exit 0 ;;
  # count-check's read of a summary.txt (cat in keycloak-db's image, read-only), here on the host dir.
  "run --rm --pull never --network none --user 0:0 --entrypoint cat "*)
    for a in "$@"; do case "$a" in *:/s:ro) d="${a%:/s:ro}" ;; esac; done
    exec cat "$d/summary.txt" ;;
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

# --- count-check (cutover step 7, Counts) ---
CC="$ROOT/count-check"
KCDB="$(sed -n 's/^KC_DB_IMAGE="\(.*\)"$/\1/p' "$SRC/identity-platform.sh")"
[ -n "$KCDB" ] || bad "KC_DB_IMAGE not found in the script"
CC_M="$(printf 'a%.0s' {1..64})"
CC_MARKERS="unpacked restored-openldap restored-keycloak started-openldap started-keycloak configured"
# The Mini's summary (theOrg's SUMMARY_SQL lines) and d05's: the same counts, changesets included,
# in another order.
MINI_SUM=$'realm master\nrealm theorg\nusers master 1\nusers theorg 12\nclients master 7\nclients theorg 9\ncredentials theorg otp 3\ncredentials theorg webauthn 2\nchangesets 120'
NEW_SUM=$'realm theorg\nrealm master\nclients theorg 9\nclients master 7\nusers theorg 12\nusers master 1\ncredentials theorg webauthn 2\ncredentials theorg otp 3\nchangesets 120'
cc_pin() {   # unpacked, its keycloak-summary-sha256 that of backup/summary.txt as it is now (unpack-bundle's check)
  local k
  k="$( (sha256sum 2>/dev/null || shasum -a 256) < "$ROOT/backup/summary.txt" | awk '{print $1}')"
  printf 'version m5-%s\nmanifests-sha256 %s\nkeycloak-summary-sha256 %s\nopenldap-summary-sha256 %s\n' \
    "${CC_M:0:12}" "$CC_M" "$k" "$CC_M" > "$ROOT/cutover-state/unpacked"
}
cc_setup() {   # what configure leaves on d05 before cutover-done; backup/ holds the Mini's copy
  rm -rf "$T/dl"/* "$T/nas"/*
  mkdir -p "$ROOT/cutover-state" "$ROOT/openldap-backup" "$ROOT/backup"
  printf '%s\n' "$MINI_SUM" > "$ROOT/backup/summary.txt"
  printf '%s\n' "$NEW_SUM" > "$T/newsummary"
  printf 'version m5-%s\nsha256 %s\n' "${CC_M:0:12}" "$CC_M" > "$ROOT/cutover-state/fetched"
  cc_pin
  printf 'date 2026-11-16T00:00:00Z\nmanifests-sha256 %s\n' "$CC_M" > "$ROOT/cutover-state/restored-openldap"
  printf 'date 2026-11-16T00:00:00Z\nmanifests-sha256 %s\n' "$CC_M" > "$ROOT/cutover-state/restored-keycloak"
  printf 'date 2026-11-16T00:00:00Z\nadmin-bind ok\n' > "$ROOT/cutover-state/started-openldap"
  printf 'date 2026-11-16T00:00:00Z\n' > "$ROOT/cutover-state/started-keycloak"
  printf 'date 2026-11-16T00:00:00Z\napply ok\nreconcile ok\n' > "$ROOT/cutover-state/configured"
}
CC_MINI="docker run --rm --pull never --network none --user 0:0 --entrypoint cat -v T/dl/IdentityPlatform/backup:/s:ro $KCDB /s/summary.txt"
CC_FIND="docker run --rm --network none --pull never --user 0:0 --entrypoint find -v T/dl/IdentityPlatform/count-check:/t $KCDB /t -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +"
CC_PRUNE="docker run --rm --network none --pull never --user 0:0 --entrypoint find -v T/dl/IdentityPlatform/count-check:/t $KCDB /t -mindepth 1 -maxdepth 1 ! -name lost+found ! -name summary.txt -exec rm -rf {} +"
# After the Mini's read (and the emptying, when count-check/ holds files): the backup, d05's read, the prune.
CC_BACKUP="$C ps -q --status running keycloak-db
docker inspect -f {{range .Config.Env}}{{if eq (index (split . \"=\") 0) \"POSTGRES_PASSWORD\"}}{{.}}{{end}}{{end}} dbid
$C --profile ops run --rm -T -v T/dl/IdentityPlatform/count-check:/backup -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup backup"
CC_REST="$CC_BACKUP
docker run --rm --pull never --network none --user 0:0 --entrypoint cat -v T/dl/IdentityPlatform/count-check:/s:ro $KCDB /s/summary.txt
$CC_PRUNE"
CC_EXPECT="$CC_MINI
$CC_REST"
cc_only_summary() {   # cc_only_summary [lost+found]: count-check/ holds summary.txt (and lost+found when named), nothing else
  [ "$(ls -A "$CC" | LC_ALL=C sort | tr '\n' ' ')" = "${1:+$1 }summary.txt " ]
}
counted_ok() {   # counted: a UTC date, unpacked's manifests-sha256, counts equal; no temp marker
  local f="$ROOT/cutover-state/counted"
  [ -f "$f" ] && [ "$(wc -l < "$f" | tr -d ' ')" -eq 3 ] \
    && grep -qE '^date [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$f" \
    && [ "$(sed -n 2p "$f")" = "manifests-sha256 $CC_M" ] && [ "$(sed -n 3p "$f")" = "counts equal" ] \
    && [ -z "$(ls -A "$ROOT/cutover-state" | grep '^\.' | grep -vxF .lock)" ]
}

run -- 2>/dev/null; echo "$OUT" | grep -q '^  count-check ' && ok "usage lists count-check" || bad "usage has no count-check line"

# The happy path: count-check/ missing (made, no find), exact calls; equal changesets, order ignored.
cc_setup
run -- count-check; rc=$?
[ "$rc" -eq 0 ] && [ "$(docker_lines)" = "$CC_EXPECT" ] && counted_ok && [ -d "$CC" ] \
  && echo "$OUT" | grep -q 'count-check: the realm names and each realm.s users, clients and credentials by type are equal (2 realm(s)); next: cutover-done' \
  && ok "count-check: exit 0, exactly the six docker calls (the Mini's read first, the -v count-check:/backup override, the prune last); counted written; equal changesets pass, line order ignored" \
  || bad "count-check happy path" "rc=$rc; $OUT; $(docker_lines)"
cc_only_summary && ok "count-check: count-check/ keeps only summary.txt (no Keycloak dump, manifest, STATUS or .work left)" \
  || bad "count-check left more than summary.txt" "$(ls -A "$CC")"
[ "$(cat "$T/kcstdin" 2>/dev/null)" = "$WORD" ] && [ "$(wc -l < "$T/kcstdin" | tr -d ' ')" = 1 ] \
  && ok "count-check: keycloak-backup backup's stdin is keycloak-db's value, one line" || bad "count-check stdin"
no_word && ok "count-check: the value is in no output, argv, environment or file" || bad "count-check: the value leaked"
[ "$(cat "$ROOT/backup/summary.txt")" = "$MINI_SUM" ] && ok "count-check: backup/ (the Mini's copy) untouched" || bad "backup/ changed"

# A stale count-check/ (an earlier run's copy) is emptied first through find; lost+found kept.
cc_setup; mkdir -p "$CC/lost+found" "$CC/.work"; echo old > "$CC/summary.txt"; echo old > "$CC/keycloak.dump"
run -- count-check; rc=$?
[ "$rc" -eq 0 ] && [ "$(docker_lines)" = "$(printf '%s\n%s\n%s' "$CC_MINI" "$CC_FIND" "$CC_REST")" ] && counted_ok \
  && cc_only_summary lost+found \
  && ok "count-check over a stale count-check/: after the Mini's read, find empties it (lost+found kept), then the same calls" \
  || bad "count-check stale dir" "rc=$rc; $OUT; $(docker_lines)"
# find failing to empty it: exit 1, no backup, no counted.
cc_setup; mkdir -p "$CC"; echo old > "$CC/summary.txt"
run STUB_FIND_RC=1 -- count-check; rc=$?
[ "$rc" -eq 1 ] && [ "$(docker_lines)" = "$(printf '%s\n%s' "$CC_MINI" "$CC_FIND")" ] && [ ! -e "$ROOT/cutover-state/counted" ] \
  && echo "$OUT" | grep -qF "count-check: $CC still holds files (find exit 1); no backup run" \
  && ok "count-check: count-check/ not emptied: exit 1, no backup, no counted" || bad "count-check find fails" "rc=$rc; $OUT; $(docker_lines)"
# The prune failing after the backup (count-check/ was missing, so no emptying): exit 1, no counted, named.
cc_setup
run STUB_FIND_RC=1 -- count-check; rc=$?
[ "$rc" -eq 1 ] && [ "$(docker_lines)" = "$CC_EXPECT" ] && [ ! -e "$ROOT/cutover-state/counted" ] \
  && echo "$OUT" | grep -qF "count-check: $CC still holds more than summary.txt (find exit 1): " \
  && echo "$OUT" | grep -qF "keycloak.dump" \
  && ok "count-check: the prune failing (the dump left): exit 1, the leftovers named, no counted" || bad "count-check prune fails" "rc=$rc; $OUT; $(docker_lines)"

# The Mini's backup/summary.txt changed after unpack (its sha256 not unpacked's
# keycloak-summary-sha256): exit 1, only the Mini's read run (no emptying, no backup), no counted.
cc_setup; printf 'date 2026-11-16T00:00:00Z\nmanifests-sha256 %s\ncounts equal\n' "$CC_M" > "$ROOT/cutover-state/counted"
mkdir -p "$CC"; echo old > "$CC/summary.txt"
printf '%s\n' "${MINI_SUM/users theorg 12/users theorg 11}" > "$ROOT/backup/summary.txt"
run -- count-check; rc=$?
[ "$rc" -eq 1 ] && [ "$(docker_lines)" = "$CC_MINI" ] && [ ! -e "$ROOT/cutover-state/counted" ] && [ ! -e "$T/kcstdin" ] \
  && echo "$OUT" | grep -qF "count-check: refused: $ROOT/backup/summary.txt is not the Mini's copy (its sha256 " \
  && echo "$OUT" | grep -qF "is not unpacked's keycloak-summary-sha256 " && echo "$OUT" | grep -qF "no backup run, no counted marker" \
  && [ "$(cat "$CC/summary.txt")" = old ] \
  && ok "count-check with a changed backup/summary.txt: exit 1, only the Mini's read, no backup run, no counted (the earlier one removed)" \
  || bad "count-check changed Mini summary" "rc=$rc; $OUT; $(docker_lines)"
# One trailing newline more is another file: refused as well.
cc_setup; printf '\n' >> "$ROOT/backup/summary.txt"
run -- count-check; rc=$?
[ "$rc" -eq 1 ] && [ "$(docker_lines)" = "$CC_MINI" ] && [ ! -e "$ROOT/cutover-state/counted" ] \
  && echo "$OUT" | grep -qF "is not the Mini's copy" \
  && ok "count-check with backup/summary.txt one newline longer: exit 1, no backup run" || bad "count-check trailing newline" "rc=$rc; $OUT"

# A mismatch: exit 1, both differing line sets printed, no counted (an earlier counted removed).
cc_setup
printf '%s\n' "${NEW_SUM/users theorg 12/users theorg 11}" > "$T/newsummary"
printf 'date 2026-11-16T00:00:00Z\nmanifests-sha256 %s\ncounts equal\n' "$CC_M" > "$ROOT/cutover-state/counted"
run -- count-check; rc=$?
mism="$(printf '%s\n' "$OUT" | sed -n '/only in the Mini/,$p')"
[ "$rc" -eq 1 ] && [ ! -e "$ROOT/cutover-state/counted" ] && [ "$(docker_lines)" = "$CC_EXPECT" ] \
  && echo "$OUT" | grep -qF "count-check: the counts differ (realm, users, clients, credentials, changesets lines); no counted marker" \
  && [ "$mism" = "  only in the Mini's $ROOT/backup/summary.txt:
    users theorg 12
  only in d05's $CC/summary.txt:
    users theorg 11" ] && no_word && cc_only_summary \
  && ok "count-check mismatch: exit 1, exactly the differing lines of each, no counted (the earlier one removed); count-check/ pruned to summary.txt" \
  || bad "count-check mismatch" "rc=$rc; $OUT"
# A realm only on one side.
cc_setup; printf '%s\nrealm extra\n' "$NEW_SUM" > "$T/newsummary"
run -- count-check; rc=$?
[ "$rc" -eq 1 ] && [ ! -e "$ROOT/cutover-state/counted" ] && printf '%s\n' "$OUT" | grep -qx '    realm extra' \
  && ok "count-check: a realm only in d05's: exit 1, named, no counted" || bad "count-check extra realm" "rc=$rc; $OUT"
# changesets alone differing is a mismatch (keycloak_backup.sh:175-182 and :553 at theOrg bd0c6bff:
# Liquibase's changelog count, which restore requires equal): exit 1, the two changesets lines, no counted.
cc_setup; printf '%s\n' "${NEW_SUM/changesets 120/changesets 131}" > "$T/newsummary"
run -- count-check; rc=$?
mism="$(printf '%s\n' "$OUT" | sed -n '/only in the Mini/,$p')"
[ "$rc" -eq 1 ] && [ ! -e "$ROOT/cutover-state/counted" ] && [ "$(docker_lines)" = "$CC_EXPECT" ] \
  && echo "$OUT" | grep -qF "count-check: the counts differ (realm, users, clients, credentials, changesets lines); no counted marker" \
  && [ "$mism" = "  only in the Mini's $ROOT/backup/summary.txt:
    changesets 120
  only in d05's $CC/summary.txt:
    changesets 131" ] && cc_only_summary \
  && ok "count-check: changesets alone differing (120 vs 131): exit 1, both changesets lines printed, no counted" \
  || bad "count-check changesets differ" "rc=$rc; $OUT"
# A summary without realm lines is not equal counts.
cc_setup; STUB_NO_SUMMARY=1 run -- count-check; rc=$?
[ "$rc" -eq 1 ] && [ ! -e "$ROOT/cutover-state/counted" ] \
  && echo "$OUT" | grep -qF "count-check: could not read a realm line from d05's $CC/summary.txt; no counted marker" \
  && ok "count-check: no summary.txt from the backup: exit 1, no counted" || bad "count-check no summary" "rc=$rc; $OUT"
cc_setup; printf 'changesets 120\n' > "$ROOT/backup/summary.txt"; printf 'changesets 120\n' > "$T/newsummary"; cc_pin
run -- count-check; rc=$?
[ "$rc" -eq 1 ] && [ ! -e "$ROOT/cutover-state/counted" ] && [ "$(docker_lines)" = "$CC_MINI" ] \
  && echo "$OUT" | grep -qF "count-check: could not read a realm line from the Mini's $ROOT/backup/summary.txt; no backup run" \
  && ok "count-check: summaries with no realm line are not equal counts: exit 1, no backup run, no counted" || bad "count-check no realm" "rc=$rc; $OUT"

# The backup failing: its exit, no d05 read, no counted, the partial dump pruned. keycloak-db's
# password not taken: 1, no backup.
cc_setup; run STUB_KC_BACKUP_RC=4 -- count-check; rc=$?
[ "$rc" -eq 4 ] && [ "$(docker_lines)" = "$(printf '%s\n%s\n%s' "$CC_MINI" "$CC_BACKUP" "$CC_PRUNE")" ] && [ ! -e "$ROOT/cutover-state/counted" ] \
  && echo "$OUT" | grep -qF "count-check: keycloak-backup backup exited 4; no counted marker" && no_word \
  && [ -z "$(ls -A "$CC")" ] \
  && ok "count-check: the backup failing: its exit (4), no d05 read, no counted, its partial dump removed" || bad "count-check backup fails" "rc=$rc; $OUT; $(docker_lines)"
cc_setup; run STUB_NO_DB=1 -- count-check; rc=$?
[ "$rc" -eq 1 ] && [ "$(docker_lines)" = "$(printf '%s\n' "$CC_EXPECT" | head -n 2)" ] && [ ! -e "$ROOT/cutover-state/counted" ] \
  && echo "$OUT" | grep -qF "count-check: keycloak-db is not running" \
  && ok "count-check: keycloak-db not running: exit 1, no backup, no counted" || bad "count-check no db" "rc=$rc; $OUT; $(docker_lines)"

# Under xtrace: exit 0, the value only on keycloak-backup's stdin.
for mode in shellopts bashx; do
  cc_setup
  if [ "$mode" = shellopts ]; then run SHELLOPTS=xtrace -- count-check; else BASH_OPTS=-x run -- count-check; fi; rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$T/kcstdin" 2>/dev/null)" = "$WORD" ] && no_word && counted_ok \
    && ok "count-check under $mode: exit 0, the value only on keycloak-backup's stdin" || bad "count-check xtrace ($mode)" "rc=$rc"
done

# Refusals: exit 3, no docker call, nothing changed.
cc_setup; STUB_HOST=test01 refused "count-check on a replica" "count-check: refused: not on a replica" -- count-check
for d in count-check backup openldap-backup; do
  cc_setup; rm -rf "$ROOT/$d"; mkdir -p "$ROOT/$d.real"; ln -s "$d.real" "$ROOT/$d"
  refused "count-check with $d/ a symlink" "count-check: refused: $ROOT/$d is a symlink" -- count-check
done
cc_setup; echo "date 2026-11-16T00:00:00Z" > "$ROOT/cutover-state/cutover-done"
refused "count-check past cutover-done" "count-check: refused: $ROOT/cutover-state/cutover-done exists" -- count-check
for m in $CC_MARKERS; do
  cc_setup; rm -f "$ROOT/cutover-state/$m"
  refused "count-check without $m" "count-check: refused: cutover marker missing or invalid: $m (" -- count-check
done
cc_setup; printf 'date 2026-11-16T00:00:00Z\napply ok\n' > "$ROOT/cutover-state/configured"
refused "count-check with configured without reconcile ok" "configured (no apply ok and reconcile ok)" -- count-check
cc_setup; printf 'version m5-%s\nmanifests-sha256 0123\n' "${CC_M:0:12}" > "$ROOT/cutover-state/unpacked"
refused "count-check with unpacked's manifests-sha256 not 64 hex" "unpacked (manifests-sha256 '0123' is not 64 hex)" -- count-check
cc_setup; printf 'version m5-%s\nmanifests-sha256 %s\n' "${CC_M:0:12}" "$CC_M" > "$ROOT/cutover-state/unpacked"
refused "count-check with unpacked without keycloak-summary-sha256" "unpacked (keycloak-summary-sha256 '' is not 64 hex)" -- count-check
cc_setup
refused "count-check combined (verify count-check)" "count-check: refused: run it alone" -- verify count-check
cc_setup
exec 7> "$ROOT/cutover-state/.lock"
if "$T/bin/flock" -n 7; then
  refused "count-check with the cutover lock held" "count-check: refused: another cutover switch is running" -- count-check
else
  bad "could not take the cutover lock for the count-check lock-held case"
fi
exec 7>&-
cc_setup; before="$(snap)"; run -- count-check extra; rc=$?
[ "$rc" -eq 2 ] && echo "$OUT" | grep -qF "count-check: usage: count-check (no ARG)" && [ -z "$(docker_lines)" ] && [ "$(snap)" = "$before" ] \
  && ok "count-check with an ARG: exit 2, no docker call, nothing changed" || bad "count-check ARG" "rc=$rc; $OUT"

[ "$fail" -eq 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
