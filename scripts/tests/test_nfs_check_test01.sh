#!/bin/bash
# Proof of the NFS check (build/setup/nfs_check/, installed by build/setup/nfs.sh), on test01 only
# (the disposable build host), after a build has installed it:
#   - the timer is enabled and active, and the metrics file shows both shares up;
#   - a share that is not mounted: up 0 and NFS_MOUNT_DOWN reason=not_mounted, then up again;
#   - the NAS not answering (nftables drops test01's traffic to 10.0.0.24 for about 70 s, so the
#     timer also runs during it): the check still ends within seconds, both shares up 0 and
#     NFS_MOUNT_DOWN reason=no_answer; after the rule is removed, both up 1 and NFS_MOUNT_UP.
#
#   scripts/tests/test_nfs_check_test01.sh     # from the workstation; uses `ssh docker@test01`
#
# Refuses to run anywhere but test01, and unless both shares are mounted when it starts. The
# nftables table and data2's mount are put back however it ends.

set -uo pipefail

if [ "${1:-}" != "--on-host" ]; then
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  ssh -o BatchMode=yes -o ConnectTimeout=10 -i ~/.ssh/docker_rsa docker@test01 '
      set -e
      [ "$(hostname -s)" = test01 ] || { echo "not test01: refusing" >&2; exit 2; }
      F=$(mktemp /tmp/nfs-check-test.XXXXXX)
      cat > "$F"
      trap "rm -f $F" EXIT
      bash "$F" --on-host' < "$REPO/scripts/tests/test_nfs_check_test01.sh"
  exit $?
fi

# ---- on test01 ----
[ "$(hostname -s)" = test01 ] || { echo "not test01: refusing" >&2; exit 2; }
NAS=10.0.0.24
S1=/mnt/nas/data1/docker
S2=/mnt/nas/data2/docker
PROM=/var/lib/node_exporter/textfile_collector/asyla_nfs.prom
UNIT=asyla-nfs-check.service
TABLE=asyla_nfs_check_test
for m in "$S1" "$S2"; do
  mountpoint -q "$m" || { echo "$m is not mounted: refusing (the test needs a working start state)" >&2; exit 2; }
done
command -v nft >/dev/null || sudo -n test -x /usr/sbin/nft || { echo "nft is not installed: refusing" >&2; exit 2; }

answers() {   # answers <mount>: statfs answers within 5 s (backgrounded, never waited on past that)
  stat -f "$1" >/dev/null 2>&1 &
  local pid=$! t
  for t in $(seq 50); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; return $?; }
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null
  return 1
}

cleanup() {
  sudo -n nft delete table inet "$TABLE" 2>/dev/null
  mountpoint -q "$S2" || sudo -n mount "$S2"
  echo "cleanup: nft table $TABLE: $(sudo -n nft list table inet "$TABLE" >/dev/null 2>&1 && echo present || echo gone); $S2 mounted: $(mountpoint -q "$S2" && echo yes || echo no)"
}
trap cleanup EXIT

fails=0
case_ok() {   # case_ok <name> <condition result 0/1>
  if [ "$2" -eq 0 ]; then echo "ok    $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi
}
up_of() { sed -n "s|^asyla_nfs_mount_up{mountpoint=\"$1\",.*} \([01]\)\$|\1|p" "$PROM"; }
journal_since() { sudo -n journalctl -u "$UNIT" --since "@$1" -o cat --no-pager; }
run_check() {   # sets TOOK (seconds) and RESULT (the unit's Result)
  local t0 t1
  t0=$(date +%s.%N)
  sudo -n systemctl start "$UNIT"
  t1=$(date +%s.%N)
  TOOK=$(awk -v s="$t0" -v e="$t1" 'BEGIN { printf "%.1f", e - s }')
  RESULT=$(systemctl show -p Result --value "$UNIT")
}

# 1. Installed and running.
case_ok "timer enabled" "$(systemctl is-enabled -q asyla-nfs-check.timer; echo $?)"
case_ok "timer active" "$(systemctl is-active -q asyla-nfs-check.timer; echo $?)"
case_ok "script installed" "$([ -x /usr/local/sbin/asyla-nfs-check ]; echo $?)"
age=$(( $(date +%s) - $(sed -n 's/^asyla_nfs_check_last_run_timestamp_seconds //p' "$PROM") ))
case_ok "metrics written by the timer within 120 s (age ${age}s)" "$([ "$age" -le 120 ]; echo $?)"
case_ok "both shares up" "$([ "$(up_of "$S1")$(up_of "$S2")" = 11 ]; echo $?)"

# 2. A share that is not mounted.
T0=$(date +%s)
sudo -n umount "$S2" || { echo "could not unmount $S2: refusing" >&2; exit 2; }
run_check
case_ok "not mounted: $S2 up 0, $S1 up 1" "$([ "$(up_of "$S1")$(up_of "$S2")" = 10 ]; echo $?)"
case_ok "not mounted: journal NFS_MOUNT_DOWN reason=not_mounted" \
  "$(journal_since "$T0" | grep -qF "NFS_MOUNT_DOWN mountpoint=$S2 source=$NAS:/mnt/data2/docker reason=not_mounted"; echo $?)"
T1=$(date +%s)
sudo -n mount "$S2"
run_check
case_ok "mounted again: both up" "$([ "$(up_of "$S1")$(up_of "$S2")" = 11 ]; echo $?)"
case_ok "mounted again: journal NFS_MOUNT_UP" "$(journal_since "$T1" | grep -qF "NFS_MOUNT_UP mountpoint=$S2"; echo $?)"

# 3. The NAS does not answer.
T2=$(date +%s)
sudo -n nft add table inet "$TABLE"
sudo -n nft add chain inet "$TABLE" out '{ type filter hook output priority 0; policy accept; }'
sudo -n nft add rule inet "$TABLE" out ip daddr "$NAS" drop
echo "      NAS traffic dropped at $(date -u +%H:%M:%SZ)"
run_check
case_ok "NAS silent: the check ends within 15 s (took ${TOOK}s)" "$(awk -v t="$TOOK" 'BEGIN { exit !(t < 15) }'; echo $?)"
case_ok "NAS silent: unit result success (got $RESULT)" "$([ "$RESULT" = success ]; echo $?)"
case_ok "NAS silent: both shares up 0" "$([ "$(up_of "$S1")$(up_of "$S2")" = 00 ]; echo $?)"
case_ok "NAS silent: journal NFS_MOUNT_DOWN reason=no_answer" \
  "$(journal_since "$T2" | grep -qF "NFS_MOUNT_DOWN mountpoint=$S1 source=$NAS:/mnt/data1/docker reason=no_answer"; echo $?)"
grep '^asyla_nfs_mount_check_seconds' "$PROM" | sed 's/^/      /'
sleep 70   # the timer runs at least once while the NAS is silent
case_ok "NAS silent: the timer's own run also ended (last run $(( $(date +%s) - $(sed -n 's/^asyla_nfs_check_last_run_timestamp_seconds //p' "$PROM") ))s ago)" \
  "$([ $(( $(date +%s) - $(sed -n 's/^asyla_nfs_check_last_run_timestamp_seconds //p' "$PROM") )) -le 70 ]; echo $?)"
case_ok "NAS silent: no stat left behind in the unit" "$([ -z "$(systemctl show -p MainPID --value "$UNIT" | grep -v '^0$')" ] && ! pgrep -f "stat -f /mnt/nas" >/dev/null; echo $?)"

sudo -n nft delete table inet "$TABLE"
echo "      NAS traffic allowed again at $(date -u +%H:%M:%SZ)"
back=""
for i in $(seq 36); do   # TCP retransmits back off; allow 3 minutes
  if answers "$S1" && answers "$S2"; then back=$((i * 5)); break; fi
  sleep 5
done
case_ok "NAS back: both shares answer again (after about ${back:-180+}s)" "$([ -n "$back" ]; echo $?)"
run_check
case_ok "NAS back: both shares up 1" "$([ "$(up_of "$S1")$(up_of "$S2")" = 11 ]; echo $?)"
case_ok "NAS back: journal NFS_MOUNT_UP" "$(journal_since "$T2" | grep -qF "NFS_MOUNT_UP mountpoint=$S1"; echo $?)"

if [ "$fails" -eq 0 ]; then echo "all cases passed"; else echo "$fails case(s) failed"; journal_since "$T0" | tail -20; fi
exit $(( fails > 0 ))
