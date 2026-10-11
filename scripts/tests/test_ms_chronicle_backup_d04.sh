#!/bin/bash
# The cases of test_ms_chronicle_backup.sh, run on d04 only (the disposable build host): the same
# bash, curl, python3 and coreutils d03 has, which the offline run on a workstation does not.
# Nothing real is involved: the route is chronicle_backup_stub.py on d04's loopback, and the
# mirror is a directory under a temp dir in /tmp. The script under test runs from a copy whose
# common.env points DATA1 into that temp dir, so it cannot reach /mnt/nas; d04 mounts the NAS
# read-only besides. This wrapper also shows that the real mirror path was not created or changed.
#
#   scripts/tests/test_ms_chronicle_backup_d04.sh          # from the workstation; uses `ssh d04`
#
# Refuses to run anywhere but d04.

set -uo pipefail

if [ "${1:-}" != "--on-host" ]; then
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  COPYFILE_DISABLE=1 tar -C "$REPO" --exclude='.env' -cf - d03/apps/ms-chronicle-backup \
      docker/common.env docker/backup_lib.sh scripts/tests/chronicle_backup_stub.py \
      scripts/tests/test_ms_chronicle_backup.sh scripts/tests/test_ms_chronicle_backup_d04.sh |
    ssh -o BatchMode=yes -o ConnectTimeout=10 d04 '
      set -e
      [ "$(hostname -s)" = d04 ] || { echo "not d04: refusing" >&2; exit 2; }
      D=$(mktemp -d /tmp/ms-chronicle-backup.XXXXXX)
      tar -C "$D" -xf - 2>/dev/null
      exec bash "$D/scripts/tests/test_ms_chronicle_backup_d04.sh" --on-host "$D"'
  exit $?
fi

# ---- on d04 ----
D="$2"
[ "$(hostname -s)" = d04 ] || { echo "not d04: refusing" >&2; exit 2; }
case "$D" in /tmp/ms-chronicle-backup.*) ;; *) echo "unexpected dir $D: refusing" >&2; exit 2 ;; esac
[ ! -e "$D/d03/apps/ms-chronicle-backup/.env" ] || { echo "a .env was shipped: refusing" >&2; exit 2; }

REAL=/mnt/nas/data1/docker/ms-chronicle
real_state() {  # the real path on the NAS, as d04 sees it: absent, or every entry with size and mtime
  if [ -e "$REAL" ]; then find "$REAL" -printf '%p %s %T@\n' 2>&1 | sort; else echo absent; fi
}
cleanup() {
  rm -rf "$D"
  echo "cleanup: $D exists: $([ -e "$D" ] && echo yes || echo no); stub processes left: $(pgrep -fc chronicle_backup_stub.py || true)"
}
trap cleanup EXIT

echo "host: $(hostname -s); $(bash --version | head -1); $(curl --version | head -1 | cut -d' ' -f1-2); $(python3 --version)"
echo "NAS mount /mnt/nas/data1/docker on this host: $(findmnt -no OPTIONS /mnt/nas/data1/docker 2>/dev/null | tr ',' '\n' | grep -E '^(ro|rw)$' || echo 'not mounted')"
BEFORE="$(real_state)"
echo "real path $REAL before: $(head -c 300 <<<"$BEFORE")"

mkdir -p "$D/t"
TMPDIR="$D/t" bash "$D/scripts/tests/test_ms_chronicle_backup.sh"
rc=$?

AFTER="$(real_state)"
if [ "$AFTER" = "$BEFORE" ]; then
  echo "ok    the real path $REAL is as it was"
else
  echo "FAIL  the real path $REAL changed during the test"
  rc=1
fi
left="$(ls -A "$D/t" | wc -l)"
if [ "$left" -eq 0 ]; then
  echo "ok    the test left nothing in its temp dir"
else
  echo "FAIL  $left entr(ies) left in $D/t"
  rc=1
fi
exit "$rc"
