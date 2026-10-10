#!/bin/bash
# Real-container test of `gitea.sh up|restart verify`, on d04 only (the disposable build host).
# It starts the same Gitea image as d03 from this checkout's gitea.sh and compose.yml, on an
# EMPTY data directory in a temp dir: never d03's restored data under /mnt/docker/Gitea, so no
# repository, user, mirror or mail exists in it. It then checks that `up verify` and
# `restart verify` pass in one call and that verify fails once Gitea is down, and removes the
# container, the network and the temp dir. The offline twin is test_gitea_verify.sh.
#
#   scripts/tests/test_gitea_verify_d04.sh          # from the workstation; uses `ssh d04`
#
# Refuses to run anywhere but d04, and when a container named gitea already exists there.

set -uo pipefail

if [ "${1:-}" != "--on-host" ]; then
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  COPYFILE_DISABLE=1 tar -C "$REPO" -cf - d03/apps/gitea/gitea.sh d03/apps/gitea/compose.yml \
      docker/common.env docker/backup_lib.sh scripts/tests/test_gitea_verify_d04.sh |
    ssh -o BatchMode=yes -o ConnectTimeout=10 d04 '
      set -e
      [ "$(hostname -s)" = d04 ] || { echo "not d04: refusing" >&2; exit 2; }
      D=$(mktemp -d /tmp/gitea-verify.XXXXXX)
      tar -C "$D" -xf - 2>/dev/null
      exec bash "$D/scripts/tests/test_gitea_verify_d04.sh" --on-host "$D"'
  exit $?
fi

# ---- on d04 ----
D="$2"
[ "$(hostname -s)" = d04 ] || { echo "not d04: refusing" >&2; exit 2; }
case "$D" in /tmp/gitea-verify.*) ;; *) echo "unexpected dir $D: refusing" >&2; exit 2 ;; esac
if [ -n "$(docker ps -aq --filter name='^gitea$')" ]; then
  echo "a container named gitea already exists on d04: refusing (not removing $D)" >&2
  exit 2
fi

mkdir -p "$D/home" "$D/data/Gitea/data"
ln -s "$D" "$D/home/scripts"
# common.env sets DOCKER_DL unconditionally; point the copy at the empty temp data dir.
sed -i "s|^DOCKER_DL=.*|DOCKER_DL=$D/data|" "$D/docker/common.env"
grep -q "^DOCKER_DL=$D/data\$" "$D/docker/common.env" || { echo "could not repoint DOCKER_DL" >&2; exit 2; }

GITEA_SH="$D/d03/apps/gitea/gitea.sh"
# compose.yml mounts /etc/timezone, which Debian 13 does not have: Docker then creates it as an
# empty directory. Remove it afterwards if this run made it.
HAD_TIMEZONE=no; [ -e /etc/timezone ] && HAD_TIMEZONE=yes
cleanup() {
  HOME="$D/home" bash "$GITEA_SH" down >/dev/null 2>&1
  [ "$HAD_TIMEZONE" = no ] && [ -d /etc/timezone ] && sudo -n rmdir /etc/timezone
  # The container wrote root- and 1003-owned files into the data dir.
  sudo -n rm -rf "$D" 2>/dev/null || docker run --rm --entrypoint rm -v /tmp:/t docker.gitea.com/gitea:1 -rf "/t/${D#/tmp/}"
  [ -e "$D" ] && echo "[WARN] $D not removed" >&2
  echo "cleanup: containers named gitea left: $(docker ps -aq --filter name='^gitea$' | wc -l); $D exists: $([ -e "$D" ] && echo yes || echo no)"
}
trap cleanup EXIT

run_gitea() {  # run_gitea <wait seconds> <switch ...>: sets RC, OUT and TOOK
  local wait_s="$1" t0=$SECONDS
  shift
  OUT="$(HOME="$D/home" GITEA_VERIFY_WAIT_S="$wait_s" GITEA_PUBLIC_URL="http://127.0.0.1:3000" \
    bash "$GITEA_SH" "$@" 2>&1)"
  RC=$?
  TOOK=$((SECONDS - t0))
}

fails=0
check() {  # check <name> <condition as a string>
  if eval "$2"; then
    echo "ok    $1 (exit $RC, ${TOOK}s)"
  else
    echo "FAIL  $1 (exit $RC, ${TOOK}s): expected $2"
    echo "$OUT" | tail -15 | sed 's/^/        /'
    fails=$((fails + 1))
  fi
}

HOME="$D/home" bash "$GITEA_SH" _update 2>&1 | tail -1   # pull the image outside the timings

run_gitea 120 up verify
check "up verify, first start on empty data" '[ "$RC" -eq 0 ] && grep -q "Local :3000 OK" <<<"$OUT"'
echo "      gitea version: $(curl -s --max-time 5 http://127.0.0.1:3000/api/v1/version)"

run_gitea 120 restart verify
check "restart verify in one call" '[ "$RC" -eq 0 ] && grep -q "Local :3000 OK" <<<"$OUT"'
grep -q "Waiting" <<<"$OUT" && echo "      (verify had to wait: the race was live in this run)"

# Reported, not asserted: with no wait, the old behaviour. It fails only when Gitea is slower
# to answer than compose is to return, as on d03 on 2026-10-10.
run_gitea 0 restart verify
echo "info  restart verify with no wait (the old behaviour): exit $RC"
run_gitea 120 verify
check "verify once Gitea is up again" '[ "$RC" -eq 0 ]'

run_gitea 6 down verify
check "verify with Gitea down fails after the bounded wait" '[ "$RC" -ne 0 ] && [ "$TOOK" -ge 6 ] && [ "$TOOK" -le 40 ]'

if [ "$fails" -eq 0 ]; then
  echo "all cases passed"
else
  echo "$fails case(s) failed"
  exit 1
fi
