#!/bin/bash
# d03/apps/tc-datalogger/rotate-logs.sh: the in-place, size-bounded rotation of the pipelines'
# cron.log files, and the tc-log-rotate service that runs it (compose.yml). Local files only;
# nothing here reaches a host. With Docker, the same checks also run under busybox:1.37 (the
# service's image); without it that part is skipped.
# Run: bash scripts/tests/test_tc_log_rotate_sh.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$REPO/d03/apps/tc-datalogger"
SCRIPT="$APP/rotate-logs.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }
mtime() { python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1"; }
inode() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$1"; }
bytes() { wc -c < "$1" | tr -d ' '; }

# A log of numbered lines, about SIZE bytes, dated an hour ago.
mklog() {  # FILE SIZE
  awk -v n="$2" 'BEGIN { i = 0; s = 0; while (s < n) { l = sprintf("2026-10-27 12:00:00 run %08d ok", i++); print l; s += length(l) + 1 } }' > "$1"
  touch -t "$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null || date -d '1 hour ago' +%Y%m%d%H%M.%S)" "$1"
}

export TC_LOG_MAX_BYTES=20000 TC_LOG_KEEP_BYTES=2000

# Below the limit: untouched.
mkdir -p "$T/a"; mklog "$T/a/cron.log" 15000
cp "$T/a/cron.log" "$T/a/orig"; m0=$(mtime "$T/a/cron.log")
sh "$SCRIPT" --once "$T/a/cron.log" >"$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && cmp -s "$T/a/cron.log" "$T/a/orig" && [ "$(mtime "$T/a/cron.log")" = "$m0" ] && [ ! -e "$T/a/cron.log.1.gz" ] \
  && ok "below the limit: untouched, no copy" || bad "below the limit" "rc=$rc; $(cat "$T/out")"

# Above the limit: cut in place to whole lines from the end, the whole file in .1.gz, mtime kept.
mkdir -p "$T/b"; mklog "$T/b/cron.log" 60000
cp "$T/b/cron.log" "$T/b/orig"; m0=$(mtime "$T/b/cron.log"); i0=$(inode "$T/b/cron.log")
exec 7>>"$T/b/cron.log"   # the pipeline's `>>`, opened before the rotation and never reopened
sh "$SCRIPT" --once "$T/b/cron.log" >"$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'cut to' "$T/out" && ok "above the limit: rotated, exit 0" || bad "above the limit: exit" "rc=$rc; $(cat "$T/out")"
n=$(bytes "$T/b/cron.log")
[ "$n" -le 2000 ] && [ "$n" -gt 1900 ] && ok "cut to at most TC_LOG_KEEP_BYTES ($n)" || bad "cut size" "$n"
[ "$(tail -n 1 "$T/b/cron.log")" = "$(tail -n 1 "$T/b/orig")" ] && ok "the newest line is kept" || bad "the newest line is kept"
grep -vqE '^2026-10-27 12:00:00 run [0-9]{8} ok$' "$T/b/cron.log" && bad "whole lines only" "$(head -n 1 "$T/b/cron.log")" \
  || ok "whole lines only (the partial first line is dropped)"
tail -n "$(wc -l < "$T/b/cron.log")" "$T/b/orig" | cmp -s - "$T/b/cron.log" && ok "the kept part is the original's tail" || bad "kept part"
gzip -dc "$T/b/cron.log.1.gz" | cmp -s - "$T/b/orig" && ok "cron.log.1.gz holds the whole file" || bad "cron.log.1.gz"
[ "$(inode "$T/b/cron.log")" = "$i0" ] && ok "same inode (copytruncate, not a rename)" || bad "same inode"
[ "$(mtime "$T/b/cron.log")" = "$m0" ] && ok "mtime kept: a rotation is not a write for the healthcheck" || bad "mtime kept" "$m0 vs $(mtime "$T/b/cron.log")"
ls "$T/b" | grep -qE 'rotate-stamp|\.tail$|\.tmp$' && bad "no temporary file left" "$(ls "$T/b")" || ok "no temporary file left"
echo "2026-10-27 13:00:00 run after ok" >&7; exec 7>&-
[ "$(tail -n 1 "$T/b/cron.log")" = "2026-10-27 13:00:00 run after ok" ] && python3 -c 'import sys; sys.exit(b"\0" in open(sys.argv[1], "rb").read())' "$T/b/cron.log" \
  && [ "$(bytes "$T/b/cron.log")" -lt 2100 ] && ok "the open >> writer goes on at the new end (no hole)" || bad "the open writer" "$(bytes "$T/b/cron.log") bytes"

# A second rotation replaces the one previous copy.
mklog "$T/b/cron.log" 30000; cp "$T/b/cron.log" "$T/b/orig2"
sh "$SCRIPT" --once "$T/b/cron.log" >/dev/null 2>&1
gzip -dc "$T/b/cron.log.1.gz" | cmp -s - "$T/b/orig2" && [ "$(ls "$T/b" | grep -c 'gz$')" = 1 ] \
  && ok "a second rotation replaces cron.log.1.gz" || bad "second rotation"

# A missing file warns and does not fail the pass; the others are still rotated.
mkdir -p "$T/c"; mklog "$T/c/cron.log" 30000
sh "$SCRIPT" --once "$T/none/cron.log" "$T/c/cron.log" >"$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'no such file' "$T/out" && [ "$(bytes "$T/c/cron.log")" -le 2000 ] \
  && ok "a missing file: warned, the rest rotated" || bad "missing file" "rc=$rc; $(cat "$T/out")"

# A copy that cannot be written: the log is not cut, the pass fails.
mkdir -p "$T/d"; mklog "$T/d/cron.log" 30000; cp "$T/d/cron.log" "$T/d/orig"; mkdir "$T/d/cron.log.1.gz.tmp"
sh "$SCRIPT" --once "$T/d/cron.log" >"$T/out" 2>&1; rc=$?
[ "$rc" != 0 ] && cmp -s "$T/d/cron.log" "$T/d/orig" && grep -q 'not cut' "$T/out" \
  && ok "no copy, no cut: the pass fails and the log is whole" || bad "failed copy" "rc=$rc; $(cat "$T/out")"

# Usage and settings.
sh "$SCRIPT" --once >/dev/null 2>&1; [ $? = 64 ] && ok "no file: usage, 64" || bad "no file: usage"
TC_LOG_MAX_BYTES=20m sh "$SCRIPT" --once "$T/a/cron.log" >/dev/null 2>&1; [ $? = 64 ] && ok "a non-number setting: 64" || bad "non-number setting"
TC_LOG_KEEP_BYTES=20000 sh "$SCRIPT" --once "$T/a/cron.log" >/dev/null 2>&1; [ $? = 64 ] && ok "keep not below max: 64" || bad "keep >= max"

# The loop: a pass, then the pass file; TERM ends it at once (it is PID 1 in the service).
mkdir -p "$T/e"; mklog "$T/e/cron.log" 30000
TC_LOG_ROTATE_PASS="$T/e/pass" TC_LOG_ROTATE_INTERVAL=600 sh "$SCRIPT" "$T/e/cron.log" >/dev/null 2>&1 & pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$T/e/pass" ] && break; sleep 0.2; done
[ -e "$T/e/pass" ] && [ "$(bytes "$T/e/cron.log")" -le 2000 ] && ok "loop: rotated, then the pass file" || bad "loop pass"
kill -TERM "$pid"; for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
kill -0 "$pid" 2>/dev/null && { bad "loop: TERM ends it" "still running"; kill -9 "$pid"; } || ok "loop: TERM ends it within 2 s"

# compose.yml: tc-log-rotate mounts every pipeline's log directory, and rotates the cron.log of each.
C="$APP/compose.yml"
svc=$(awk '/^  tc-log-rotate:/{f=1; next} f && /^  [a-z]/{f=0} f' "$C")
for d in faction_crimes faction_members items user_events faction_chains; do
  grep -qF -- "/tc-datalogger/TC_$d/logs:/app/logs" "$C" || { bad "compose: pipeline $d mounts its logs"; continue; }
  printf '%s\n' "$svc" | grep -qF -- "/tc-datalogger/TC_$d/logs:/logs/$d" \
    && printf '%s\n' "$svc" | grep -qF -- "- /logs/$d/cron.log" && ok "compose: tc-log-rotate mounts and rotates $d" \
    || bad "compose: tc-log-rotate covers $d"
done
printf '%s\n' "$svc" | grep -qF './rotate-logs.sh:/rotate-logs.sh:ro' && printf '%s\n' "$svc" | grep -qF 'network_mode: none' \
  && ok "compose: the script read-only, no network" || bad "compose: script mount or network"
nsvc=$(grep -cE '^    container_name: ' "$C"); nlog=$(grep -cE '^    logging:' "$C")
[ "$nsvc" -ge 8 ] && [ "$nsvc" = "$nlog" ] && grep -qE '^  driver: local$' "$C" \
  && ok "compose: every service ($nsvc) logs through a rotating driver" || bad "compose: logging on every service" "$nsvc services, $nlog logging"
grep -q 'DOCKER_UID DOCKER_GID' "$APP/tc-datalogger.sh" && ok "tc-datalogger.sh exports DOCKER_UID/DOCKER_GID for compose" \
  || bad "tc-datalogger.sh exports DOCKER_UID/DOCKER_GID"

# The same rotation under the service's image.
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  mkdir -p "$T/f"; mklog "$T/f/cron.log" 60000; cp "$T/f/cron.log" "$T/f/orig"; m0=$(mtime "$T/f/cron.log")
  if docker run --rm --network none -u "$(id -u):$(id -g)" -e TC_LOG_MAX_BYTES -e TC_LOG_KEEP_BYTES \
       -v "$SCRIPT:/rotate-logs.sh:ro" -v "$T/f:/logs/x" busybox:1.37 sh /rotate-logs.sh --once /logs/x/cron.log >"$T/out" 2>&1 \
     && [ "$(bytes "$T/f/cron.log")" -le 2000 ] && [ "$(mtime "$T/f/cron.log")" = "$m0" ] \
     && gzip -dc "$T/f/cron.log.1.gz" | cmp -s - "$T/f/orig"; then ok "busybox:1.37: rotated, mtime kept, copy whole"
  else bad "busybox:1.37" "$(cat "$T/out")"; fi
  docker run --rm --network none -v "$T/e:/tmp/x" busybox:1.37 sh -c 'touch /tmp/rotate-pass; [ -n "$(find /tmp/rotate-pass -mmin -130 2>/dev/null)" ]' \
    && ok "busybox:1.37: the healthcheck's find -mmin works" || bad "busybox:1.37 healthcheck find"
else
  echo "skip busybox:1.37 (no Docker)"
fi

[ "$fail" = 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
