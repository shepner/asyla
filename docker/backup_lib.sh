# Shared rsync backup helpers. Source from any app's <app>.sh:
#   . "$HOME/scripts/docker/backup_lib.sh"
#
# Two styles. Both take a per-destination lock, so a manual `<app>.sh backup`
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
# 2. Hardlink snapshots (legacy; only for small trees)
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
# Designed to be safe under `set -euo pipefail`.

# _backup_lock <dest> — hold a non-blocking lock on <dest> for the rest of this
# process. Prints why and returns 1 if another backup already holds it.
_backup_lock() {
  local dest="$1" key lock_file
  key=$(printf '%s' "$dest" | tr -c 'A-Za-z0-9._-' '_')
  lock_file="${BACKUP_LOCK_DIR:-/tmp}/backup-${key}.lock"
  exec {_BACKUP_LOCK_FD}>"$lock_file"
  if ! flock -n "$_BACKUP_LOCK_FD"; then
    echo "[ERROR] Another backup to $dest is already running (lock $lock_file); not starting a second one" >&2
    return 1
  fi
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
  rsync -aH --delete --stats --human-readable \
    --exclude=/.backup-status \
    "${extra_rsync_args[@]}" \
    "$src/" "$dest/"

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
