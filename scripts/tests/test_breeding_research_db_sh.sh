#!/bin/bash
# d03/apps/breeding-research/breeding-research.sh dbmigrate, dbstatus and dbload against a docker
# stub: the exec command each runs in the app container, the refusal when the app is not running or
# its image lacks the script (nothing runs), stdin passed through to pg_load.py byte for byte (and
# left alone by dbmigrate in `dbmigrate dbload`), a failed migration stopping before the load, and a
# load mismatch's exit code. Then dbload_from_workstation.sh against an ssh stub: its argument
# refusals before any ssh, the one BatchMode ssh call and its remote command, the tar it sends
# (manifest.json and the *.jsonl at the top level, nothing else, no ._ AppleDouble member), a failed
# load's exit, and the whole path with the ssh stub running the real breeding-research.sh.
# Nothing here reaches a registry, the vault or a host.
# Run: bash scripts/tests/test_breeding_research_db_sh.sh
# BREEDING_RESEARCH_SH=PATH tests another copy of breeding-research.sh (a mutated one, to see cases fail).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_SRC="$REPO/d03/apps/breeding-research"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }
has() { grep -qF -- "$2" <<< "$1"; }

mkdir -p "$T/home/scripts/docker" "$T/bin" "$T/app/lib" "$T/dl" "$T/d1"
cp "$REPO/docker/backup_lib.sh" "$T/home/scripts/docker/"
printf 'DOCKER_DL=%s\nDOCKER_D1=%s\n' "$T/dl" "$T/d1" > "$T/home/scripts/docker/common.env"
cp "$APP_SRC/compose.yml" "$APP_SRC/dbload_from_workstation.sh" "$T/app/"
cp "$APP_SRC/lib/docker-native-build.sh" "$T/app/lib/"
cp "${BREEDING_RESEARCH_SH:-$APP_SRC/breeding-research.sh}" "$T/app/breeding-research.sh"

# docker: logs each call (compose path shortened). The app container is running when
# STUB_APP_RUNNING; `test -f /app/scripts/...` fails when STUB_NO_SCRIPTS; db_migrate.py exits
# STUB_MIGRATE_RC; pg_load.py --tar - keeps its stdin in $STUB_RECEIVED and exits STUB_LOAD_RC.
# test -f and db_migrate.py drain their stdin, as compose exec would forward it: a call that does
# not close it would eat dbload's tar in `dbmigrate dbload`.
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" | sed -E "s#-f [^ ]*/compose.yml#-f compose.yml#; s# --project-directory [^ ]*##" >> "$STUB_LOG"
case "$*" in
  *"ps -q --status running breeding-research") if [ -n "${STUB_APP_RUNNING:-}" ]; then echo app1; fi ;;
  *"ps -q --status running"*) ;;
  *"exec -T breeding-research test -f /app/scripts/"*) cat >/dev/null; [ -z "${STUB_NO_SCRIPTS:-}" ] ;;
  *"python scripts/db_migrate.py"*) cat >/dev/null; exit "${STUB_MIGRATE_RC:-0}" ;;
  *"python scripts/pg_load.py --tar -") cat > "$STUB_RECEIVED"; exit "${STUB_LOAD_RC:-0}" ;;
esac
EOF
# ssh (dbload_from_workstation.sh only): logs its arguments and keeps its stdin in $STUB_RECEIVED,
# exits STUB_SSH_RC; with STUB_SSH_REAL it runs the real breeding-research.sh instead (as d03 would).
cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
echo "ssh $*" >> "$STUB_LOG"
if [ -n "${STUB_SSH_REAL:-}" ]; then exec bash "$STUB_APP_SH" dbmigrate dbload; fi
cat > "$STUB_RECEIVED"
exit "${STUB_SSH_RC:-0}"
EOF
chmod +x "$T/bin/docker" "$T/bin/ssh"

# Runs `breeding-research.sh ARGS...` in a clean environment plus the NAME=value words before --,
# stdin from $STDIN_FILE (default /dev/null); sets OUT and LOG, returns its exit code.
run_br() {
  local envs=() rc
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$T/log"; rm -f "$T/received"
  OUT="$(env -i PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T/home" STUB_LOG="$T/log" \
    STUB_RECEIVED="$T/received" ${envs[@]+"${envs[@]}"} bash "$T/app/breeding-research.sh" "$@" \
    <"${STDIN_FILE:-/dev/null}" 2>&1)"
  rc=$?
  LOG="$(cat "$T/log")"
  return "$rc"
}

# A stand-in export tar: binary bytes too, so a pass-through that changes anything shows.
mkdir -p "$T/src"
printf '{"table":"x"}\n' > "$T/src/manifest.json"
head -c 4096 /dev/urandom > "$T/src/x.jsonl"
tar -C "$T/src" -cf "$T/export.tar" manifest.json x.jsonl

PFX="docker compose -f compose.yml"

# 1. dbmigrate: checks the app runs and ships the script, then runs it in /app with stdin closed.
if run_br STUB_APP_RUNNING=1 -- dbmigrate; then
  if has "$LOG" "$PFX exec -T breeding-research test -f /app/scripts/db_migrate.py" \
      && has "$LOG" "$PFX exec -T -w /app breeding-research python scripts/db_migrate.py" \
      && ! has "$LOG" "db_migrate.py --status" && ! has "$LOG" "pg_load"; then
    ok "dbmigrate runs python scripts/db_migrate.py in the app container (/app)"
  else bad "dbmigrate runs python scripts/db_migrate.py in the app container" "$LOG"; fi
else bad "dbmigrate succeeds" "$OUT"; fi

# 2. dbstatus: --status only.
if run_br STUB_APP_RUNNING=1 -- dbstatus && has "$LOG" "$PFX exec -T -w /app breeding-research python scripts/db_migrate.py --status"; then
  ok "dbstatus runs db_migrate.py --status"
else bad "dbstatus runs db_migrate.py --status" "$LOG"; fi

# 3. An image without the scripts: dbmigrate, dbstatus and dbload refused, nothing run, the fix named.
refused=0
for c in dbmigrate dbstatus dbload; do
  STDIN_FILE="$T/export.tar" run_br STUB_APP_RUNNING=1 STUB_NO_SCRIPTS=1 -- "$c" && refused=1
  has "$OUT" "update the app image first" || refused=1
  has "$LOG" "python scripts/" && refused=1
  [ -e "$T/received" ] && refused=1
done
if [ "$refused" = 0 ]; then ok "an image without the scripts: dbmigrate, dbstatus, dbload refused, nothing run, 'update the app image first'"
else bad "an image without the scripts is refused" "$OUT
$LOG"; fi

# 4. The app not running: refused before any exec.
if run_br -- dbmigrate; then bad "dbmigrate with the app stopped is refused"
elif has "$OUT" "not running" && ! has "$LOG" " exec "; then ok "dbmigrate with the app stopped is refused before any exec"
else bad "dbmigrate with the app stopped is refused before any exec" "$OUT
$LOG"; fi

# 5. dbload: stdin reaches pg_load.py --tar - unchanged.
if STDIN_FILE="$T/export.tar" run_br STUB_APP_RUNNING=1 -- dbload \
    && has "$LOG" "$PFX exec -T breeding-research test -f /app/scripts/pg_load.py" \
    && has "$LOG" "$PFX exec -T -w /app breeding-research python scripts/pg_load.py --tar -" \
    && cmp -s "$T/export.tar" "$T/received"; then
  ok "dbload passes stdin to python scripts/pg_load.py --tar - byte for byte"
else bad "dbload passes stdin to pg_load.py --tar - byte for byte" "$OUT
$LOG"; fi

# 6. `dbmigrate dbload` (what the workstation script runs): migrations first, the tar left for dbload.
if STDIN_FILE="$T/export.tar" run_br STUB_APP_RUNNING=1 -- dbmigrate dbload \
    && [ "$(grep -n 'db_migrate.py' <<< "$LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'pg_load.py --tar' <<< "$LOG" | cut -d: -f1)" ] \
    && cmp -s "$T/export.tar" "$T/received"; then
  ok "dbmigrate dbload: migrations first, and dbmigrate leaves stdin for dbload"
else bad "dbmigrate dbload: migrations first, stdin left for dbload" "$LOG"; fi

# 7. A failed migration stops before the load; a load mismatch is the script's exit code.
if STDIN_FILE="$T/export.tar" run_br STUB_APP_RUNNING=1 STUB_MIGRATE_RC=1 -- dbmigrate dbload; then
  bad "a failed dbmigrate stops dbmigrate dbload"
elif ! has "$LOG" "pg_load.py --tar"; then ok "a failed dbmigrate stops before dbload"
else bad "a failed dbmigrate stops before dbload" "$LOG"; fi
STDIN_FILE="$T/export.tar" run_br STUB_APP_RUNNING=1 STUB_LOAD_RC=3 -- dbload; rc=$?
if [ "$rc" = 3 ]; then ok "a pg_load.py mismatch (exit 3) is dbload's exit"; else bad "a pg_load.py mismatch is dbload's exit" "rc=$rc"; fi

# 8. The usage names the new switches; an unknown one still exits 2.
run_br -- nosuch; rc=$?
if [ "$rc" = 2 ] && has "$OUT" "dbmigrate|dbstatus|dbload" && has "$OUT" "dbload < EXPORT.tar"; then
  ok "usage names dbmigrate, dbstatus and dbload"
else bad "usage names dbmigrate, dbstatus and dbload" "rc=$rc $OUT"; fi

# dbload_from_workstation.sh: same clean environment, the ssh stub.
HELPER="$T/app/dbload_from_workstation.sh"
run_ws() {
  local envs=() rc
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$T/log"; rm -f "$T/received"
  OUT="$(env -i PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T/home" STUB_LOG="$T/log" \
    STUB_RECEIVED="$T/received" STUB_APP_SH="$T/app/breeding-research.sh" ${envs[@]+"${envs[@]}"} \
    bash "$HELPER" "$@" </dev/null 2>&1)"
  rc=$?
  LOG="$(cat "$T/log")"
  return "$rc"
}

# An export dir with strays the tar must leave out (.DS_Store, a .txt, a subdirectory) and, on
# macOS, an xattr that plain bsdtar would turn into a ._ member.
E="$T/export"
mkdir -p "$E/sub"
printf '{"tables":[]}\n' > "$E/manifest.json"
printf '{"a":1}\n' > "$E/akc_dogs.jsonl"
head -c 2048 /dev/urandom > "$E/pedigree_nodes.jsonl"
printf 'x' > "$E/.DS_Store"; printf 'x' > "$E/notes.txt"; printf 'x' > "$E/sub/y.jsonl"
if command -v xattr >/dev/null 2>&1; then xattr -w com.example.test 1 "$E/akc_dogs.jsonl" 2>/dev/null || true; fi

# 9. Refusals, each before any ssh: no argument, two, a missing dir, no manifest.json, a symlinked
# manifest, no .jsonl, a symlinked .jsonl, a D03_SSH that is not [user@]host.
mkdir -p "$T/nomani" "$T/nojsonl" "$T/linkj" "$T/linkm"
printf '{}' > "$T/nojsonl/manifest.json"; printf '{}' > "$T/linkj/manifest.json"
ln -s "$E/akc_dogs.jsonl" "$T/linkj/a.jsonl"
ln -s "$E/manifest.json" "$T/linkm/manifest.json"; cp "$E/akc_dogs.jsonl" "$T/linkm/"
refused=0
run_ws -- && refused=1; has "$LOG" "ssh" && refused=1
run_ws -- "$E" "$E" && refused=1; has "$LOG" "ssh" && refused=1
for d in "$T/none" "$T/nomani" "$T/linkm" "$T/nojsonl" "$T/linkj"; do
  run_ws -- "$d" && refused=1; has "$LOG" "ssh" && refused=1
done
for h in "docker@d03;id" "-oProxyCommand=x" "a b"; do
  run_ws D03_SSH="$h" -- "$E" && refused=1; has "$LOG" "ssh" && refused=1
done
if [ "$refused" = 0 ]; then ok "dbload_from_workstation.sh refuses bad arguments, a non-export dir, symlinks and a bad D03_SSH before any ssh"
else bad "dbload_from_workstation.sh refuses bad input before any ssh" "$OUT
$LOG"; fi

# 10. A good export: one BatchMode ssh to docker@d03 running dbmigrate dbload, fed a tar of exactly
# manifest.json and the top-level .jsonl files, unchanged.
if run_ws -- "$E"; then
  members="$(tar -tf "$T/received" | LC_ALL=C sort | tr '\n' ' ')"
  mkdir -p "$T/x"; tar -C "$T/x" -xf "$T/received"
  if [ "$LOG" = "ssh -o BatchMode=yes docker@d03 ~/scripts/d03/apps/breeding-research/breeding-research.sh dbmigrate dbload" ] \
      && [ "$members" = "akc_dogs.jsonl manifest.json pedigree_nodes.jsonl " ] \
      && cmp -s "$E/pedigree_nodes.jsonl" "$T/x/pedigree_nodes.jsonl" && cmp -s "$E/manifest.json" "$T/x/manifest.json"; then
    ok "dbload_from_workstation.sh sends manifest.json and the .jsonl (no strays, no ._) to one BatchMode ssh: dbmigrate dbload"
  else bad "dbload_from_workstation.sh's ssh call and tar" "$LOG | $members"; fi
else bad "dbload_from_workstation.sh with a good export succeeds" "$OUT"; fi

# 11. A failed or mismatched load on d03 is a failure here.
if run_ws STUB_SSH_RC=1 -- "$E"; then bad "dbload_from_workstation.sh fails when the d03 side fails"
elif has "$OUT" "[ERROR] the load failed"; then ok "dbload_from_workstation.sh exits 1 when the d03 side fails"
else bad "dbload_from_workstation.sh exits 1 when the d03 side fails" "$OUT"; fi

# 12. The whole path: the ssh stub runs the real breeding-research.sh against the docker stub.
if run_ws STUB_SSH_REAL=1 STUB_APP_RUNNING=1 -- "$E" \
    && has "$LOG" "python scripts/db_migrate.py" && has "$LOG" "python scripts/pg_load.py --tar -" \
    && [ "$(tar -tf "$T/received" | LC_ALL=C sort | tr '\n' ' ')" = "akc_dogs.jsonl manifest.json pedigree_nodes.jsonl " ]; then
  ok "workstation -> breeding-research.sh dbmigrate dbload -> pg_load.py gets the export tar"
else bad "workstation -> breeding-research.sh -> pg_load.py end to end" "$OUT
$LOG"; fi
if run_ws STUB_SSH_REAL=1 STUB_APP_RUNNING=1 STUB_NO_SCRIPTS=1 -- "$E"; then bad "end to end with an old image fails"
elif has "$OUT" "update the app image first" && ! has "$LOG" "python scripts/"; then
  ok "end to end with an old image: refused on d03, nothing run"
else bad "end to end with an old image: refused, nothing run" "$OUT
$LOG"; fi

exit "$fail"
