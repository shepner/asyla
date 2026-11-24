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
#
# Environment (all optional): D01_SSH the ssh target (default d01, as the workstation's ssh config
# has it); SSH_IDENTITY a key file for it (ssh -i, IdentitiesOnly), for a target the ssh config does
# not cover (docker@test01 on a d01 replica); RESTART=1 restarts where-to-stream after the push and
# waits for its /healthz (up to 120 s), failing if it does not answer. d01/host.toml's [[external]]
# where-to-stream runs it that way, so a build_host.py rebuild of d01 ships the source (asyla #1247).
set -euo pipefail

REPO="${1:-$HOME/local/personal/projects/where-to-stream}"
HOST="${D01_SSH:-d01}"
DEST="${DEST:-/mnt/docker/where-to-stream/src}"
SSH_CMD=(ssh)
if [ -n "${SSH_IDENTITY:-}" ]; then
  SSH_CMD+=(-i "$SSH_IDENTITY" -o IdentitiesOnly=yes)
fi

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
  "${SSH_CMD[@]}" "$HOST" "set -e; rm -rf '$DEST.new'; mkdir -p '$DEST.new' '$DEST'; tar -x -C '$DEST.new'; echo '$sha' >'$DEST.new/.git-sha'; rsync -a --delete '$DEST.new/' '$DEST/'; rm -rf '$DEST.new'"
echo "[OK] $HOST:$DEST at $sha"
if [ "${RESTART:-0}" != "1" ]; then
  echo "[INFO] Load it: ssh $HOST docker restart where-to-stream"
  exit 0
fi
# The healthcheck's own probe (compose.yml): the port is not published, so it is asked inside the container.
probe="docker exec where-to-stream python3 -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=5)\""
"${SSH_CMD[@]}" "$HOST" "set -e; docker restart where-to-stream >/dev/null; for i in \$(seq 60); do $probe 2>/dev/null && exit 0; sleep 2; done; exit 1" \
  || { echo "[ERROR] where-to-stream on $HOST did not answer /healthz within 120 s after the restart" >&2; exit 1; }
echo "[OK] where-to-stream restarted on $HOST and answers /healthz"
