#!/bin/bash
# Offline test of `tc-datalogger.sh verify` (d03/apps/tc-datalogger/tc-datalogger.sh). The local
# dashboard check waits up to TC_VERIFY_WAIT_S (default 60 s) for :8081 to answer, so a verify run
# right after `up` passes. The weekly redeploy of 2026-11-05 (host-maintenance pipeline 3031558319)
# failed because its verify ran before the new tc-dashboard listened: d03's tc-dashboard started
# 11:15:40.46Z, the job logged "[ERROR] Local dashboard :8081 failed" at 11:15:42.54Z, and Flask
# logged "Running on" at 11:15:42.78Z.
# Touches no host. curl, docker, sleep and date are stubs on PATH. sleep moves a fake clock that the
# date stub reads, so the 60 s cases take no real time. Needs only bash (macOS's 3.2 is enough).
# Run from anywhere:
#
#   scripts/tests/test_tc_datalogger_verify.sh
#
# TC_SH=PATH tests another copy of the script, for example the one before the wait (9db07de^), to
# see the cases fail. Exit 0 when every case passes.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TC_SH="${TC_SH:-$REPO/d03/apps/tc-datalogger/tc-datalogger.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }

# A copy in a folder with no .env, and a HOME whose common.env points at the temp dir, so nothing
# reads d03's values or /mnt.
mkdir -p "$T/home/scripts/docker" "$T/bin" "$T/app" "$T/dl" "$T/d1"
cp "$REPO/docker/backup_lib.sh" "$T/home/scripts/docker/"
printf 'DOCKER_DL=%s\nDOCKER_D1=%s\n' "$T/dl" "$T/d1" > "$T/home/scripts/docker/common.env"
cp "$TC_SH" "$T/app/tc-datalogger.sh"

# curl: the local dashboard fails its first STUB_LOCAL_FAILS tries ("never": every try), then
# answers. STUB_LOCAL_HTTP_ERROR=1: it answers every try with an HTTP error, which only curl's -f
# turns into a failure (exit 22), as real curl does. The public URL exits STUB_PUBLIC_RC (0 by
# default). Each call is logged with the clock.
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
url="" fail_flag=""
for a in "$@"; do
  case "$a" in
    http*) url="$a" ;;
    --fail) fail_flag=1 ;;
    --*) ;;
    -*f*) fail_flag=1 ;;
  esac
done
echo "curl $url t=$(cat "$STUB_CLOCK")" >> "$STUB_LOG"
case "$url" in
  http://127.0.0.1:8081/*)
    n=$(( $(cat "$STUB_TRIES" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_TRIES"
    if [ -n "${STUB_LOCAL_HTTP_ERROR:-}" ]; then [ -n "$fail_flag" ] && exit 22; exit 0; fi
    [ "${STUB_LOCAL_FAILS:-0}" = never ] && exit 7
    [ "$n" -gt "${STUB_LOCAL_FAILS:-0}" ] || exit 7 ;;
  https://tc-datalogger.asyla.org/*) exit "${STUB_PUBLIC_RC:-0}" ;;
  *) echo "unexpected url: $url" >> "$STUB_LOG"; exit 99 ;;
esac
EOF
# docker: tc-doltgres reports STUB_DB (healthy by default); the two SQL reads answer a head and a count.
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
case "$*" in
  "inspect -f {{.State.Health.Status}} tc-doltgres") echo "${STUB_DB:-healthy}" ;;
  *"hashof('main')"*) echo "h0stub" ;;
  *"count(*) FROM dolt_log"*) echo "42" ;;
  *) echo "unexpected docker: $*" >> "$STUB_LOG"; exit 99 ;;
esac
EOF
# sleep moves the fake clock. Past 600 fake seconds it stops the script under test (its parent),
# so a wait with no bound fails the case (rc 143) instead of hanging the test.
cat > "$T/bin/sleep" <<'EOF'
#!/bin/bash
c=$(( $(cat "$STUB_CLOCK") + ${1%%.*} )); echo "$c" > "$STUB_CLOCK"
[ "$c" -le 600 ] || { echo "unexpected: fake clock past 600 s" >> "$STUB_LOG"; kill "$PPID"; }
EOF
cat > "$T/bin/date" <<'EOF'
#!/bin/bash
if [ "$*" = "+%s" ]; then cat "$STUB_CLOCK"; else exec /bin/date "$@"; fi
EOF
chmod +x "$T/bin/"*
# bash skips a file on PATH it cannot run (a noexec temp dir) and takes the next one: the real
# curl or docker would then reach d03's dashboard and tc-doltgres. Refuse to run then.
for s in curl docker sleep date; do
  [ "$(PATH="$T/bin:$PATH" command -v "$s")" = "$T/bin/$s" ] || { echo "stub $s not runnable in $T/bin" >&2; exit 2; }
done

run() {   # run [VAR=VALUE...]: verify with those set; output in $OUT, status in $RC, tries and clock read after
  echo 0 > "$T/clock"; : > "$T/log"; rm -f "$T/tries"
  # -u: a value exported in the caller's shell must not reach a case that does not set it.
  OUT="$(env -u TC_VERIFY_WAIT_S -u STUB_LOCAL_FAILS -u STUB_LOCAL_HTTP_ERROR -u STUB_PUBLIC_RC -u STUB_DB \
    "$@" HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_CLOCK="$T/clock" \
    STUB_TRIES="$T/tries" bash "$T/app/tc-datalogger.sh" verify 2>&1)"
  RC=$?
  TRIES="$(cat "$T/tries" 2>/dev/null || echo 0)"
  CLOCK="$(cat "$T/clock")"
}
has()  { grep -q -F -- "$1" <<<"$OUT"; }
public_tried() { grep -q -F "curl https://tc-datalogger.asyla.org/" "$T/log"; }
unexpected() { grep -q -E "^unexpected" "$T/log"; }

# 1. The dashboard answers at once: one try, no wait, then the public URL and the DB line.
c="answers at once"
run
if [ "$RC" -eq 0 ] && [ "$TRIES" -eq 1 ] && [ "$CLOCK" -eq 0 ] && has "[INFO] Local http://127.0.0.1:8081/login OK" \
  && has "[INFO] https://tc-datalogger.asyla.org/login OK" && has "[INFO] tc-doltgres: torn_data head h0stub, 42 commits" \
  && ! unexpected; then ok "$c"; else bad "$c" "rc=$RC tries=$TRIES clock=$CLOCK: $OUT"; fi

# 2. 2026-11-05: up has returned, Flask listens a few seconds later. Verify waits and passes.
c="dashboard answers 4 s after up (2026-11-05)"
run STUB_LOCAL_FAILS=2
if [ "$RC" -eq 0 ] && [ "$TRIES" -eq 3 ] && [ "$CLOCK" -eq 4 ] && has "[INFO] Local http://127.0.0.1:8081/login OK" \
  && public_tried; then ok "$c"; else bad "$c" "rc=$RC tries=$TRIES clock=$CLOCK: $OUT"; fi

# 3. The last try inside the default 60 s still counts.
c="dashboard answers at 58 s, inside the 60 s wait"
run STUB_LOCAL_FAILS=29
if [ "$RC" -eq 0 ] && [ "$TRIES" -eq 30 ] && [ "$CLOCK" -eq 58 ]; then ok "$c"; else bad "$c" "rc=$RC tries=$TRIES clock=$CLOCK: $OUT"; fi

# 4. A dashboard that never answers fails verify after 60 s, and says how long it waited.
#    The wait is bounded and the public URL is not tried.
c="dashboard never answers: fails after the 60 s wait"
run STUB_LOCAL_FAILS=never
if [ "$RC" -eq 1 ] && [ "$CLOCK" -ge 60 ] && [ "$CLOCK" -le 62 ] && has "[ERROR] Local dashboard :8081 failed (waited 60s)" \
  && ! public_tried; then ok "$c"; else bad "$c" "rc=$RC tries=$TRIES clock=$CLOCK: $OUT"; fi

# 5. TC_VERIFY_WAIT_S sets the wait.
c="TC_VERIFY_WAIT_S=10 waits 10 s"
run STUB_LOCAL_FAILS=never TC_VERIFY_WAIT_S=10
if [ "$RC" -eq 1 ] && [ "$CLOCK" -ge 10 ] && [ "$CLOCK" -le 12 ] && has "(waited 10s)"; then ok "$c"
else bad "$c" "rc=$RC tries=$TRIES clock=$CLOCK: $OUT"; fi

# 5b. An HTTP error from the dashboard is not up: verify keeps waiting, then fails.
c="dashboard answers with an HTTP error: not up"
run STUB_LOCAL_HTTP_ERROR=1 TC_VERIFY_WAIT_S=4
if [ "$RC" -eq 1 ] && [ "$TRIES" -eq 3 ] && has "(waited 4s)" && ! public_tried; then ok "$c"
else bad "$c" "rc=$RC tries=$TRIES clock=$CLOCK: $OUT"; fi

# 6. The local dashboard answers but the public URL does not: verify fails.
c="public URL fails"
run STUB_PUBLIC_RC=22
if [ "$RC" -eq 1 ] && has "[INFO] Local http://127.0.0.1:8081/login OK" && has "[ERROR] Public URL failed"; then ok "$c"
else bad "$c" "rc=$RC: $OUT"; fi

# 7. tc-doltgres not healthy: verify fails and names its state.
c="tc-doltgres not healthy"
run STUB_DB=starting
if [ "$RC" -eq 1 ] && has "[ERROR] tc-doltgres is not healthy (state: starting)"; then ok "$c"
else bad "$c" "rc=$RC clock=$CLOCK: $OUT"; fi

exit "$fail"
