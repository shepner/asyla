#!/bin/bash
# Workstation side: ship the committed HEAD of the where-to-stream repo to d01, where the media stack's
# where-to-stream service runs it from /app (read-only bind mount of DEST). Modelled on
# ../breeding-program/push-source.sh: d01 holds no Gitea credentials, so the source travels as a git
# archive over ssh, and DEST/.git-sha records the commit.
#
# DEST is updated in place (rsync --delete from a staged copy), not replaced: the running container's
# bind mount follows the directory it was started with, so a rm + mv would leave it an empty, deleted
# directory until the next restart. The data dir (/mnt/docker/where-to-stream/data) is never touched.
#
# Usage: push-where-to-stream.sh [path-to-where-to-stream-repo]   (default ~/local/personal/projects/where-to-stream)
# Then on d01, to load the new code: docker restart where-to-stream
# (the first time: ~/scripts/d01/apps/media/media.sh up, which creates the container)
set -euo pipefail

REPO="${1:-$HOME/local/personal/projects/where-to-stream}"
HOST="${D01_SSH:-d01}"
DEST="${DEST:-/mnt/docker/where-to-stream/src}"

if [ ! -f "$REPO/serve.py" ]; then
  echo "[ERROR] $REPO has no serve.py; is it the where-to-stream repo?" >&2
  exit 1
fi
if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]; then
  echo "[WARN] $REPO has uncommitted changes; shipping HEAD only" >&2
fi
sha="$(git -C "$REPO" rev-parse HEAD)"
echo "[INFO] Shipping $(git -C "$REPO" rev-parse --short HEAD) to $HOST:$DEST"
git -C "$REPO" archive --format=tar HEAD |
  ssh "$HOST" "set -e; rm -rf '$DEST.new'; mkdir -p '$DEST.new' '$DEST'; tar -x -C '$DEST.new'; echo '$sha' >'$DEST.new/.git-sha'; rsync -a --delete '$DEST.new/' '$DEST/'; rm -rf '$DEST.new'"
echo "[OK] $HOST:$DEST at $sha"
echo "[INFO] Load it: ssh $HOST docker restart where-to-stream"
