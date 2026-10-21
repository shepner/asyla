#!/bin/bash
# Failure-path test of build/setup/nfs.sh, on test01 only (the disposable build host): a share that
# does not mount must fail the setup step. It used to be a warning and exit 0, so a build ran on
# through restore and apps with no NAS (test01, 2026-10-14).
#
# It runs this checkout's build/setup/nfs.sh (HOST_SPEC = test01/host.toml; nfs_check/ beside it) with a `mount` that always refuses (and `apt`,
# `sleep` and `systemctl` that do nothing) first in PATH, once with /mnt/nas/data2/docker
# unmounted (expected: exit 1, that share named, data1 not named) and once with both shares
# mounted (expected: exit 0). It then mounts data2 again with the real mount and checks it.
# /etc/fstab is not changed: its two lines already match, so the script skips them.
#
#   scripts/tests/test_nfs_mount_failure_test01.sh     # from the workstation; uses `ssh docker@test01`
#
# Refuses to run anywhere but test01, and unless both shares are mounted when it starts.

set -uo pipefail

if [ "${1:-}" != "--on-host" ]; then
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  COPYFILE_DISABLE=1 tar -C "$REPO" -cf - build/setup/nfs.sh build/setup/nfs_check test01/host.toml \
      scripts/tests/test_nfs_mount_failure_test01.sh |
    ssh -o BatchMode=yes -o ConnectTimeout=10 -i ~/.ssh/docker_rsa docker@test01 '
      set -e
      [ "$(hostname -s)" = test01 ] || { echo "not test01: refusing" >&2; exit 2; }
      D=$(mktemp -d /tmp/nfs-fail.XXXXXX)
      tar -C "$D" -xf - 2>/dev/null
      exec bash "$D/scripts/tests/test_nfs_mount_failure_test01.sh" --on-host "$D"'
  exit $?
fi

# ---- on test01 ----
D="$2"
[ "$(hostname -s)" = test01 ] || { echo "not test01: refusing" >&2; exit 2; }
case "$D" in /tmp/nfs-fail.*) ;; *) echo "unexpected dir $D: refusing" >&2; exit 2 ;; esac
S1=/mnt/nas/data1/docker
S2=/mnt/nas/data2/docker
for m in "$S1" "$S2"; do
  mountpoint -q "$m" || { echo "$m is not mounted: refusing (the test needs a working start state)" >&2; exit 2; }
done
FSTAB_BEFORE=$(sha256sum < /etc/fstab)

mkdir -p "$D/bin"
printf '#!/bin/sh\necho "mount.nfs: access denied by server while mounting (test stub)" >&2\nexit 32\n' > "$D/bin/mount"
for c in apt sleep systemctl; do printf '#!/bin/sh\nexit 0\n' > "$D/bin/$c"; done
chmod 755 "$D"/bin/*

cleanup() {
  mountpoint -q "$S2" || sudo -n mount "$S2"
  rm -rf "$D"
  echo "cleanup: $S1 mounted: $(mountpoint -q "$S1" && echo yes || echo no); $S2 mounted: $(mountpoint -q "$S2" && echo yes || echo no); $D exists: $([ -e "$D" ] && echo yes || echo no)"
}
trap cleanup EXIT

run_nfs() {   # sets RC and OUT
  OUT=$(sudo -n env PATH="$D/bin:$PATH" HOST_SPEC="$D/test01/host.toml" bash "$D/build/setup/nfs.sh" 2>&1)
  RC=$?
}

fails=0
case_ok() {   # case_ok <name> <condition result 0/1>
  if [ "$2" -eq 0 ]; then echo "ok    $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi
}

sudo -n umount "$S2" || { echo "could not unmount $S2: refusing" >&2; exit 2; }
run_nfs
case_ok "a share that does not mount: exit 1 (got $RC)" "$([ "$RC" -eq 1 ]; echo $?)"
case_ok "the failed share is named" "$(grep -q "Not mounted: $S2" <<<"$OUT"; echo $?)"
case_ok "the mount error is shown" "$(grep -q "access denied by server" <<<"$OUT"; echo $?)"
case_ok "the mounted share is not named as failed" "$(! grep -q "Could not mount $S1" <<<"$OUT"; echo $?)"
case_ok "the old warning is gone" "$(! grep -q "will mount on boot" <<<"$OUT"; echo $?)"
[ "$fails" -eq 0 ] || echo "$OUT" | tail -15

sudo -n mount "$S2"
case_ok "$S2 mounts again with the real mount" "$(mountpoint -q "$S2"; echo $?)"
run_nfs
case_ok "both shares mounted: exit 0 (got $RC)" "$([ "$RC" -eq 0 ]; echo $?)"
case_ok "/etc/fstab unchanged" "$([ "$(sha256sum < /etc/fstab)" = "$FSTAB_BEFORE" ]; echo $?)"

if [ "$fails" -eq 0 ]; then echo "all cases passed"; else echo "$fails case(s) failed"; fi
exit $(( fails > 0 ))
