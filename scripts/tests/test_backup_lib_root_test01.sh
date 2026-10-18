#!/bin/bash
# Test of backup_lib.sh's mirror backup and restore keeping the top directory's mode and owner,
# on test01 only (it needs Linux stat, flock and sudo; the workstation has none of the three as
# the library uses them). Temp dirs under /tmp only: no app data and no NAS path is touched.
#
# The fault: a restored app directory took the mirror directory's mode, and the NAS gives a
# mirror directory its own (breeding-research's 2775 came back 755 on d04, 2026-10-09). The test
# makes a source directory 2775 owned by docker:docker (gid 1000), backs it up, sets the mirror
# directory to 755 as the NAS would, restores, and expects 2775 and gid 1000 back.
#
#   scripts/tests/test_backup_lib_root_test01.sh     # from the workstation; uses `ssh docker@test01`

set -uo pipefail

if [ "${1:-}" != "--on-host" ]; then
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  COPYFILE_DISABLE=1 tar -C "$REPO" -cf - docker/backup_lib.sh scripts/tests/test_backup_lib_root_test01.sh |
    ssh -o BatchMode=yes -o ConnectTimeout=10 -i ~/.ssh/docker_rsa docker@test01 '
      set -e
      [ "$(hostname -s)" = test01 ] || { echo "not test01: refusing" >&2; exit 2; }
      D=$(mktemp -d /tmp/backup-root.XXXXXX)
      tar -C "$D" -xf - 2>/dev/null
      exec bash "$D/scripts/tests/test_backup_lib_root_test01.sh" --on-host "$D"'
  exit $?
fi

# ---- on test01 ----
D="$2"
[ "$(hostname -s)" = test01 ] || { echo "not test01: refusing" >&2; exit 2; }
case "$D" in /tmp/backup-root.*) ;; *) echo "unexpected dir $D: refusing" >&2; exit 2 ;; esac
trap 'rm -rf "$D"; echo "cleanup: $D exists: $([ -e "$D" ] && echo yes || echo no)"' EXIT
export BACKUP_LOCK_DIR="$D"
. "$D/docker/backup_lib.sh"

fails=0
is() {   # is <name> <got> <want>
  if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
}

SRC="$D/app"; MIRROR="$D/nas/app/mirror"
mkdir -p "$SRC/sub"; echo data > "$SRC/sub/file"
chgrp 1000 "$SRC" && chmod 2775 "$SRC"
is "start: source is 2775, group 1000" "$(stat -c '%a %g' "$SRC")" "2775 1000"

( do_rsync_mirror_backup "$SRC" "$MIRROR" ) >/dev/null 2>&1
is "backup: exit 0" "$?" "0"
is "backup: .backup-root holds mode, uid, gid" "$(cat "$MIRROR/.backup-root" 2>/dev/null)" "2775 $(id -u) 1000"
is "backup: status is OK" "$(head -c2 "$MIRROR/.backup-status")" "OK"
( do_rsync_mirror_backup "$SRC" "$MIRROR" ) >/dev/null 2>&1
is "second backup: .backup-root survives --delete" "$(cat "$MIRROR/.backup-root" 2>/dev/null)" "2775 $(id -u) 1000"

# As the NAS does: the mirror directory has its own mode and group.
# 00755: GNU chmod 755 keeps a directory's setgid bit (2775 becomes 2755).
chmod 00755 "$MIRROR"; chgrp "$(id -g)" "$MIRROR"
OUT="$D/restored"
( do_rsync_mirror_restore "$MIRROR" "$OUT" ) >/dev/null 2>&1
is "restore: exit 0" "$?" "0"
is "restore: top directory is 2775, group 1000 again" "$(stat -c '%a %g' "$OUT")" "2775 1000"
is "restore: the data is back" "$(cat "$OUT/sub/file" 2>/dev/null)" "data"
is "restore: .backup-root is not copied into the app's data" "$([ -e "$OUT/.backup-root" ] && echo there || echo absent)" "absent"

# A source without setgid and a setgid mirror directory: the restore clears the bit.
SRC3="$D/app3"; MIRROR3="$D/nas/app3/mirror"; OUT3="$D/restored3"
mkdir -p "$SRC3"; echo data > "$SRC3/file"; chmod 00755 "$SRC3"
( do_rsync_mirror_backup "$SRC3" "$MIRROR3" ) >/dev/null 2>&1
chmod 2775 "$MIRROR3"
( do_rsync_mirror_restore "$MIRROR3" "$OUT3" ) >/dev/null 2>&1
is "setgid mirror: restore exit 0" "$?" "0"
is "setgid mirror: top directory is 755, no setgid" "$(stat -c '%a' "$OUT3")" "755"

# Extra rsync args after "--" (d01's duplicati: its pre-upgrade copies "backup <job> <stamp>.sqlite"
# stay in the mirror and are left out of the restore; a name with spaces, anchored at the root).
SRC4="$D/app4"; MIRROR4="$D/nas/app4/mirror"; OUT4="$D/restored4"
mkdir -p "$SRC4/config/sub"
echo live > "$SRC4/config/ABC.sqlite"; echo copy > "$SRC4/config/backup ABC 20260521.sqlite"
echo nested > "$SRC4/config/sub/backup ABC 20260521.sqlite"
( do_rsync_mirror_backup "$SRC4" "$MIRROR4" ) >/dev/null 2>&1
( do_rsync_mirror_restore "$MIRROR4" "$OUT4" -- '--exclude=/config/backup *.sqlite' ) >/dev/null 2>&1
is "extra args: restore exit 0" "$?" "0"
is "extra args: the live database is back" "$(cat "$OUT4/config/ABC.sqlite" 2>/dev/null)" "live"
is "extra args: the excluded copy is left out" "$([ -e "$OUT4/config/backup ABC 20260521.sqlite" ] && echo there || echo absent)" "absent"
is "extra args: the anchor keeps a deeper file of that name" "$(cat "$OUT4/config/sub/backup ABC 20260521.sqlite" 2>/dev/null)" "nested"
is "extra args: the mirror still holds the copy" "$(cat "$MIRROR4/config/backup ABC 20260521.sqlite" 2>/dev/null)" "copy"
OUT5="$D/restored5"
( do_rsync_mirror_restore "$MIRROR4" "$OUT5" ) >/dev/null 2>&1
is "no extra args: everything is back" "$(cat "$OUT5/config/backup ABC 20260521.sqlite" 2>/dev/null)" "copy"

# A mirror from before .backup-root: restores as before, and says which mode it left.
rm "$MIRROR/.backup-root"
OUT2="$D/restored-old"
MSG=$( ( do_rsync_mirror_restore "$MIRROR" "$OUT2" ) 2>&1 >/dev/null )
is "old mirror: exit 0" "$?" "0"
is "old mirror: warns, naming the mode" "$(grep -c 'no .backup-root.*keeps mode 755' <<<"$MSG")" "1"

# A damaged .backup-root is refused, not passed to chmod.
echo '2775; reboot 0 0' > "$MIRROR/.backup-root"
( RESTORE_FORCE=1 do_rsync_mirror_restore "$MIRROR" "$OUT2" ) >/dev/null 2>&1
is "damaged .backup-root: exit 1" "$?" "1"

if [ "$fails" -eq 0 ]; then echo "all cases passed"; else echo "$fails case(s) failed"; fi
exit $(( fails > 0 ))
