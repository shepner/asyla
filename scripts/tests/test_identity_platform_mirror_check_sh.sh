#!/bin/bash
# d05/apps/identity-platform/identity-platform.sh mirror-check, and cutover_gate's mirror path
# (asyla #1101), against stubs (docker, hostname, flock).
# mirror-check happy path: exactly the docker calls, in order (both restored summaries read, both
# dirs emptied only when they hold files, openldap-backup backup into openldap-count-check/,
# keycloak-db's value read from the running container and on keycloak-backup backup's stdin alone,
# into count-check/, each fresh summary read, each dir pruned); mirror-checked written; both dirs
# keep only summary.txt; backup/ and openldap-backup/ unchanged; the value in no output, argv,
# environment or file (also under SHELLOPTS=xtrace and bash -x); also on a replica. Keycloak lines
# other than the count lines are ignored. Refusals (exit 3, nothing changed, no docker run): the
# value's name in the environment, each symlinked path, the lock held, each M5 or later marker, each
# mirror-restored-* missing or invalid, keycloak-db not healthy. Exit 2 for an ARG. Exit 1: a
# restored summary that is not its marker's (no backup run), openldap's or keycloak's counts
# differing (lines printed, no marker, a stale mirror-checked removed), a dir that cannot be emptied
# or pruned. A backup failing: its exit, no marker, the dir pruned.
# The gate on the mirror path: start-openldap, start-keycloak, configure, check-reset-off,
# check-mail-off (realm mode) and cutover-done (which needs reset-off too) take both
# mirror-restored-* and mirror-checked (each missing or invalid one named); restore-openldap and
# count-check refused there; markers of both paths refused by every gated switch; cutover-done
# writes cutover-done with source mirror and both sha256s.
# Every value is a plain stand-in word made at run time.
# Run: bash scripts/tests/test_identity_platform_mirror_check_sh.sh
set -uo pipefail
unset IDP_KEYCLOAK_DB_PASSWORD IDP_LDAP_ADMIN_PASSWORD POSTGRES_PASSWORD PGPASSWORD KC_DB_PASSWORD \
  STUB_HEALTH STUB_NO_DB STUB_OL_BACKUP_RC STUB_KC_BACKUP_RC STUB_FIND_RC STUB_RESTORED

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
SW="$ROOT/cutover-state"
WORD="stand-in-db-word-$$"     # keycloak-db's stand-in value; only in $T/dbword and the checks
printf '%s' "$WORD" > "$T/dbword"
KCDB="$(sed -n 's/^KC_DB_IMAGE="\(.*\)"$/\1/p' "$SRC/identity-platform.sh")"
[ -n "$KCDB" ] || bad "KC_DB_IMAGE not found in the script"

# Every stub turns xtrace off first and logs its call with $T shortened to T; docker dumps its
# environment to $T/envdump (read only by the checks).
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
echo "docker $*" | sed -E "s#-f [^ ]*/compose.yml#-f compose.yml#; s# --project-directory [^ ]*##; s#$STUB_T#T#g" >> "$STUB_LOG"
env >> "$STUB_T/envdump"
d=""
case "$*" in
  *" ps -q keycloak-db") echo dbid ;;
  "inspect -f {{if .State.Health}}"*" dbid") echo "${STUB_HEALTH:-healthy}" ;;
  *"--profile restored ps -q openldap") [ -z "${STUB_RESTORED:-}" ] || echo olid ;;
  *"--profile restored ps -q keycloak") [ -z "${STUB_RESTORED:-}" ] || echo kcid ;;
  "inspect -f {{if .State.Health}}"*" olid"|"inspect -f {{if .State.Health}}"*" kcid") echo healthy ;;
  *" ps -q --status running keycloak-db") [ -n "${STUB_NO_DB:-}" ] || echo dbid ;;
  "inspect -f "*POSTGRES_PASSWORD*" dbid") printf '%s=%s\n' POSTGRES_PASSWORD "$(cat "$STUB_T/dbword")" ;;
  # The fresh backups into their -v dir: a dump, a manifest, a STATUS, .work and .lock (also before
  # a failure), then $STUB_T/olnew or kcnew there as summary.txt.
  *"--profile ops run --rm -T -v "*":/backup openldap-backup backup")
    echo "OLSTDIN $(wc -c | tr -d ' ')" >> "$STUB_LOG"
    for a in "$@"; do case "$a" in *:/backup) d="${a%:/backup}" ;; esac; done
    mkdir -p "$d/.work"; : > "$d/.lock"; echo stand-in-export > "$d/data.ldif"; echo stand-in-export > "$d/config.ldif"
    [ -z "${STUB_OL_BACKUP_RC:-}" ] || exit "$STUB_OL_BACKUP_RC"
    echo stand-in-manifest > "$d/manifest.sha256"; echo OK > "$d/STATUS"
    cat "$STUB_T/olnew" > "$d/summary.txt"
    exit 0 ;;
  *"--profile ops run --rm -T -v "*":/backup -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup backup")
    cat > "$STUB_T/kcstdin"
    for a in "$@"; do case "$a" in *:/backup) d="${a%:/backup}" ;; esac; done
    mkdir -p "$d/.work"; echo stand-in-dump > "$d/keycloak.dump"
    [ -z "${STUB_KC_BACKUP_RC:-}" ] || exit "$STUB_KC_BACKUP_RC"
    echo stand-in-manifest > "$d/manifest.sha256"; echo OK > "$d/STATUS"
    cat "$STUB_T/kcnew" > "$d/summary.txt"
    exit 0 ;;
  # find in keycloak-db's image (the emptying and the prune), here on the host dir.
  "run --rm --network none --pull never --user 0:0 --entrypoint find "*)
    [ -z "${STUB_FIND_RC:-}" ] || exit "$STUB_FIND_RC"
    for a in "$@"; do case "$a" in *:/t) d="${a%:/t}" ;; esac; done
    # less GNU rm's long flags (the host's rm may be BSD's; the logged argv keeps them)
    e=(); for a in "${@:15}"; do case "$a" in --one-file-system|--preserve-root=all) ;; *) e+=("$a") ;; esac; done
    find "$d" "${e[@]}"
    exit 0 ;;
  "run --rm --pull never --network none --user 0:0 --entrypoint cat "*)
    for a in "$@"; do case "$a" in *:/s:ro) d="${a%:/s:ro}" ;; esac; done
    exec cat "$d/summary.txt" ;;
esac
exit 0
EOF
cat > "$T/bin/hostname" <<'EOF'
#!/bin/bash
{ set +x; } 2>/dev/null
[ "$1" = -s ] && echo "$STUB_HOST"
EOF
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
exit 0
EOF
# mountpoint: the NAS is never mounted here (backup, past cutover-done, stops at its step 3).
printf '#!/bin/bash\nexit 1\n' > "$T/bin/mountpoint"
chmod +x "$T/bin/docker" "$T/bin/hostname" "$T/bin/flock" "$T/bin/mountpoint"
hash -r
for s in docker hostname flock mountpoint; do
  [ "$(PATH="$T/bin:$PATH" command -v "$s")" = "$T/bin/$s" ] || { echo "stub $s not runnable in $T/bin" >&2; exit 2; }
done

run() {   # run [ENV=V...] -- SWITCH...: output in $OUT, calls in $T/log, status returned; d05 unless STUB_HOST
  local pre=() rc
  while [ "$1" != -- ]; do pre+=("$1"); shift; done
  shift
  : > "$T/log"; : > "$T/envdump"; rm -f "$T/kcstdin"
  OUT="$(env ${pre[@]+"${pre[@]}"} HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_T="$T" \
    STUB_HOST="${STUB_HOST:-d05}" bash ${BASH_OPTS:-} "$T/app/identity-platform.sh" "$@" </dev/null 2>&1)"
  rc=$?
  return "$rc"
}
sha_of() { (sha256sum 2>/dev/null || shasum -a 256) < "$1" | awk '{print $1}'; }
# Paths (with $T shortened), modes, mtimes and sha256s under $T/dl; .lock aside.
snap() {
  python3 -I -c 'import hashlib, os, sys
t = sys.argv[1]
for d, ds, fs in os.walk(sys.argv[2]):
    ds.sort()
    for n in sorted(ds + fs):
        p = os.path.join(d, n)
        if n == ".lock":
            continue
        st = os.lstat(p)
        h = hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.isfile(p) and not os.path.islink(p) else ""
        print(p.replace(t, "T"), oct(st.st_mode), st.st_mtime_ns, h)' "$T" "$T/dl"
}

DIGEST="$(printf 'b%.0s' {1..64})"
OL_SUM="config 40
entries 12
suffix dc=example,dc=org
subtree ou=people 8
subtree ou=groups 3
entryuuid 12 $DIGEST
createtimestamp 12"
KC_SUM=$'realm master\nrealm theorg\nusers master 1\nusers theorg 12\nclients master 7\nclients theorg 9\ncredentials theorg otp 3\nchangesets 120'
# The fresh keycloak summary: the same count lines in another order, plus a line count_lines ignores.
KC_NEW=$'realm theorg\nrealm master\nclients theorg 9\nclients master 7\nusers theorg 12\nusers master 1\ncredentials theorg otp 3\nchangesets 120\ntaken 2026-11-21T00:00:00Z'
marker() {   # marker NAME: a valid mirror-restored-NAME naming the restored summary's sha256
  local d
  if [ "$1" = openldap ]; then d="$ROOT/openldap-backup"; else d="$ROOT/backup"; fi
  printf 'date 2026-11-21T00:00:00Z\nsource mirror\nstatus OK 2026-11-20T03:45:00Z\nsummary-sha256 %s\n' "$(sha_of "$d/summary.txt")" > "$SW/mirror-restored-$1"
}
setup() {   # what restore-mirror leaves: both restored copies, both markers, keycloak-db up
  rm -rf "$T/dl"/*
  mkdir -p "$SW" "$ROOT/openldap-backup" "$ROOT/backup" "$ROOT/openldap-data" "$ROOT/openldap-config"
  : > "$SW/.lock"
  printf '%s\n' "$OL_SUM" > "$ROOT/openldap-backup/summary.txt"; echo stand-in-export > "$ROOT/openldap-backup/data.ldif"
  printf '%s\n' "$KC_SUM" > "$ROOT/backup/summary.txt"; echo stand-in-dump > "$ROOT/backup/keycloak.dump"
  printf '%s\n' "$OL_SUM" > "$T/olnew"
  printf '%s\n' "$KC_NEW" > "$T/kcnew"
  marker openldap; marker keycloak
}
checked() {   # a valid mirror-checked for the current markers
  printf 'date 2026-11-21T01:00:00Z\nsource mirror\nopenldap-summary-sha256 %s\nkeycloak-summary-sha256 %s\nsummaries equal\n' \
    "$(sha_of "$ROOT/openldap-backup/summary.txt")" "$(sha_of "$ROOT/backup/summary.txt")" > "$SW/mirror-checked"
}
docker_lines() { grep '^docker ' "$T/log"; }
no_run() { ! docker_lines | grep -q ' run '; }
no_word() {
  ! printf '%s' "$OUT" | grep -qF "$WORD" && ! grep -qF "$WORD" "$T/log" "$T/envdump" && ! grep -rqF "$WORD" "$T/dl"
}
only_summary() { [ "$(ls -A "$1" | tr '\n' ' ')" = "summary.txt " ]; }
only_summary_or_empty() { [ -z "$(ls -A "$1" | grep -vx summary.txt)" ]; }

# --- usage ---
run --; echo "$OUT" | grep -q '^  mirror-check ' && ok "usage lists mirror-check" || bad "usage" "$OUT"

# --- the happy path: exact calls ---
C="docker compose -f compose.yml"
CAT="docker run --rm --pull never --network none --user 0:0 --entrypoint cat"
FIND="docker run --rm --network none --pull never --user 0:0 --entrypoint find"
P="T/dl/IdentityPlatform"
WANT="$C ps -q keycloak-db
docker inspect -f {{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}} dbid
$CAT -v $P/openldap-backup:/s:ro $KCDB /s/summary.txt
$CAT -v $P/backup:/s:ro $KCDB /s/summary.txt
$C --profile ops run --rm -T -v $P/openldap-count-check:/backup openldap-backup backup
$CAT -v $P/openldap-count-check:/s:ro $KCDB /s/summary.txt
$FIND -v $P/openldap-count-check:/t $KCDB /t -xdev -mindepth 1 -maxdepth 1 ! -name lost+found ! -name summary.txt -exec rm -rf --one-file-system --preserve-root=all {} +
$C ps -q --status running keycloak-db
docker inspect -f {{range .Config.Env}}{{if eq (index (split . \"=\") 0) \"POSTGRES_PASSWORD\"}}{{.}}{{end}}{{end}} dbid
$C --profile ops run --rm -T -v $P/count-check:/backup -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup backup
$CAT -v $P/count-check:/s:ro $KCDB /s/summary.txt
$FIND -v $P/count-check:/t $KCDB /t -xdev -mindepth 1 -maxdepth 1 ! -name lost+found ! -name summary.txt -exec rm -rf --one-file-system --preserve-root=all {} +"
happy() {   # happy LABEL [ENV=V...]: one run on a fresh setup, every check
  local label="$1" before after
  shift
  setup
  before="$(snap_of_restored)"
  run "$@" -- mirror-check; rc=$?
  after="$(snap_of_restored)"
  [ "$rc" -eq 0 ] || { bad "$label: exit" "rc=$rc; $OUT"; return; }
  [ "$(docker_lines)" = "$WANT" ] && ok "$label: exactly the docker calls, in order" \
    || bad "$label: calls" "$(diff <(echo "$WANT") <(docker_lines))"
  grep -qx 'OLSTDIN 0' "$T/log" && [ "$(cat "$T/kcstdin")" = "$WORD" ] \
    && ok "$label: openldap-backup backup gets no stdin; keycloak-backup backup's stdin is keycloak-db's value alone" \
    || bad "$label: stdin" "$(grep OLSTDIN "$T/log")"
  no_word && ok "$label: the value in no output, argv, environment or file" || bad "$label: value leaked"
  only_summary "$ROOT/count-check" && only_summary "$ROOT/openldap-count-check" \
    && ok "$label: count-check/ and openldap-count-check/ keep only summary.txt" \
    || bad "$label: dirs" "$(ls -A "$ROOT/count-check" "$ROOT/openldap-count-check")"
  [ "$before" = "$after" ] && ok "$label: backup/ and openldap-backup/ unchanged" || bad "$label: restored copies changed"
  grep -qx 'source mirror' "$SW/mirror-checked" && grep -qx 'summaries equal' "$SW/mirror-checked" \
    && grep -qx "openldap-summary-sha256 $(sha_of "$ROOT/openldap-backup/summary.txt")" "$SW/mirror-checked" \
    && grep -qx "keycloak-summary-sha256 $(sha_of "$ROOT/backup/summary.txt")" "$SW/mirror-checked" \
    && grep -qE '^date [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$SW/mirror-checked" \
    && ok "$label: mirror-checked (date, source mirror, both sha256s, summaries equal)" \
    || bad "$label: marker" "$(cat "$SW/mirror-checked" 2>&1)"
}
snap_of_restored() { find "$ROOT/backup" "$ROOT/openldap-backup" -type f -exec shasum {} + | sort; }
happy "mirror-check"
BASH_OPTS=-x happy "mirror-check under bash -x"
happy "mirror-check under SHELLOPTS=xtrace" SHELLOPTS=xtrace
STUB_HOST=test01 happy "mirror-check on a replica (test01)"

# A dir left by an earlier run is emptied first (find, only then), then the run goes on.
setup; mkdir -p "$ROOT/count-check" "$ROOT/openldap-count-check"; echo old > "$ROOT/count-check/keycloak.dump"
run -- mirror-check; rc=$?
[ "$rc" -eq 0 ] && docker_lines | grep -qxF "$FIND -v $P/count-check:/t $KCDB /t -xdev -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf --one-file-system --preserve-root=all {} +" \
  && ! docker_lines | grep -qF "$P/openldap-count-check:/t $KCDB /t -xdev -mindepth 1 -maxdepth 1 ! -name lost+found -exec" \
  && ! docker_lines | grep -F -- "--entrypoint find " | grep -vF -- " /t -xdev -mindepth 1 -maxdepth 1 " | grep -q . \
  && ! docker_lines | grep -F -- "--entrypoint find " | grep -vF -- " -exec rm -rf --one-file-system --preserve-root=all {} +" | grep -q . \
  && ok "a non-empty count-check/ emptied before the backups; an empty openldap-count-check/ not; every root find (clear and prune) has -xdev and rm -rf --one-file-system --preserve-root=all" || bad "emptying" "rc=$rc; $OUT"
setup; mkdir -p "$ROOT/openldap-count-check"; echo old > "$ROOT/openldap-count-check/data.ldif"
run STUB_FIND_RC=1 -- mirror-check; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "mirror-check: $ROOT/openldap-count-check still holds files (find exit 1); no backup run" \
  && ! docker_lines | grep -q ' backup$' && [ ! -e "$SW/mirror-checked" ] \
  && ok "an openldap-count-check/ that cannot be emptied: exit 1, no backup run, no marker" || bad "emptying fails" "rc=$rc; $OUT"

# --- refusals: exit 3, nothing changed, no docker run ---
refused() {   # refused LABEL PATTERN [ENV=V...] -- [SWITCH ARG...]; setup done by the caller
  local label="$1" pat="$2" before rc
  shift 2
  before="$(snap)"
  run "$@"; rc=$?
  [ "$rc" -eq 3 ] && echo "$OUT" | grep -qF -- "$pat" && no_run && [ "$(snap)" = "$before" ] \
    && ok "mirror-check refused: $label (3), no docker run, nothing changed" || bad "refusal: $label" "rc=$rc; $OUT; $(cat "$T/log")"
}
setup; refused "IDP_KEYCLOAK_DB_PASSWORD in the environment" "mirror-check: refused: IDP_KEYCLOAK_DB_PASSWORD is set" \
  IDP_KEYCLOAK_DB_PASSWORD="$WORD" -- mirror-check
for p in cutover-state backup openldap-backup count-check openldap-count-check openldap-data openldap-config; do
  setup; rm -rf "${ROOT:?}/$p"; mkdir -p "$T/elsewhere-$p"; ln -s "$T/elsewhere-$p" "$ROOT/$p"
  refused "$p a symlink" "refused: $ROOT/$p is a symlink" -- mirror-check
  rm -rf "$T/elsewhere-$p"
done
setup
exec 7> "$SW/.lock"
if "$T/bin/flock" -n 7; then refused "the cutover lock held" "mirror-check: refused: another cutover switch is running" -- mirror-check
else bad "the test could not take the cutover lock"; fi
exec 7>&-
for m in fetched unpack-started unpacked restored-openldap restored-keycloak started-openldap started-keycloak configured reset-off counted cutover-done; do
  setup; echo "date 2026-11-21T00:00:00Z" > "$SW/$m"
  refused "with $m (an M5 or later marker)" "mirror-check: refused: $SW/$m exists" -- mirror-check
done
for n in openldap keycloak; do
  setup; rm -f "$SW/mirror-restored-$n"
  refused "no mirror-restored-$n" "mirror-check: refused: $SW/mirror-restored-$n is missing or not a valid marker" -- mirror-check
  setup; grep -v '^source mirror$' "$SW/mirror-restored-$n" > "$T/m" && cat "$T/m" > "$SW/mirror-restored-$n"
  refused "an invalid mirror-restored-$n" "mirror-check: refused: $SW/mirror-restored-$n is missing or not a valid marker" -- mirror-check
done
setup; refused "keycloak-db unhealthy" "mirror-check: refused: keycloak-db is starting, not running and healthy" STUB_HEALTH=starting -- mirror-check
setup; run -- mirror-check extra; rc=$?
[ "$rc" -eq 2 ] && echo "$OUT" | grep -qF 'mirror-check: usage: mirror-check (no ARG)' && no_run \
  && ok "mirror-check with an ARG: exit 2, no docker run" || bad "ARG" "rc=$rc; $OUT"
setup; refused "combined (up mirror-check)" "mirror-check: refused: run it alone" -- up mirror-check

# --- failures: exit 1 or the backup's exit, no marker ---
for n in openldap keycloak; do
  setup; checked
  if [ "$n" = openldap ]; then echo extra >> "$ROOT/openldap-backup/summary.txt"; else echo extra >> "$ROOT/backup/summary.txt"; fi
  run -- mirror-check; rc=$?
  [ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "summary.txt is not the restored copy's" && ! docker_lines | grep -q ' backup$' \
    && [ ! -e "$SW/mirror-checked" ] && ok "the restored $n summary.txt not its marker's: exit 1, no backup run, the stale mirror-checked removed" \
    || bad "restored $n summary changed" "rc=$rc; $OUT"
done
setup; checked; printf '%s\n' "${OL_SUM/subtree ou=people 8/subtree ou=people 7}" > "$T/olnew"
run -- mirror-check; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "mirror-check: openldap's summaries differ; no mirror-checked marker" \
  && echo "$OUT" | grep -qx '    subtree ou=people 8' && echo "$OUT" | grep -qx '    subtree ou=people 7' \
  && [ ! -e "$SW/mirror-checked" ] && only_summary "$ROOT/openldap-count-check" && only_summary "$ROOT/count-check" \
  && ok "openldap's fresh summary differs: exit 1, both lines printed, no marker (the stale one removed), dirs pruned" \
  || bad "openldap mismatch" "rc=$rc; $OUT"
setup; printf '%s\n' "${OL_SUM/entryuuid 12 $DIGEST/entryuuid 12 $(printf 'c%.0s' {1..64})}" > "$T/olnew"
run -- mirror-check; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "openldap's summaries differ" && [ ! -e "$SW/mirror-checked" ] \
  && ok "openldap's entryUUID digest differs (same counts): exit 1, no marker" || bad "entryuuid mismatch" "rc=$rc; $OUT"
setup; printf '%s\n' "${KC_NEW/users theorg 12/users theorg 11}" > "$T/kcnew"
run -- mirror-check; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "mirror-check: keycloak's counts differ (realm, users, clients, credentials, changesets lines)" \
  && echo "$OUT" | grep -qx '    users theorg 12' && echo "$OUT" | grep -qx '    users theorg 11' \
  && [ ! -e "$SW/mirror-checked" ] && only_summary "$ROOT/count-check" \
  && ok "keycloak's counts differ: exit 1, both lines printed, no marker, count-check/ pruned" || bad "keycloak mismatch" "rc=$rc; $OUT"
setup; run STUB_OL_BACKUP_RC=1 -- mirror-check; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "openldap-backup backup exited 1; no keycloak backup run" \
  && ! docker_lines | grep -q 'keycloak-backup backup' && [ ! -e "$SW/mirror-checked" ] && only_summary_or_empty "$ROOT/openldap-count-check" \
  && ok "openldap-backup backup failing: its exit, no keycloak backup, no marker, no dump left" || bad "ol backup fails" "rc=$rc; $OUT"
setup; run STUB_KC_BACKUP_RC=3 -- mirror-check; rc=$?
[ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "keycloak-backup backup exited 3; no mirror-checked marker" \
  && [ ! -e "$SW/mirror-checked" ] && only_summary_or_empty "$ROOT/count-check" && no_word \
  && ok "keycloak-backup backup failing: its exit passes through, no marker, no dump left" || bad "kc backup fails" "rc=$rc; $OUT"
setup; run STUB_NO_DB=1 -- mirror-check; rc=$?
[ "$rc" -eq 1 ] && echo "$OUT" | grep -qF "keycloak-db is not running, so its password cannot be taken" \
  && ! docker_lines | grep -q 'keycloak-backup backup' && [ ! -e "$SW/mirror-checked" ] \
  && ok "keycloak-db gone before its password is taken: exit 1, no keycloak backup, no marker" || bad "no db" "rc=$rc; $OUT"

# --- the gate on the mirror path ---
gate() {   # gate SWITCH "MARKERS" MISSING|pass: markers written over a setup without mirror-checked
  local m pat
  setup
  for m in $2; do
    case "$m" in
      mirror-checked) checked ;;
      mirror-restored-*) : ;;   # setup wrote both
      started-openldap) printf 'date 2026-11-21T00:00:00Z\nadmin-bind ok\n' > "$SW/$m" ;;
      configured) printf 'date 2026-11-21T00:00:00Z\napply ok\nreconcile ok\n' > "$SW/$m" ;;
      reset-off) printf 'date 2026-11-21T00:00:00Z\n%s\n' "${GATE_RESETOFF-resetPasswordAllowed false}" > "$SW/$m" ;;
      *) printf 'date 2026-11-21T00:00:00Z\n' > "$SW/$m" ;;
    esac
  done
  for m in mirror-restored-openldap mirror-restored-keycloak; do
    case " $2 " in *" $m "*) ;; *) rm -f "$SW/$m" ;; esac
  done
  run -- "$1"; rc=$?
  if [ "$3" = pass ]; then pat="$1: refused: "; else pat="$1: refused: mirror-path marker missing or invalid: $3"; fi
  [ "$rc" -eq 3 ] && echo "$OUT" | grep -qF -- "$pat" && { [ "$3" != pass ] || ! echo "$OUT" | grep -q 'marker missing'; } \
    && ! grep -qE ' up | run |exec -i' "$T/log" \
    && ok "mirror gate $1 with [$2]: $([ "$3" = pass ] && echo 'passes, then refused later (3)' || echo "names $3 (3)")" \
    || bad "mirror gate $1 [$2]" "rc=$rc; $OUT"
}
MP="mirror-restored-openldap mirror-restored-keycloak mirror-checked"
gate start-openldap "mirror-restored-openldap mirror-restored-keycloak" "mirror-checked"
gate start-openldap "mirror-restored-keycloak mirror-checked" "mirror-restored-openldap"
gate start-openldap "mirror-restored-openldap mirror-checked" "mirror-restored-keycloak"
gate start-openldap "$MP" pass
gate start-keycloak "$MP" "started-openldap"
gate start-keycloak "$MP started-openldap" pass
gate configure "$MP started-openldap" "started-keycloak"
gate configure "$MP started-openldap started-keycloak" pass
gate check-reset-off "$MP started-openldap started-keycloak" "configured"
gate check-reset-off "mirror-restored-openldap mirror-restored-keycloak started-openldap started-keycloak configured" "mirror-checked"
gate check-reset-off "$MP started-openldap started-keycloak configured" pass
# check-mail-off in realm mode (configured present) takes check-reset-off's gate; with no configured
# it is without-realm mode and takes none (test_identity_platform_sh.sh).
gate check-mail-off "mirror-restored-openldap mirror-restored-keycloak started-openldap started-keycloak configured" "mirror-checked"
gate check-mail-off "$MP started-keycloak configured" "started-openldap"
gate check-mail-off "$MP started-openldap started-keycloak configured" pass
gate cutover-done "$MP started-openldap started-keycloak" "configured reset-off"
gate cutover-done "$MP started-openldap started-keycloak configured" "reset-off"
GATE_RESETOFF="resetPasswordAllowed true" gate cutover-done "$MP started-openldap started-keycloak configured reset-off" "reset-off (no resetPasswordAllowed false)"
gate cutover-done "mirror-restored-openldap mirror-restored-keycloak started-openldap started-keycloak configured reset-off" "mirror-checked"
gate cutover-done "$MP started-openldap started-keycloak configured reset-off" pass
# An invalid mirror-restored-* or a mirror-checked for other restores is named.
setup; checked; grep -v '^source mirror$' "$SW/mirror-restored-keycloak" > "$T/m" && cat "$T/m" > "$SW/mirror-restored-keycloak"
run -- start-openldap; rc=$?
[ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "start-openldap: refused: mirror-path marker missing or invalid: mirror-restored-keycloak (not a valid marker)" \
  && ok "mirror gate: an invalid mirror-restored-keycloak named (3)" || bad "invalid mirror-restored" "rc=$rc; $OUT"
setup; checked; marker_other() { printf 'date 2026-11-21T00:00:00Z\nsource mirror\nstatus OK 2026-11-20T03:45:00Z\nsummary-sha256 %s\n' "$DIGEST" > "$SW/mirror-restored-openldap"; }
marker_other; run -- start-openldap; rc=$?
[ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "mirror-checked (not summaries equal for these mirror-restored-* markers)" \
  && ok "mirror gate: a mirror-checked of other restores named (3)" || bad "stale mirror-checked" "rc=$rc; $OUT"
setup; checked; grep -v '^summaries equal$' "$SW/mirror-checked" > "$T/m" && cat "$T/m" > "$SW/mirror-checked"
run -- configure; rc=$?
[ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "configure: refused: mirror-path marker missing or invalid: mirror-checked (not summaries equal" \
  && ok "mirror gate: a mirror-checked without summaries equal named (3)" || bad "no summaries equal" "rc=$rc; $OUT"

# Mixed paths: refused by every gated switch.
for m5 in fetched unpacked restored-openldap counted; do
  mixed_ok=1
  for sw in start-openldap start-keycloak configure check-reset-off cutover-done restore-openldap count-check; do
    setup; checked; echo "date 2026-11-21T00:00:00Z" > "$SW/$m5"
    run -- "$sw"; rc=$?
    [ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "$sw: refused: cutover-state/ mixes the mirror path (mirror-restored-openldap mirror-restored-keycloak mirror-checked) and the M5 cutover path ($m5)" \
      && no_run || { bad "mixed $m5 $sw" "rc=$rc; $OUT"; mixed_ok=0; }
  done
  # The ok line only when all seven cases passed: a bad above has already set fail.
  [ "$mixed_ok" -eq 1 ] || continue
  ok "mixed paths ($m5 with the mirror markers): start-openldap, start-keycloak, configure, check-reset-off, cutover-done, restore-openldap and count-check refused (3), no docker run"
done
# M5-only switches on the mirror path.
for sw in restore-openldap count-check; do
  setup; checked; run -- "$sw"; rc=$?
  [ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "$sw: refused: $sw is an M5 cutover switch and cutover-state/ is on the mirror path" && no_run \
    && ok "$sw on the mirror path: refused (3), no docker run" || bad "$sw on the mirror path" "rc=$rc; $OUT"
done
# The M5 path's messages are unchanged with no mirror marker.
setup; rm -f "$SW"/mirror-restored-*; run -- start-openldap; rc=$?
[ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "start-openldap: refused: cutover marker missing or invalid: unpacked restored-openldap (" \
  && ok "no marker of either path: the M5 gate's refusal (3)" || bad "M5 gate" "rc=$rc; $OUT"

# cutover-done on the mirror path: written with source mirror and both sha256s; past it, backup is
# no longer refused for want of cutover-done, and the switches refuse.
setup; checked
printf 'date 2026-11-21T00:00:00Z\nadmin-bind ok\n' > "$SW/started-openldap"
printf 'date 2026-11-21T00:00:00Z\n' > "$SW/started-keycloak"
printf 'date 2026-11-21T00:00:00Z\napply ok\nreconcile ok\n' > "$SW/configured"
printf 'date 2026-11-21T00:00:00Z\nresetPasswordAllowed false\n' > "$SW/reset-off"
run STUB_RESTORED=1 -- cutover-done; rc=$?
[ "$rc" -eq 0 ] && grep -qx 'source mirror' "$SW/cutover-done" \
  && grep -qx "openldap-summary-sha256 $(sha_of "$ROOT/openldap-backup/summary.txt")" "$SW/cutover-done" \
  && grep -qx "keycloak-summary-sha256 $(sha_of "$ROOT/backup/summary.txt")" "$SW/cutover-done" \
  && ! grep -q '^manifests-sha256' "$SW/cutover-done" && grep -qE '^date ' "$SW/cutover-done" \
  && ok "cutover-done on the mirror path: written (date, source mirror, both summary sha256s)" || bad "cutover-done mirror" "rc=$rc; $OUT; $(cat "$SW/cutover-done" 2>&1)"
run -- backup; rc=$?
! echo "$OUT" | grep -qF "no $SW/cutover-done yet" && ok "past the mirror path's cutover-done, backup is not refused for want of it" || bad "backup after mirror cutover-done" "rc=$rc; $OUT"
run -- mirror-check; rc=$?
[ "$rc" -eq 3 ] && echo "$OUT" | grep -qF "mirror-check: refused: $SW/started-openldap exists" \
  && ok "mirror-check past the starts: refused (3)" || bad "mirror-check after starts" "rc=$rc; $OUT"

echo "checks ok: $oks"
if [ "$fail" -ne 0 ]; then echo "some checks FAILED"; exit 1; fi
echo "all passed"
