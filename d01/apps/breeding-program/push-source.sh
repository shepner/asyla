#!/bin/bash
# Workstation side: ship the committed HEAD of the breeding-program repo to d01 for a native build.
# d01 holds no Gitea credentials, so the source travels as a git archive over ssh.
# Usage: push-source.sh [path-to-breeding-program-repo]   (default ~/local/asyla/projects/breeding-program)
# Then on d01: ~/scripts/d01/apps/breeding-program/breeding-program.sh build restart verify
set -euo pipefail

REPO="${1:-$HOME/local/asyla/projects/breeding-program}"
HOST="${D01_SSH:-d01}"
DEST="${DEST:-/mnt/docker/breeding-program/src}"

if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]; then
  echo "[WARN] $REPO has uncommitted changes; shipping HEAD only" >&2
fi
sha="$(git -C "$REPO" rev-parse HEAD)"
echo "[INFO] Shipping $(git -C "$REPO" rev-parse --short HEAD) to $HOST:$DEST"
git -C "$REPO" archive --format=tar HEAD |
  ssh "$HOST" "set -e; rm -rf '$DEST.new'; mkdir -p '$DEST.new'; tar -x -C '$DEST.new'; echo '$sha' >'$DEST.new/.git-sha'; rm -rf '$DEST'; mv '$DEST.new' '$DEST'"
echo "[OK] $HOST:$DEST at $sha"
