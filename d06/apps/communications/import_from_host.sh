#!/bin/bash
# Runs on the workstation (WS01), not on d06: C4 step 3, the Mini's final message-store backup into
# d06's mirror, as a committed script instead of improvised SSH (README.md, Import).
# Usage: import_from_host.sh MINI_PATH | --volume NAME   (exactly one)
#   MINI_PATH: the absolute path, on the source host, of the directory theOrg's one-shot backup
#   wrote (COMMS_BACKUP_DIR: STATUS comms.dump tables.tsv manifest.sha256).
#   --volume NAME: the named Docker volume on the source host that holds those four files (C4:
#   theOrg's final backup.yml writes `communications-final-backup`). On the Mini's Docker Desktop a
#   volume has no host path the Mac user can read, so the files are read through a throwaway
#   container: `docker run --rm -v NAME:/b:ro IMAGE tar -C /b -cf - ...`, a read-only mount, no
#   root shell and no copy left behind. IMAGE is IMPORT_TAR_IMAGE (default alpine:3.20).
# How the bytes move: `ssh MINI_SSH` (default 10.0.0.150, as this user) packs the four files as a
# tar on its stdout; this host pipes it, in memory only, into `ssh D06_SSH` (default docker@d06),
# which writes it to D06_IMPORT_DIR/mini-<UTC time>.tar under umask 077. Then
# `communications.sh import` on d06 checks it and mirrors it to the NAS; the tar is removed once
# import succeeds and kept for a retry when it does not. Nothing is restored: the restore is C4
# step 4, its own approval. IMPORT_FORCE=1 is passed on to import (it replaces a backup already in
# the mirror).
# MINI_PATH mode runs no container: the source host's ssh user must be able to read the four files.
# theOrg's image writes them owner-only as uid 999; whether a Docker Desktop bind mount on the Mini
# shows them as the Mac user's is not checked here. If tar says Permission denied there, theOrg
# makes them readable to that user; this script does not work around it. In --volume mode the tar
# runs inside the container, which reads the uid 999 files.
set -euo pipefail

MINI_SSH="${MINI_SSH:-10.0.0.150}"
D06_SSH="${D06_SSH:-docker@d06}"
D06_IMPORT_DIR="${D06_IMPORT_DIR:-/mnt/docker/Communications/import}"
# Expanded by d06's shell, not here.
# shellcheck disable=SC2088
D06_SCRIPT="${D06_SCRIPT:-~/scripts/d06/apps/communications/communications.sh}"
FILES="STATUS comms.dump tables.tsv manifest.sha256"
SSH=(ssh -o BatchMode=yes)
IMAGE="${IMPORT_TAR_IMAGE:-alpine:3.20}"

usage() {
  echo "Usage: $0 MINI_PATH | --volume NAME   (exactly one: the absolute path on $MINI_SSH of the backup directory, or the Docker volume there, holding $FILES)" >&2
  exit 1
}
mini_path=""; volume=""
if [ $# -eq 2 ] && [ "$1" = --volume ]; then
  volume="$2"
elif [ $# -eq 1 ] && [ "$1" != --volume ]; then
  mini_path="$1"
else
  usage
fi
# Both go into the remote command below, so only plain name and path characters.
if [ -n "$volume" ]; then
  if ! [[ "$volume" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "[ERROR] --volume NAME must match ^[A-Za-z0-9][A-Za-z0-9_.-]*\$" >&2
    exit 1
  fi
  if ! [[ "$IMAGE" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]]; then
    echo "[ERROR] IMPORT_TAR_IMAGE must be an image reference of A-Z a-z 0-9 . _ / : @ -" >&2
    exit 1
  fi
  source_desc="$MINI_SSH volume $volume"
  # $PATH is expanded by the Mini's shell: Docker Desktop's CLI is in /usr/local/bin, which a
  # non-login ssh shell may not have.
  # shellcheck disable=SC2016
  source_cmd='PATH=/usr/local/bin:$PATH'" docker run --rm -v $volume:/b:ro $IMAGE tar -C /b -cf - $FILES"
else
  if ! [[ "$mini_path" =~ ^/[A-Za-z0-9._/-]+$ ]] || [[ "$mini_path" == *..* ]]; then
    echo "[ERROR] MINI_PATH must be an absolute path of A-Z a-z 0-9 . _ - / without '..'" >&2
    exit 1
  fi
  source_desc="$MINI_SSH:$mini_path"
  # COPYFILE_DISABLE and --no-xattrs: macOS tar adds no ._ AppleDouble members and no xattr headers.
  source_cmd="cd '$mini_path' && COPYFILE_DISABLE=1 tar --no-xattrs -cf - $FILES"
fi
force="${IMPORT_FORCE:-0}"
if [ "$force" != 0 ] && [ "$force" != 1 ]; then
  echo "[ERROR] IMPORT_FORCE must be 0 or 1" >&2
  exit 1
fi
if ! [[ "$D06_IMPORT_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "[ERROR] D06_IMPORT_DIR must be an absolute path of A-Z a-z 0-9 . _ - /" >&2
  exit 1
fi
remote="$D06_IMPORT_DIR/mini-$(date -u +%Y%m%dT%H%M%SZ).tar"

echo "[INFO] $source_desc -> $D06_SSH:$remote (through this host's memory, not its disk)"
if ! "${SSH[@]}" "$MINI_SSH" "$source_cmd" \
    | "${SSH[@]}" "$D06_SSH" "umask 077 && mkdir -p '$D06_IMPORT_DIR' && cat > '$remote'"; then
  echo "[ERROR] the copy failed (the line above says where); removing the partial $remote" >&2
  "${SSH[@]}" "$D06_SSH" "rm -f '$remote'" || echo "[WARN] could not remove $D06_SSH:$remote" >&2
  exit 1
fi
if ! "${SSH[@]}" "$D06_SSH" "IMPORT_FORCE=$force $D06_SCRIPT import '$remote'"; then
  echo "[ERROR] communications.sh import on d06 refused or failed (its line above says why); $remote kept for a retry" >&2
  exit 1
fi
"${SSH[@]}" "$D06_SSH" "rm -f '$remote'" || echo "[WARN] imported, but could not remove $D06_SSH:$remote" >&2
echo "[INFO] imported, not restored. C4 step 4 (its own approval): ssh $D06_SSH 'RESTORE_FORCE=1 $D06_SCRIPT restore'"
