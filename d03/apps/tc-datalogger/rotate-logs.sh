#!/bin/sh
# Size-bounded rotation of the pipelines' in-app cron.log files (asyla backlog
# 2026-10-20-asyla-hosts-tc-datalogger-log-rotation-and-heartbeat). Runs in the tc-log-rotate
# service (compose.yml, busybox) until the app logs to stdout. Usage: rotate-logs.sh [--once] FILE...
#
# Each pipeline appends to its cron.log with `>>` (O_APPEND) from a process that never reopens it,
# so a rename would leave it writing to the old file: the file is rotated in place, as logrotate's
# copytruncate does. Above TC_LOG_MAX_BYTES a file is copied whole to FILE.1.gz (one previous copy,
# replaced each time), then cut down, same inode, to its last TC_LOG_KEEP_BYTES (whole lines), so
# the dashboard still finds the recent runs it parses. Its mtime is put back afterwards: the
# pipelines' healthchecks read it as "written recently", and a rotation must not count as a write.
# Lines the pipeline appends while a file is being cut (well under a second) can be lost, as with
# copytruncate. Without --once it repeats every TC_LOG_ROTATE_INTERVAL seconds and touches
# $TC_LOG_ROTATE_PASS after each pass (the service's healthcheck).

MAX_BYTES="${TC_LOG_MAX_BYTES:-20971520}"      # 20 MiB
KEEP_BYTES="${TC_LOG_KEEP_BYTES:-1048576}"     # 1 MiB stays in place
INTERVAL="${TC_LOG_ROTATE_INTERVAL:-3600}"
PASS_FILE="${TC_LOG_ROTATE_PASS:-/tmp/rotate-pass}"

rotate_one() {
  f="$1"
  [ -f "$f" ] || { echo "[WARN] $f: no such file" >&2; return 0; }
  size=$(wc -c < "$f" | tr -d ' ')
  [ "$size" -gt "$MAX_BYTES" ] || return 0
  stamp="$f.rotate-stamp"
  touch -r "$f" "$stamp" || return 1
  if ! gzip -c "$f" > "$f.1.gz.tmp" || ! mv -f "$f.1.gz.tmp" "$f.1.gz"; then
    echo "[ERROR] $f: could not write $f.1.gz; not cut" >&2
    rm -f "$f.1.gz.tmp" "$stamp"
    return 1
  fi
  # tail -c starts mid-line: drop that first partial line.
  if ! tail -c "$KEEP_BYTES" "$f" | sed '1d' > "$f.tail"; then
    echo "[ERROR] $f: could not read its tail; not cut" >&2
    rm -f "$f.tail" "$stamp"
    return 1
  fi
  cat "$f.tail" > "$f"
  touch -r "$stamp" "$f"
  rm -f "$f.tail" "$stamp"
  echo "[INFO] $f: $size bytes, cut to $(wc -c < "$f" | tr -d ' '); the whole file is in $f.1.gz"
}

pass() {
  rc=0
  for f in "$@"; do rotate_one "$f" || rc=1; done
  return "$rc"
}

once=0
[ "${1:-}" = "--once" ] && { once=1; shift; }
[ $# -gt 0 ] || { echo "Usage: $0 [--once] FILE..." >&2; exit 64; }
case "$MAX_BYTES$KEEP_BYTES$INTERVAL" in
  *[!0-9]*) echo "[ERROR] TC_LOG_MAX_BYTES, TC_LOG_KEEP_BYTES and TC_LOG_ROTATE_INTERVAL must be whole numbers" >&2; exit 64 ;;
esac
[ "$KEEP_BYTES" -lt "$MAX_BYTES" ] || { echo "[ERROR] TC_LOG_KEEP_BYTES must be below TC_LOG_MAX_BYTES" >&2; exit 64; }

if [ "$once" = 1 ]; then
  pass "$@"
  exit $?
fi

trap 'exit 0' TERM INT
while :; do
  pass "$@" && touch "$PASS_FILE"
  sleep "$INTERVAL" &
  wait $!
done
