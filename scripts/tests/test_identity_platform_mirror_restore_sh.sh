#!/bin/bash
# d05/apps/identity-platform/identity-platform.sh restore-mirror and restore-mirror-accept-age
# (asyla #1101): a rebuilt d05 (or test01, its replica) restored from the NAS mirror, against stubs
# (docker, hostname, flock, mountpoint, chown, and a cp that logs and then copies). The docker stub
# runs the switch's inline unstage script (MIRROR_UNSTAGE_SH) with sh on the mounted host dirs, as
# the image would as root (chown is stubbed: the tests are not root).
# Happy path: exactly the docker calls, in order; each copy staged from the mirror (named files,
# manifest, STATUS last; unnamed files never), copied into its empty target (named files, manifest,
# STATUS last; dir 0700, files 0600; lost+found kept) before theOrg's restore; openldap's restore
# with OPENLDAP_BACKUP_CONFIG_MOUNT=rw and no stdin; keycloak-db's value read from the running
# container and written to keycloak-backup restore's stdin alone (never an argv, an environment, a
# file or the output, also under SHELLOPTS=xtrace and bash -x); both mirror-restored-* markers; the
# mirror never changed (paths, modes, mtimes, contents). Also on a replica.
# Refusals (exit 3, nothing changed): the value's name in the environment, each symlinked path, the
# lock held, each M5 marker, an invalid marker, both markers valid, compose unable to tell, a
# container, each target holding data, keycloak-db not healthy, the NAS not mounted, each bad STATUS,
# a mirror older than 48 hours, a STATUS more than 300 s in the future, or the two copies' STATUS
# times (a restored copy's from its marker) more than 2 hours apart (restore-mirror-accept-age
# restores each, with a warning), a bad manifest or one with
# no summary.txt, the mirror changed while staged, combined with another switch. Exit 2 for an ARG.
# Failures: a stage or target that does not match its manifest (exit 1, no STATUS, no restore);
# the restores' exits pass through with no marker; a re-run skips a valid marker.
# Every value is a plain stand-in word made at run time.
# Run: bash scripts/tests/test_identity_platform_mirror_restore_sh.sh
set -uo pipefail
unset IDP_KEYCLOAK_DB_PASSWORD IDP_LDAP_ADMIN_PASSWORD POSTGRES_PASSWORD PGPASSWORD KC_DB_PASSWORD \
  STUB_PS_RC STUB_IDS STUB_HEALTH STUB_NO_DB STUB_OL_RESTORE_RC STUB_KC_RESTORE_RC STUB_UNSTAGE_RC \
  STUB_NOT_MOUNTED STUB_CHANGE STUB_CP_CORRUPT OPENLDAP_BACKUP_CONFIG_MOUNT

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO/d05/apps/identity-platform"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0 oks=0
ok()  { echo "ok   $1"; oks=$((oks + 1)); }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }

mkdir -p "$T/home/scripts/docker" "$T/bin" "$T/app" "$T/dl" "$T/nas"
printf 'DOCKER_DL=%s\nDOCKER_D1=%s\n' "$T/dl" "$T/nas" > "$T/home/scripts/docker/common.env"
cp "$SRC"/{compose.yml,identity-platform.sh,mirror-stage.sh} "$T/app/"
ROOT="$T/dl/IdentityPlatform"
MIR="$T/nas/IdentityPlatform/mirror"
SW="$ROOT/cutover-state"
WORD="stand-in-db-word-$$"     # keycloak-db's stand-in value; only in $T/dbword and the checks
printf '%s' "$WORD" > "$T/dbword"
TAG="stand-in-tag"

# Every stub turns xtrace off first (SHELLOPTS=xtrace reaches them too) and logs its call with $T
# shortened to T. docker logs the unstage script's text as UNSTAGE_SH and dumps its environment to
# $T/envdump (read only by the checks).
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
args=() nx=false
for a in "$@"; do
  if $nx; then args+=(UNSTAGE_SH); nx=false; else args+=("$a"); [ "$a" != -c ] || nx=true; fi
done
echo "docker ${args[*]}" | sed -E "s#-f [^ ]*/compose.yml#-f compose.yml#; s# --project-directory [^ ]*##; s#$STUB_T#T#g" >> "$STUB_LOG"
env >> "$STUB_T/envdump"
case "${args[*]}" in
  *"--profile restored ps -a -q openldap keycloak")
    [ -z "${STUB_PS_RC:-}" ] || exit "$STUB_PS_RC"
    [ -z "${STUB_IDS:-}" ] || echo "$STUB_IDS" ;;
  *" ps -q keycloak-db") echo dbid ;;
  "inspect -f {{if .State.Health}}"*" dbid") echo "${STUB_HEALTH:-healthy}" ;;
  *" ps -q --status running keycloak-db") [ -n "${STUB_NO_DB:-}" ] || echo dbid ;;
  "inspect -f "*POSTGRES_PASSWORD*" dbid") printf '%s=%s\n' POSTGRES_PASSWORD "$(cat "$STUB_T/dbword")" ;;
  *"--profile ops run --rm -T openldap-backup restore")
    echo "OLRESTORE mount=${OPENLDAP_BACKUP_CONFIG_MOUNT:-unset} stdin=$(wc -c | tr -d ' ') target=$(ls -A "$STUB_T/dl/IdentityPlatform/openldap-backup" | LC_ALL=C sort | tr '\n' ' ')" >> "$STUB_LOG"
    exit "${STUB_OL_RESTORE_RC:-0}" ;;
  *"--profile ops run --rm -T -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup restore")
    cat > "$STUB_T/kcstdin"
    echo "KCRESTORE target=$(ls -A "$STUB_T/dl/IdentityPlatform/backup" | LC_ALL=C sort | tr '\n' ' ')" >> "$STUB_LOG"
    exit "${STUB_KC_RESTORE_RC:-0}" ;;
  # The unstage in the copy's image: its own script, run here with sh on the mounted host dirs.
  "run --rm --network none --pull never --user 0:0 --entrypoint sh "*" -c UNSTAGE_SH mirror-unstage /stage /backup "*)
    [ -z "${STUB_UNSTAGE_RC:-}" ] || exit "$STUB_UNSTAGE_RC"
    s="" t="" i=0 ci=0
    for a in "$@"; do
      i=$((i + 1))
      case "$a" in *:/stage:ro) s="${a%:/stage:ro}" ;; *:/backup) t="${a%:/backup}" ;; -c) ci=$i ;; esac
    done
    exec sh -c "${@:ci+1:1}" mirror-unstage "$s" "$t" "${@:ci+5}" ;;
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
cat > "$T/bin/mountpoint" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
echo "mountpoint $*" | sed "s#$STUB_T#T#g" >> "$STUB_LOG"
[ -z "${STUB_NOT_MOUNTED:-}" ]
EOF
cat > "$T/bin/chown" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
echo "chown $*" | sed "s#$STUB_T#T#g" >> "$STUB_LOG"
EOF
# cp: logs its call, then copies. STUB_CP_CORRUPT=SUFFIX appends a byte to a copy whose destination
# ends in /SUFFIX (a copy that did not land intact). STUB_CHANGE=status|manifest rewrites the
# mirror's openldap STATUS or manifest.sha256 right after the manifest is staged (a backup writing
# the mirror meanwhile).
cat > "$T/bin/cp" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
dst="${!#}"
echo "cp $*" | sed "s#$STUB_T#T#g" >> "$STUB_LOG"
/bin/cp "$@" || exit
if [ -n "${STUB_CP_CORRUPT:-}" ] && [[ $dst == *"/$STUB_CP_CORRUPT" ]]; then printf x >> "$dst"; fi
m="$STUB_T/nas/IdentityPlatform/mirror/openldap"
case "${STUB_CHANGE:-}:$dst" in
  status:*/mirror-stage/openldap/manifest.sha256) echo "OK 2099-01-01T00:00:00Z" > "$m/STATUS" ;;
  manifest:*/mirror-stage/openldap/manifest.sha256) head -n 1 "$m/manifest.sha256" >> "$m/manifest.sha256" ;;
esac
exit 0
EOF
chmod +x "$T/bin/docker" "$T/bin/hostname" "$T/bin/flock" "$T/bin/mountpoint" "$T/bin/chown" "$T/bin/cp"
hash -r
for s in docker hostname flock mountpoint chown cp; do
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

iso_ago() {   # iso_ago HOURS: the UTC time HOURS ago, as theOrg's STATUS writes it
  python3 -I -c 'import datetime, sys
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=float(sys.argv[1]))
print(t.strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"
}
hours_since() {   # hours_since ISO: whole hours from ISO to now
  python3 -I -c 'import datetime, sys
t = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
print(int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() // 3600))' "$1"
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
mode_of() { python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }

# One mirror copy as mirror_copy leaves it: the named files (owner-only), manifest.sha256, STATUS
# "OK <time HOURS ago>", plus a file the manifest does not name (never staged).
make_mirror() {   # make_mirror DIR HOURS FILE...
  local d="$1" h="$2" f
  shift 2
  mkdir -p "$d"
  for f in "$@"; do printf 'stand-in %s body\n' "$f" > "$d/$f"; done
  (cd "$d" && sha256sum "$@" > manifest.sha256)
  echo "OK $(iso_ago "$h")" > "$d/STATUS"
  echo stray > "$d/notes.txt"
  chmod 0600 "$d"/*
}
OL_FILES=(config.ldif data.ldif summary.txt)
KC_FILES=(keycloak.dump summary.txt)
setup() {   # a rebuilt host: empty targets (backup/ and openldap-data with lost+found), fresh mirrors
  rm -rf "$T/dl"/* "$T/nas"/*
  mkdir -p "$SW" "$ROOT/openldap-data/lost+found" "$ROOT/openldap-config" "$ROOT/backup/lost+found"
  : > "$SW/.lock"
  make_mirror "$MIR/openldap" 2 "${OL_FILES[@]}"
  make_mirror "$MIR/keycloak" 2 "${KC_FILES[@]}"
}
valid_marker() {   # valid_marker NAME: a mirror-restored-NAME as the switch writes it (status: the mirror's STATUS)
  printf 'date 2026-11-20T00:00:00Z\nsource mirror\nstatus %s\nsummary-sha256 %s\n' \
    "$(head -n 1 "$MIR/$1/STATUS")" "$(printf 'a%.0s' {1..64})" > "$SW/mirror-restored-$1"
}
docker_lines() { grep '^docker ' "$T/log"; }
no_run() { ! docker_lines | grep -q ' run '; }   # no docker run and no compose run (ps and inspect only)
no_marker() { [ ! -e "$SW/mirror-restored-openldap" ] && [ ! -e "$SW/mirror-restored-keycloak" ]; }
no_word() {   # the value in no output, argv, environment or file under the host's dirs
  ! printf '%s' "$OUT" | grep -qF "$WORD" && ! grep -qF "$WORD" "$T/log" "$T/envdump" \
    && ! grep -rqF "$WORD" "$T/dl" "$T/nas"
}

# --- usage ---
run --; echo "$OUT" | grep -q '^  restore-mirror ' && echo "$OUT" | grep -q '^  restore-mirror-accept-age ' \
  && ok "usage lists restore-mirror and restore-mirror-accept-age" || bad "usage" "$OUT"

# --- the happy path: exact calls ---
C="docker compose -f compose.yml"
IMG="gitea.asyla.org/theorg/identity-platform"
UNSTAGE="docker run --rm --network none --pull never --user 0:0 --entrypoint sh"
DB_HEALTH="$C ps -q keycloak-db
docker inspect -f {{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}} dbid"
DB_PW="$C ps -q --status running keycloak-db
docker inspect -f {{range .Config.Env}}{{if eq (index (split . \"=\") 0) \"POSTGRES_PASSWORD\"}}{{.}}{{end}}{{end}} dbid"
OL_CALLS="$UNSTAGE -v T/dl/IdentityPlatform/mirror-stage/openldap:/stage:ro -v T/dl/IdentityPlatform/openldap-backup:/backup $IMG-openldap-backup:$TAG -c UNSTAGE_SH mirror-unstage /stage /backup config.ldif data.ldif summary.txt
$C --profile ops run --rm -T openldap-backup restore"
KC_CALLS="$DB_PW
$UNSTAGE -v T/dl/IdentityPlatform/mirror-stage/keycloak:/stage:ro -v T/dl/IdentityPlatform/backup:/backup $IMG-keycloak-backup:$TAG -c UNSTAGE_SH mirror-unstage /stage /backup keycloak.dump summary.txt
$C --profile ops run --rm -T -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup restore"
PS="$C --profile restored ps -a -q openldap keycloak"
EXPECT="$PS
$DB_HEALTH
$OL_CALLS
$KC_CALLS"

cp_order() {   # cp_order DIR: the names cp wrote into DIR (T-relative), in order
  grep '^cp ' "$T/log" | awk -v d="$1/" 'index($NF, d) == 1 { sub(".*/", "", $NF); print $NF }'
}
check_copy() {   # check_copy NAME TARGET FILE...: stage and target hold exactly the mirror's copy
  local name="$1" tgt="$2" f d want got
  shift 2
  want="$(printf '%s\n' "$@" manifest.sha256 STATUS | LC_ALL=C sort)"
  for d in "$ROOT/mirror-stage/$name" "$ROOT/$tgt"; do
    got="$(ls -A "$d" | grep -vx lost+found | LC_ALL=C sort)"
    [ "$got" = "$want" ] || { echo "contents of $d: $got"; return 1; }
    for f in "$@" manifest.sha256 STATUS; do
      cmp -s "$MIR/$name/$f" "$d/$f" || { echo "$d/$f differs from the mirror's"; return 1; }
    done
  done
  [ "$(cp_order "T/dl/IdentityPlatform/mirror-stage/$name")" = "$(printf '%s\n' "$@" manifest.sha256 STATUS)" ] \
    || { echo "cp order into the stage: $(cp_order "T/dl/IdentityPlatform/mirror-stage/$name")"; return 1; }
  [ "$(cp_order "T/dl/IdentityPlatform/$tgt")" = "$(printf '%s\n' "$@" manifest.sha256 .STATUS.tmp)" ] \
    || { echo "cp order into the target: $(cp_order "T/dl/IdentityPlatform/$tgt")"; return 1; }
  [ "$(mode_of "$ROOT/$tgt")" = 700 ] || { echo "$tgt mode $(mode_of "$ROOT/$tgt")"; return 1; }
  for f in "$@" manifest.sha256 STATUS; do
    [ "$(mode_of "$ROOT/$tgt/$f")" = 600 ] || { echo "$tgt/$f mode $(mode_of "$ROOT/$tgt/$f")"; return 1; }
  done
}
check_marker() {   # check_marker NAME: mirror-restored-NAME's four lines match the mirror
  local f="$SW/mirror-restored-$1"
  [ "$(wc -l < "$f" | tr -d ' ')" = 4 ] && grep -qE '^date [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$f" \
    && [ "$(sed -n 2p "$f")" = "source mirror" ] && [ "$(sed -n 3p "$f")" = "status $(head -n 1 "$MIR/$1/STATUS")" ] \
    && [ "$(sed -n 4p "$f")" = "summary-sha256 $(sha256sum < "$MIR/$1/summary.txt" | awk '{print $1}')" ]
}

for host in d05 test01; do
  setup
  nas_before="$(snap_of "$T/nas")"
  STUB_HOST=$host run -- restore-mirror; rc=$?
  [ "$rc" -eq 0 ] && [ "$(docker_lines)" = "$EXPECT" ] \
    && ok "on $host: exit 0 and exactly the docker calls, in order" || bad "happy path on $host" "rc=$rc; $OUT; $(docker_lines)"
  [ "$(snap_of "$T/nas")" = "$nas_before" ] && ok "on $host: the mirror is unchanged (paths, modes, mtimes, contents)" \
    || bad "mirror changed on $host"
  check_marker openldap && check_marker keycloak && ok "on $host: both mirror-restored-* markers (date, source mirror, STATUS, summary sha256)" \
    || bad "markers on $host" "$(cat "$SW"/mirror-restored-* 2>&1)"
done
check_copy openldap openldap-backup "${OL_FILES[@]}" >"$T/cc" \
  && ok "openldap: stage and openldap-backup/ hold exactly the named files, manifest and STATUS (last); 0700 and 0600" \
  || bad "openldap copy" "$(cat "$T/cc")"
check_copy keycloak backup "${KC_FILES[@]}" >"$T/cc" \
  && ok "keycloak: stage and backup/ hold exactly the named files, manifest and STATUS (last); 0700 and 0600" \
  || bad "keycloak copy" "$(cat "$T/cc")"
[ -d "$ROOT/backup/lost+found" ] && [ -d "$ROOT/openldap-data/lost+found" ] && ok "lost+found is kept and allowed" || bad "lost+found"
! grep -q notes.txt <(grep '^cp ' "$T/log") && ok "a file the manifest does not name is never copied" || bad "unnamed file copied"
grep -qx "OLRESTORE mount=rw stdin=0 target=STATUS config.ldif data.ldif manifest.sha256 summary.txt " "$T/log" \
  && ok "openldap-backup restore: OPENLDAP_BACKUP_CONFIG_MOUNT=rw, no stdin, after the copy landed with its STATUS" \
  || bad "openldap restore" "$(grep OLRESTORE "$T/log")"
grep -qx "KCRESTORE target=STATUS keycloak.dump lost+found manifest.sha256 summary.txt " "$T/log" \
  && ok "keycloak-backup restore runs after the copy landed with its STATUS" || bad "keycloak restore" "$(grep KCRESTORE "$T/log")"
[ "$(cat "$T/kcstdin" 2>/dev/null)" = "$WORD" ] && [ "$(wc -l < "$T/kcstdin" | tr -d ' ')" = 1 ] \
  && ok "keycloak-backup restore's stdin is keycloak-db's value, one line" || bad "keycloak-backup stdin"
no_word && ok "the value is in no output, argv, environment or file" || bad "the value leaked"
grep -qx "chown 0:0 T/dl/IdentityPlatform/openldap-backup" "$T/log" && grep -qx "chown 0:0 T/dl/IdentityPlatform/backup" "$T/log" \
  && ok "each target is made root's in the image" || bad "chown" "$(grep chown "$T/log")"
grep -qx "mountpoint -q T/nas" "$T/log" && ok "the NAS share is checked as a mount point" || bad "mountpoint check"
[ "$(mode_of "$ROOT/mirror-stage/openldap")" = 700 ] && ok "the stage is owner-only" || bad "stage mode"

# --- leak checks under xtrace ---
for mode in shellopts bashx; do
  setup
  if [ "$mode" = shellopts ]; then run SHELLOPTS=xtrace -- restore-mirror; else BASH_OPTS=-x run -- restore-mirror; fi; rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$T/kcstdin" 2>/dev/null)" = "$WORD" ] && no_word \
    && ok "under $mode: exit 0, the value only on keycloak-backup restore's stdin" || bad "xtrace ($mode)" "rc=$rc"
done

# --- refusals: exit 3, nothing changed ---
refused() {   # refused DESC PATTERN [ENV=V...] -- SWITCH...: no docker call at all
  local desc="$1" pat="$2" before rc
  shift 2
  before="$(snap)"
  run "$@"; rc=$?
  [ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "$pat" && [ -z "$(docker_lines)" ] && [ "$(snap)" = "$before" ] \
    && ok "refused (3, no docker call, nothing changed): $desc" || bad "refusal: $desc" "rc=$rc; $OUT; $(docker_lines)"
}
refused_ro() {   # refused_ro DESC PATTERN [ENV=V...] -- SWITCH...: ps and inspect only
  local desc="$1" pat="$2" before rc
  shift 2
  before="$(snap)"
  run "$@"; rc=$?
  [ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "$pat" && no_run && [ "$(snap)" = "$before" ] \
    && ok "refused (3, no run, nothing changed): $desc" || bad "refusal: $desc" "rc=$rc; $OUT; $(docker_lines)"
}
setup
refused "IDP_KEYCLOAK_DB_PASSWORD in the environment" "restore-mirror: refused: IDP_KEYCLOAK_DB_PASSWORD is set" \
  IDP_KEYCLOAK_DB_PASSWORD="$WORD" -- restore-mirror
for p in "$SW" "$ROOT/backup" "$ROOT/openldap-backup" "$ROOT/openldap-data" "$ROOT/openldap-config" \
  "$ROOT/mirror-stage" "$ROOT/mirror-stage/openldap" "$ROOT/mirror-stage/keycloak" "$MIR" "$MIR/openldap" "$MIR/keycloak"; do
  setup
  mkdir -p "$p"
  mv "$p" "$p.real" && ln -s "$(basename "$p").real" "$p"
  refused "${p#"$T"/} a symlink" "refused: $p is a symlink" -- restore-mirror
done
setup
exec 7> "$SW/.lock"
if "$T/bin/flock" -n 7; then
  refused "the cutover lock held" "restore-mirror: refused: another cutover switch is running" -- restore-mirror
  refused "the cutover lock held (accept-age)" "restore-mirror-accept-age: refused: another cutover switch is running" -- restore-mirror-accept-age
else
  bad "could not take the cutover lock for the lock-held case"
fi
exec 7>&-
for m in fetched unpack-started unpacked restored-openldap restored-keycloak started-openldap started-keycloak configured reset-off counted cutover-done; do
  setup
  echo "date 2026-11-16T00:00:00Z" > "$SW/$m"
  refused "the M5 marker $m" "refused: $SW/$m exists (an M5 cutover marker" -- restore-mirror
done
for n in openldap keycloak; do
  setup
  echo "date 2026-11-20T00:00:00Z" > "$SW/mirror-restored-$n"
  refused "an invalid mirror-restored-$n" "refused: $SW/mirror-restored-$n exists but is not a valid marker" -- restore-mirror
done
setup
valid_marker openldap; valid_marker keycloak
refused "both markers valid" "refused: both copies are restored from the mirror already" -- restore-mirror
setup
refused_ro "compose cannot tell" "refused: docker compose ps for openldap and keycloak failed" STUB_PS_RC=1 -- restore-mirror
refused_ro "a container exists" "refused: an openldap or keycloak container exists" STUB_IDS=stand-in-id -- restore-mirror
for d in openldap-backup openldap-data openldap-config backup; do
  setup
  mkdir -p "$ROOT/$d" && echo stray > "$ROOT/$d/left"
  refused_ro "$d/ holding data" "refused: $ROOT/$d holds more than lost+found" -- restore-mirror
done
setup
refused_ro "keycloak-db not healthy" "refused: keycloak-db is starting, not running and healthy" STUB_HEALTH=starting -- restore-mirror
refused_ro "the NAS not mounted" "refused: $T/nas is not a mount point" STUB_NOT_MOUNTED=1 -- restore-mirror
for st in missing "OK old" "FAIL 2026-11-20T00:00:00Z" "OK 2026-11-20T00:00:00Z extra" "OK 2026-11-20 00:00:00Z"; do
  setup
  if [ "$st" = missing ]; then rm -f "$MIR/openldap/STATUS"; else echo "$st" > "$MIR/openldap/STATUS"; fi
  refused_ro "openldap STATUS $st" "refused: $MIR/openldap/STATUS is missing or not 'OK <UTC time>'" -- restore-mirror
done
setup
rm -f "$MIR/keycloak/STATUS"
refused_ro "keycloak STATUS missing" "refused: $MIR/keycloak/STATUS is missing" -- restore-mirror
for st in "OK 2026-13-01T00:00:00Z" "OK 2026-11-20T24:00:00Z"; do
  setup
  echo "$st" > "$MIR/openldap/STATUS"
  refused_ro "an impossible STATUS time ($st)" "refused: $MIR/openldap/STATUS has no valid time" -- restore-mirror
done

# --- the 48-hour rule, and iso_epoch's arithmetic against python3 ---
setup
make_mirror "$MIR/openldap" 49.5 "${OL_FILES[@]}"
refused_ro "a mirror 49 hours old" "refused: the openldap mirror is 49 hours old" -- restore-mirror
echo "$OUT" | grep -qF "to restore it anyway: restore-mirror-accept-age" && ok "the age refusal names restore-mirror-accept-age" \
  || bad "age refusal hint" "$OUT"
old="$(head -n 1 "$MIR/openldap/STATUS")"
run -- restore-mirror-accept-age; rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -qF "[WARN] restore-mirror-accept-age: the openldap mirror is 49 hours old ($old); restoring it anyway" \
  && [ "$(sed -n 3p "$SW/mirror-restored-openldap")" = "status $old" ] && check_marker keycloak \
  && ok "restore-mirror-accept-age: the old mirror restored, with a warning; both markers" || bad "accept-age" "rc=$rc; $OUT"
setup
make_mirror "$MIR/openldap" 47.5 "${OL_FILES[@]}"
make_mirror "$MIR/keycloak" 47.5 "${KC_FILES[@]}"
run -- restore-mirror; rc=$?
[ "$rc" -eq 0 ] && ! echo "$OUT" | grep -q WARN && check_marker openldap && check_marker keycloak \
  && ok "mirrors 47 hours old are restored without a warning" || bad "47 hours" "rc=$rc; $OUT"

# --- a STATUS in the future (more than 300 s), and the two copies more than 2 hours apart ---
setup
make_mirror "$MIR/openldap" -0.1 "${OL_FILES[@]}"
make_mirror "$MIR/keycloak" -0.1 "${KC_FILES[@]}"
refused_ro "a STATUS 6 minutes in the future" "refused: the openldap mirror's STATUS is" -- restore-mirror
echo "$OUT" | grep -qE "STATUS is 3[0-9]{2} seconds in the future .*more than 300 .*to restore it anyway: restore-mirror-accept-age" \
  && ok "the future refusal gives the seconds and names restore-mirror-accept-age" || bad "future refusal text" "$OUT"
run -- restore-mirror-accept-age; rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -qF "[WARN] restore-mirror-accept-age: the openldap mirror's STATUS is" \
  && check_marker openldap && check_marker keycloak \
  && ok "restore-mirror-accept-age: a STATUS in the future restored, with a warning; both markers" || bad "future accept-age" "rc=$rc; $OUT"
setup
make_mirror "$MIR/openldap" -0.05 "${OL_FILES[@]}"
make_mirror "$MIR/keycloak" -0.05 "${KC_FILES[@]}"
run -- restore-mirror; rc=$?
[ "$rc" -eq 0 ] && ! echo "$OUT" | grep -q WARN && check_marker openldap && check_marker keycloak \
  && ok "a STATUS 3 minutes in the future is restored without a warning" || bad "3 minutes ahead" "rc=$rc; $OUT"
setup
make_mirror "$MIR/keycloak" 4.5 "${KC_FILES[@]}"
refused_ro "the copies 2.5 hours apart" "refused: the openldap and keycloak STATUS times differ by" -- restore-mirror
echo "$OUT" | grep -qE "differ by 1(49|50|51) minutes \(openldap: OK [^;]+; keycloak: $(head -n 1 "$MIR/keycloak/STATUS")\), more than 2 hours .*restore-mirror-accept-age" \
  && ok "the skew refusal gives the minutes, both STATUS lines and names restore-mirror-accept-age" || bad "skew refusal text" "$OUT"
run -- restore-mirror-accept-age; rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -qF "[WARN] restore-mirror-accept-age: the openldap and keycloak STATUS times differ by" \
  && check_marker openldap && check_marker keycloak \
  && ok "restore-mirror-accept-age: copies 2.5 hours apart restored, with a warning; both markers" || bad "skew accept-age" "rc=$rc; $OUT"
setup
make_mirror "$MIR/keycloak" 3.5 "${KC_FILES[@]}"
run -- restore-mirror; rc=$?
[ "$rc" -eq 0 ] && ! echo "$OUT" | grep -q WARN && check_marker openldap && check_marker keycloak \
  && ok "copies 1.5 hours apart are restored without a warning" || bad "1.5 hours apart" "rc=$rc; $OUT"
setup
make_mirror "$MIR/keycloak" 5 "${KC_FILES[@]}"
valid_marker keycloak
make_mirror "$MIR/keycloak" 2 "${KC_FILES[@]}"
refused_ro "openldap 3 hours from keycloak's marker (its mirror fresh)" \
  "refused: the openldap and keycloak STATUS times differ by" -- restore-mirror
echo "$OUT" | grep -qF "keycloak: $(sed -n 's/^status //p' "$SW/mirror-restored-keycloak")" \
  && ok "the skew with a restored copy takes its marker's status line, not its mirror's" || bad "skew vs marker" "$OUT"
for iso in 2024-02-29T12:00:00Z 2000-03-01T00:00:00Z 1999-12-31T23:59:59Z 1970-01-01T00:00:00Z; do
  setup
  echo "OK $iso" > "$MIR/openldap/STATUS"
  run -- restore-mirror; rc=$?
  want="$(hours_since "$iso")"
  got="$(echo "$OUT" | sed -nE 's/.*the openldap mirror is ([0-9]+) hours old.*/\1/p' | head -n 1)"
  [ "$rc" -eq 3 ] && [ -n "$got" ] && [ $((got - want)) -ge -1 ] && [ $((got - want)) -le 1 ] \
    && ok "STATUS $iso: $got hours old (python3: $want)" || bad "age of $iso" "rc=$rc; got=$got want=$want; $OUT"
done

# --- a bad manifest, or the mirror changing while staged: exit 3, no target written ---
staged_refused() {   # staged_refused DESC PATTERN [ENV=V...] -- SWITCH...
  local desc="$1" pat="$2" rc
  shift 2
  run "$@"; rc=$?
  [ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "$pat" && no_run && no_marker \
    && [ "$(ls -A "$ROOT/backup")" = "lost+found" ] && [ ! -e "$ROOT/openldap-backup" ] \
    && ok "refused (3, no run, no target written, no marker): $desc" || bad "refusal: $desc" "rc=$rc; $OUT; $(docker_lines)"
}
setup
echo "not a manifest line" >> "$MIR/openldap/manifest.sha256"
staged_refused "a manifest line not theOrg's form" "refused: $MIR/openldap/manifest.sha256 is not a theOrg manifest" -- restore-mirror
setup
(cd "$MIR/keycloak" && sha256sum keycloak.dump > manifest.sha256)
staged_refused "a manifest with no summary.txt (keycloak, after openldap staged)" "refused: $MIR/keycloak/manifest.sha256 names no summary.txt" -- restore-mirror
for what in status manifest; do
  setup
  staged_refused "the mirror's $what changed while staged" "refused: $MIR/openldap changed while it was copied" STUB_CHANGE=$what -- restore-mirror
done

# --- failed checks: exit 1, no STATUS, no restore, no marker ---
setup
run STUB_CP_CORRUPT=mirror-stage/openldap/data.ldif -- restore-mirror; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "do not match the mirror's manifest.sha256" && no_run && no_marker \
  && [ ! -e "$ROOT/mirror-stage/openldap/STATUS" ] \
  && ok "a staged file that does not match: exit 1, no stage STATUS, no run" || bad "stage corrupt" "rc=$rc; $OUT"
setup
run STUB_CP_CORRUPT=openldap-backup/data.ldif -- restore-mirror; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "mirror-unstage: the files in" && [ ! -e "$ROOT/openldap-backup/STATUS" ] \
  && ! grep -q OLRESTORE "$T/log" && no_marker && ! docker_lines | grep -q keycloak-backup \
  && ok "a target file that does not match: exit 1, no STATUS in the target, no restore, no marker" || bad "target corrupt" "rc=$rc; $OUT"
setup
run STUB_UNSTAGE_RC=3 -- restore-mirror; rc=$?
[ "$rc" -eq 3 ] && ! grep -q OLRESTORE "$T/log" && no_marker && ok "the unstage refusing (3): exit 3, no restore, no marker" \
  || bad "unstage 3" "rc=$rc; $OUT"

# --- the restores' exits pass through; a re-run skips a valid marker ---
setup
run STUB_OL_RESTORE_RC=3 -- restore-mirror; rc=$?
[ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "openldap-backup restore exited 3" && no_marker && ! docker_lines | grep -q keycloak-backup \
  && ok "openldap-backup restore exit 3 passes through: no marker, keycloak not started" || bad "openldap restore 3" "rc=$rc; $OUT"
setup
run STUB_KC_RESTORE_RC=1 -- restore-mirror; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "keycloak-backup restore exited 1" && check_marker openldap \
  && [ ! -e "$SW/mirror-restored-keycloak" ] && ok "keycloak-backup restore exit 1 passes through: openldap's marker only" \
  || bad "keycloak restore 1" "rc=$rc; $OUT"
setup
run STUB_NO_DB=1 -- restore-mirror; rc=$?
[ "$rc" -eq 1 ] && check_marker openldap && [ ! -e "$SW/mirror-restored-keycloak" ] && [ "$(ls -A "$ROOT/backup")" = "lost+found" ] \
  && ! docker_lines | grep -q 'mirror-stage/keycloak:/stage' \
  && ok "keycloak-db's value not readable: exit 1, backup/ not written, openldap's marker only" || bad "no db value" "rc=$rc; $OUT"
run -- restore-mirror; rc=$?
[ "$rc" -eq 0 ] && [ "$(docker_lines)" = "$PS
$DB_HEALTH
$KC_CALLS" ] && echo "$OUT" | grep -qF "mirror-restored-openldap is valid; openldap is restored already, skipped" && check_marker keycloak \
  && ok "the re-run skips openldap (valid marker) and restores keycloak alone" || bad "re-run" "rc=$rc; $OUT; $(docker_lines)"
refused "the next run: both restored" "refused: both copies are restored from the mirror already" -- restore-mirror
setup
valid_marker keycloak
run STUB_HEALTH=starting -- restore-mirror; rc=$?
[ "$rc" -eq 0 ] && [ "$(docker_lines)" = "$PS
$OL_CALLS" ] && check_marker openldap \
  && ok "keycloak's marker valid: openldap alone restored, keycloak-db's health not needed" || bad "keycloak skipped" "rc=$rc; $OUT; $(docker_lines)"

# --- ARGs (exit 2) and combining (exit 3): no docker call, nothing changed ---
for args in "restore-mirror extra" "restore-mirror accept-age" "restore-mirror-accept-age extra"; do
  setup; before="$(snap)"
  # shellcheck disable=SC2086
  run -- $args; rc=$?
  [ "$rc" -eq 2 ] && echo "$OUT" | grep -qF "${args%% *}: usage: ${args%% *} (no ARG" && [ -z "$(docker_lines)" ] && [ "$(snap)" = "$before" ] \
    && ok "$args: exit 2, no docker call, nothing changed" || bad "ARG: $args" "rc=$rc; $OUT"
done
setup
refused "combined (verify restore-mirror)" "restore-mirror: refused: run it alone" -- verify restore-mirror
refused "combined (up restore-mirror-accept-age)" "restore-mirror-accept-age: refused: run it alone" -- up restore-mirror-accept-age

echo "checks ok: $oks"
[ "$fail" -eq 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
