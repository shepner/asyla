# Shared backup helpers. Source from any app's <app>.sh:
#   . "$HOME/scripts/docker/backup_lib.sh"
#
# Three styles. All take a per-destination lock, so a manual `<app>.sh backup`
# and the cron-driven backup_all.sh can never write the same destination at
# the same time (a second run fails fast with an error instead).
#
# 1. Mirror (preferred for anything with many files)
#
#   do_rsync_mirror_backup <src_dir> <dest_dir> [-- <extra rsync args>...]
#
#   Keeps ONE rsync mirror of src_dir at dest_dir. History comes from the NAS,
#   not from extra copies: on nas01, data1/docker is ZFS-snapshotted daily at
#   00:00, kept 2 weeks, and replicated to the backup pool. A daily run only
#   touches files that changed. dest_dir/.backup-status says "OK <time>" after a
#   successful run and "IN PROGRESS ..." while one is running (or if it died), so
#   a ZFS snapshot taken mid-run is recognizable.
#
# 2. Hardlink snapshots (legacy; no app uses it since 2026-09-29)
#
#   do_rsync_snapshot_backup <src_dir> <dest_root> <keep> [-- <extra rsync args>...]
#
#   src_dir   — directory to back up (e.g. /mnt/docker/calibre)
#   dest_root — root holding snapshots (e.g. /mnt/nas/data1/docker/calibre)
#   keep      — number of snapshot dirs to retain (recommend 14)
#   extras    — additional rsync args after a literal "--" (typically --exclude=...)
#
#   Produces <dest_root>/YYYYMMDD-HHMMSS/... plus <dest_root>/latest, using
#   --link-dest so unchanged files are hardlinked from the previous snapshot.
#   Every run still recreates every directory and hardlink, and pruning deletes
#   a whole tree. Over NFS each of those is a synchronous round trip (~28 ms on
#   nas01 data1), so a tree of a few hundred thousand entries takes many hours:
#   Plex's ~826k entries took ~23 h per run. Use the mirror style for big trees.
#
# 3. Timestamped tarballs with retention (no app uses it since 2026-09-29)
#
#   do_tgz_backup <parent_dir> <name> <dest_dir> <prefix> <keep> [-- <extra tar args>...]
#
#   Writes <dest_dir>/<prefix>-YYYYMMDD-HHMMSS.tgz of <parent_dir>/<name>, then
#   deletes all but the <keep> newest archives named exactly
#   <prefix>-YYYYMMDD-HHMMSS.tgz. Anything else in dest_dir (other apps,
#   <prefix>-migrate-*.tgz, differently-cased names) is never touched. The
#   archive is written as .partial and renamed only when tar succeeds, so a
#   failed run leaves nothing that looks complete and prunes nothing.
#
# Plus run_detached_if_interactive, which the d03 scripts use to decide whether
# `backup` / `update` detach into screen (see its comment below).
#
# Designed to be safe under `set -euo pipefail`.

# _backup_lock <dest> — hold a non-blocking lock on <dest> for the rest of this
# process. Prints why and returns 1 if another backup already holds it.
# Re-entrant for the same dest, so one run can make two passes (gitea.sh).
_backup_lock() {
  local dest="$1" key lock_file
  [ "${_BACKUP_LOCK_DEST:-}" = "$dest" ] && return 0
  key=$(printf '%s' "$dest" | tr -c 'A-Za-z0-9._-' '_')
  lock_file="${BACKUP_LOCK_DIR:-/tmp}/backup-${key}.lock"
  exec {_BACKUP_LOCK_FD}>"$lock_file"
  if ! flock -n "$_BACKUP_LOCK_FD"; then
    echo "[ERROR] Another backup to $dest is already running (lock $lock_file); not starting a second one" >&2
    return 1
  fi
  _BACKUP_LOCK_DEST="$dest"
}

do_rsync_mirror_backup() {
  local src="$1"
  local dest="$2"
  shift 2
  if [ "${1:-}" = "--" ]; then shift; fi
  local extra_rsync_args=("$@")

  if [ ! -d "$src" ]; then
    echo "[WARN] Source dir does not exist: $src — skipping" >&2
    return 0
  fi

  _backup_lock "$dest" || return 1

  local status_file="$dest/.backup-status"
  mkdir -p "$dest"
  echo "IN PROGRESS since $(date -Is) from $(hostname -s):$src" > "$status_file"

  echo "[INFO] rsync $src/ -> $dest/ (mirror; history is the NAS's ZFS snapshots)"
  # No --inplace: changed files are written to a temp name and renamed, so an
  # update never modifies an inode still hardlinked from an older copy.
  # The status file is excluded so --delete leaves it alone.
  # rc is checked explicitly: callers often run this under `if ! run_cmd` or
  # `run_cmd || ...`, where bash ignores set -e for the whole call.
  local rc=0
  rsync -aH --delete --stats --human-readable \
    --exclude=/.backup-status \
    "${extra_rsync_args[@]}" \
    "$src/" "$dest/" || rc=$?
  if [ "$rc" -eq 24 ]; then
    echo "[WARN] rsync: some source files vanished during the copy (live app)"
  elif [ "$rc" -ne 0 ]; then
    echo "FAILED (rsync exit $rc) $(date -Is) from $(hostname -s):$src" > "$status_file"
    echo "[ERROR] rsync exit $rc; mirror at $dest is incomplete" >&2
    return "$rc"
  fi

  echo "OK $(date -Is) from $(hostname -s):$src" > "$status_file"
  echo "[INFO] Backup complete: $dest"
}

do_rsync_snapshot_backup() {
  local src="$1"
  local dest_root="$2"
  local keep="$3"
  shift 3
  if [ "${1:-}" = "--" ]; then shift; fi
  local extra_rsync_args=("$@")

  if [ ! -d "$src" ]; then
    echo "[WARN] Source dir does not exist: $src — skipping" >&2
    return 0
  fi

  _backup_lock "$dest_root" || return 1

  local stamp snapshot_dir latest_link tmp_link
  stamp=$(date +%Y%m%d-%H%M%S)
  snapshot_dir="$dest_root/$stamp"
  latest_link="$dest_root/latest"
  tmp_link="$dest_root/.latest.$$"

  mkdir -p "$dest_root"

  local link_dest_args=()
  if [ -L "$latest_link" ] && [ -d "$latest_link" ]; then
    link_dest_args=(--link-dest="$(readlink -f "$latest_link")")
    echo "[INFO] Incremental against previous snapshot: $(readlink "$latest_link")"
  else
    echo "[INFO] No previous snapshot found; first run will copy everything"
  fi

  echo "[INFO] rsync $src/ -> $snapshot_dir/"
  rsync -aH --delete --stats --human-readable \
    "${extra_rsync_args[@]}" \
    "${link_dest_args[@]}" \
    "$src/" "$snapshot_dir/"

  # Atomically update the 'latest' pointer (relative symlink).
  ln -snr "$snapshot_dir" "$tmp_link"
  mv -T "$tmp_link" "$latest_link"

  # Retention: keep only the N newest stamped snapshot dirs.
  local removed=0
  local victim
  while IFS= read -r victim; do
    [ -n "$victim" ] || continue
    rm -rf "$victim" && removed=$((removed + 1))
  done < <(ls -1d "$dest_root"/20[0-9][0-9][0-1][0-9][0-3][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9] 2>/dev/null \
            | sort | head -n -"$keep")
  if [ "$removed" -gt 0 ]; then
    echo "[INFO] Pruned $removed snapshot(s) older than the most recent $keep"
  fi

  echo "[INFO] Backup complete: $snapshot_dir"
}

do_tgz_backup() {
  local parent="$1" name="$2" dest_dir="$3" prefix="$4" keep="$5"
  shift 5
  if [ "${1:-}" = "--" ]; then shift; fi
  local extra_tar_args=("$@")

  if ! [[ "$keep" =~ ^[1-9][0-9]*$ ]]; then
    echo "[ERROR] keep must be a positive integer, got '$keep'" >&2
    return 1
  fi
  if [ ! -d "$parent/$name" ]; then
    echo "[ERROR] Source dir does not exist: $parent/$name" >&2
    return 1
  fi

  _backup_lock "$dest_dir/$prefix" || return 1

  local stamp archive partial rc=0
  stamp=$(date +%Y%m%d-%H%M%S)
  archive="$dest_dir/${prefix}-${stamp}.tgz"
  partial="$archive.partial"

  echo "[INFO] Backing up $parent/$name to $archive"
  tar -czf "$partial" -C "$parent" "${extra_tar_args[@]}" "$name" || rc=$?
  # GNU tar exit 1 means a file changed while it was read (live app); the
  # archive is complete, so keep it and say so. Anything else is a failure.
  if [ "$rc" -eq 1 ]; then
    echo "[WARN] tar: some files changed while being archived; archive kept"
  elif [ "$rc" -ne 0 ]; then
    rm -f "$partial"
    echo "[ERROR] tar exit $rc; no archive written" >&2
    return "$rc"
  fi
  mv "$partial" "$archive"
  echo "[INFO] Done. Size: $(du -h --apparent-size "$archive" | cut -f1)"

  # Retention: keep only the N newest archives of exactly this prefix.
  local removed=0 victim
  while IFS= read -r victim; do
    [ -n "$victim" ] || continue
    rm -f "$victim" && removed=$((removed + 1))
  done < <(ls -1d "$dest_dir/$prefix"-20[0-9][0-9][0-1][0-9][0-3][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].tgz 2>/dev/null \
            | sort | head -n -"$keep")
  if [ "$removed" -gt 0 ]; then
    echo "[INFO] Pruned $removed archive(s) older than the most recent $keep"
  fi
}

# run_detached_if_interactive <label> <function> [args...]
#
# Runs <function> in a detached screen session only when a person started it
# from a terminal, so an SSH drop can't kill a long backup. Every other caller
# gets the function in the foreground and its real exit code:
#   - MAINT_FOREGROUND=1 (host-maintenance sets it on every app-script call)
#   - already inside screen ($STY set: host-maintenance and update_all.sh both
#     run their tasks in screen, which gives the child a TTY, so -t 0 alone is
#     not enough)
#   - no TTY on stdin (cron, CI, ssh host cmd)
# The detached session re-runs "$0" with the private _<label> entry point.
run_detached_if_interactive() {
  local label="$1" fn="$2"
  shift 2
  if [ "${MAINT_FOREGROUND:-0}" != "1" ] && [ -z "${STY:-}" ] && [ -t 0 ]; then
    local session="${label}-${SCREEN_APP:-$(basename "$0" .sh)}-$(date +%Y%m%d-%H%M%S)"
    screen -S "$session" -dm "$0" "_${label}"
    echo "[INFO] ${label} running in screen $session; attach with: screen -r $session"
  else
    "$fn" "$@"
  fi
}
