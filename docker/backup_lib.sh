# Shared rsync snapshot backup helper. Source from any app's <app>.sh:
#   . "$HOME/scripts/docker/backup_lib.sh"
#
# Usage:
#   do_rsync_snapshot_backup <src_dir> <dest_root> <keep> [-- <extra rsync args>...]
#
#   src_dir   — directory to back up (e.g. /mnt/docker/calibre)
#   dest_root — root holding snapshots (e.g. /mnt/nas/data1/docker/calibre)
#   keep      — number of snapshot dirs to retain (recommend 14)
#   extras    — additional rsync args after a literal "--" (typically --exclude=...)
#
# Produces:
#   <dest_root>/YYYYMMDD-HHMMSS/...    (each daily snapshot)
#   <dest_root>/latest -> YYYYMMDD-HHMMSS   (symlink to most recent)
#
# Uses --link-dest against <latest> so each daily run only transfers what
# actually changed; unchanged files are hardlinked from the previous snapshot.
# This keeps daily NAS writes small and lets the NAS share storage across days.
#
# Designed to be safe under `set -euo pipefail`.

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
