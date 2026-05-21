#!/bin/bash
# Discover and back up every containerized app on this host. Cron-friendly.
#
# Discovery:
#   For each ~/scripts/<hostname>/apps/<app>/<app>.sh whose dispatcher has a
#   'backup)' case, run "<app>.sh backup" *serially* with low CPU and idle-class
#   IO priority. Serial + ionice prevents this from saturating the NAS, so it
#   is safe to schedule daily (or more often) alongside normal workload.
#
# Usage:
#   backup_all.sh                       # back up every discovered app
#   backup_all.sh plex calibre          # back up only the named apps
#   backup_all.sh --list                # print what would run; do nothing
#   backup_all.sh --help
#
# Cron (suggested 04:00 daily):
#   0 4 * * * /home/docker/scripts/docker/backup_all.sh >> /home/docker/logs/backup_all.cron.log 2>&1
#
# Concurrency: only one instance runs at a time (flock). Overlapping cron
# firings exit 0 without doing anything; the next slot will pick up.
#
# Knobs (env):
#   BACKUP_ALL_NICE         (default 19)  nice level for child app scripts
#   BACKUP_ALL_IONICE_CLASS (default 3 = idle)  ionice class (1=RT 2=BE 3=idle)
#   BACKUP_ALL_LOG_DIR      (default ~/logs)
#   BACKUP_ALL_LOG_KEEP     (default 30)  retain at most this many run logs
#   BACKUP_ALL_LOCK         (default /tmp/backup_all-<host>.lock)
#   SCRIPTS_DIR             (default ~/scripts)

set -euo pipefail

HOSTNAME_SHORT=$(hostname -s)
SCRIPTS_DIR="${SCRIPTS_DIR:-$HOME/scripts}"
APPS_DIR="$SCRIPTS_DIR/$HOSTNAME_SHORT/apps"
LOG_DIR="${BACKUP_ALL_LOG_DIR:-$HOME/logs}"
LOG_KEEP="${BACKUP_ALL_LOG_KEEP:-30}"
NICE_LEVEL="${BACKUP_ALL_NICE:-19}"
IONICE_CLASS="${BACKUP_ALL_IONICE_CLASS:-3}"
LOCK_FILE="${BACKUP_ALL_LOCK:-/tmp/backup_all-$HOSTNAME_SHORT.lock}"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit "${1:-1}"
}

LIST_ONLY=0
declare -a WANTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list|--dry-run) LIST_ONLY=1 ;;
    -h|--help)        usage 0 ;;
    --*)              echo "[ERROR] unknown option: $1" >&2; usage ;;
    *)                WANTED+=("$1") ;;
  esac
  shift
done

if [ ! -d "$APPS_DIR" ]; then
  echo "[ERROR] apps dir not found: $APPS_DIR" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

# --- single-instance lock -------------------------------------------------
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[INFO] another backup_all is already running (lock $LOCK_FILE); exiting." >&2
  exit 0
fi

# --- discovery -----------------------------------------------------------
# An app is backup-capable if:
#   1. ~/scripts/<host>/apps/<app>/<app>.sh exists and is executable,
#   2. its dispatcher contains a 'backup)' case statement.
declare -a DISCOVERED=()
for dir in "$APPS_DIR"/*/; do
  [ -d "$dir" ] || continue
  app=$(basename "$dir")
  script="$dir$app.sh"
  [ -x "$script" ] || continue
  if grep -qE '^[[:space:]]*backup\)' "$script" 2>/dev/null; then
    DISCOVERED+=("$app")
  fi
done

if [ ${#DISCOVERED[@]} -eq 0 ]; then
  echo "[INFO] no backup-capable apps found under $APPS_DIR"
  exit 0
fi

# --- filter to user-named subset, if any ---------------------------------
declare -a TARGETS=()
if [ ${#WANTED[@]} -gt 0 ]; then
  for w in "${WANTED[@]}"; do
    matched=0
    for d in "${DISCOVERED[@]}"; do
      [ "$w" = "$d" ] && { TARGETS+=("$w"); matched=1; break; }
    done
    [ "$matched" = "0" ] && echo "[WARN] requested app '$w' not found or has no backup; skipping" >&2
  done
else
  TARGETS=("${DISCOVERED[@]}")
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "[INFO] no targets after filtering"
  exit 0
fi

# --- list mode -----------------------------------------------------------
if [ "$LIST_ONLY" = "1" ]; then
  echo "host: $HOSTNAME_SHORT"
  echo "apps dir: $APPS_DIR"
  echo "discovered (backup-capable):"
  for app in "${DISCOVERED[@]}"; do echo "  - $app"; done
  echo "would run (after filter):"
  for app in "${TARGETS[@]}"; do
    echo "  nice -n $NICE_LEVEL ionice -c $IONICE_CLASS $APPS_DIR/$app/$app.sh backup"
  done
  exit 0
fi

# --- run -----------------------------------------------------------------
stamp=$(date +%Y%m%d-%H%M%S)
run_log="$LOG_DIR/backup_all-${stamp}.log"

{
  echo "===== backup_all $stamp on $HOSTNAME_SHORT ====="
  echo "targets: ${TARGETS[*]}"
  echo "nice=$NICE_LEVEL ionice=class$IONICE_CLASS  (serial; NAS-friendly)"
  echo "run log: $run_log"
  echo
} | tee -a "$run_log"

declare -A APP_RC APP_DUR
overall_rc=0

for app in "${TARGETS[@]}"; do
  script="$APPS_DIR/$app/$app.sh"
  echo "--- $app ---"
  echo "[INFO] $(date -Is) starting $app"

  {
    echo
    echo "##### $app — started $(date -Is) #####"
  } >> "$run_log"

  start=$(date +%s)
  rc=0
  # Run with low CPU + idle-class IO priority so this never starves anything
  # else on the host or the NAS. Stay synchronous so we can fold the exit code.
  nice -n "$NICE_LEVEL" ionice -c "$IONICE_CLASS" "$script" backup >> "$run_log" 2>&1 || rc=$?
  end=$(date +%s)
  duration=$((end - start))

  APP_RC[$app]=$rc
  APP_DUR[$app]=$duration

  echo "##### $app — finished $(date -Is) rc=$rc duration=${duration}s #####" >> "$run_log"

  if [ "$rc" -eq 0 ]; then
    echo "[INFO] $app OK  (${duration}s)"
  else
    echo "[ERROR] $app FAILED rc=$rc  (${duration}s)  — see $run_log" >&2
    overall_rc=$rc
  fi
done

# --- summary -------------------------------------------------------------
{
  echo
  echo "===== summary ====="
  total=0
  for app in "${TARGETS[@]}"; do
    printf "  %-20s rc=%-3d  %ds\n" "$app" "${APP_RC[$app]}" "${APP_DUR[$app]}"
    total=$(( total + APP_DUR[$app] ))
  done
  echo "  total: ${total}s"
  echo "===== run log: $run_log ====="
} | tee -a "$run_log"

# --- rotate run logs -----------------------------------------------------
# Keep at most $LOG_KEEP newest run logs; safe even when fewer exist.
if compgen -G "$LOG_DIR/backup_all-*.log" > /dev/null; then
  # shellcheck disable=SC2012
  ls -1t "$LOG_DIR"/backup_all-*.log 2>/dev/null | tail -n +$((LOG_KEEP + 1)) | xargs -r rm -f
fi

exit "$overall_rc"
