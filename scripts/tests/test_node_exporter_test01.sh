#!/bin/bash
# Proof of the node exporter step (build/setup/node_exporter.sh), on test01 only (the disposable
# build host):
#   - installed: the exporter and the copy timer active, the unit's address filter in place;
#   - served: every textfile parses, smart.prom (test01's one source, on the NAS) copied with its
#     source's mtime, /mnt/docker in the filesystem collector and /mnt/nas not, no veth interfaces;
#   - sources that fail: a FIFO (a read that never ends), a missing file and a good one in the
#     list: the copy ends within its limit, the FIFO is no_answer (last copy kept), the missing
#     one's copy is removed, the good one is copied, with journal lines;
#   - the NAS not answering (nftables drops test01's traffic to 10.0.0.24 for about 45 s): the copy
#     still ends within its limit, smart.prom no_answer with its last copy kept, and a scrape answers
#     at once meanwhile; after the rule goes, smart.prom copied again;
#   - from the workstation: port 9100 does not answer it (not in allow); with the workstation's
#     address allowed at runtime it answers; with that removed it does not again.
#
#   scripts/tests/test_node_exporter_test01.sh             # checks only (after a build installed it)
#   scripts/tests/test_node_exporter_test01.sh --install   # first runs the step from this working
#                                                          # tree (a build sends GitLab master)
#
# Refuses to run anywhere but test01. The source list, the nftables table and the runtime allow
# are put back however it ends.

set -uo pipefail
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$HOME/.ssh/docker_rsa" docker@test01)

if [ "${1:-}" != "--on-host" ]; then
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  if [ "${1:-}" = "--install" ]; then
    echo "== install: build/setup/node_exporter.sh from the working tree"
    tar -czf - -C "$REPO" build test01/host.toml | "${SSH[@]}" '
        set -e
        [ "$(hostname -s)" = test01 ] || { echo "not test01: refusing" >&2; exit 2; }
        B=$(mktemp -d /tmp/asyla-build.XXXXXX)
        trap "rm -rf $B" EXIT
        tar -xzf - -C "$B"
        sudo HOST_SPEC="$B/test01/host.toml" bash "$B/build/setup/node_exporter.sh"' || exit 1
  fi
  "${SSH[@]}" '
      set -e
      [ "$(hostname -s)" = test01 ] || { echo "not test01: refusing" >&2; exit 2; }
      F=$(mktemp /tmp/node-exporter-test.XXXXXX)
      cat > "$F"
      trap "rm -f $F" EXIT
      bash "$F" --on-host' < "$REPO/scripts/tests/test_node_exporter_test01.sh"
  host_rc=$?

  # From the workstation: the unit's address filter.
  fails=0
  ws=$("${SSH[@]}" 'echo ${SSH_CLIENT%% *}')
  ip=$("${SSH[@]}" 'hostname -I | cut -d" " -f1')
  answers() { curl -fsS -m 5 -o /dev/null "http://$ip:9100/metrics"; }
  ws_check() {
    if [ "$2" = yes ]; then answers && r=PASS || r=FAIL; else answers && r=FAIL || r=PASS; fi
    [ "$r" = PASS ] || fails=$((fails + 1))
    echo "[$r] $1"
  }
  echo "== address filter, from the workstation ($ws) to $ip:9100"
  ws_check "not answered: the workstation is not in allow" no
  "${SSH[@]}" "sudo systemctl set-property --runtime prometheus-node-exporter IPAddressAllow=$ws"
  ws_check "answered with the workstation allowed at runtime" yes
  # A running unit keeps its address filter until it restarts (test01, 2026-10-27: a daemon-reload
  # alone left the workstation answered); node_exporter.sh restarts it after any change.
  "${SSH[@]}" 'sudo rm -f /run/systemd/system.control/prometheus-node-exporter.service.d/*IPAddress*.conf &&
               sudo systemctl daemon-reload && sudo systemctl restart prometheus-node-exporter && sleep 1
               systemctl show -p IPAddressAllow --value prometheus-node-exporter'
  ws_check "not answered again once that is removed (and the exporter restarted)" no
  echo "== workstation: $fails failure(s); test01: exit $host_rc"
  [ "$fails" -eq 0 ] && [ "$host_rc" -eq 0 ]
  exit $?
fi

# ---- on test01 ----
[ "$(hostname -s)" = test01 ] || { echo "not test01: refusing" >&2; exit 2; }
NAS=10.0.0.24
DIR=/var/lib/node_exporter/textfile_collector
LIST=/etc/asyla/textfile-sources
SMART=/mnt/nas/data1/docker/nas01-smart/smart.prom
UNIT=asyla-textfile-sources.service
TABLE=asyla_node_exporter_test
T=$(mktemp -d /tmp/ne-test.XXXXXX)
sudo cp -p "$LIST" "$T/list.saved"
sudo systemctl stop asyla-textfile-sources.timer   # each run below is the test's own

cleanup() {
  sudo -n nft delete table inet "$TABLE" 2>/dev/null
  sudo cp "$T/list.saved" "$LIST"
  sudo rm -f "$DIR/good.prom" "$DIR/fifo.prom" "$DIR/missing.prom"
  sudo systemctl start "$UNIT" asyla-textfile-sources.timer
  echo "cleanup: nft table $TABLE: $(sudo -n nft list table inet "$TABLE" >/dev/null 2>&1 && echo present || echo gone); list restored: $(sudo cmp -s "$T/list.saved" "$LIST" && echo yes || echo NO)"
  rm -rf "$T"
}
trap cleanup EXIT

fails=0
check() {   # check LABEL CONDITION-EXIT
  if [ "$2" -eq 0 ]; then echo "[PASS] $1"; else echo "[FAIL] $1"; fails=$((fails + 1)); fi
}
scrape() { curl -fsS -m 5 http://127.0.0.1:9100/metrics; }
run_copy() {   # run the copy once; prints its run time in seconds
  local s e
  s=$(date +%s.%N); sudo systemctl start "$UNIT"; e=$(date +%s.%N)
  awk -v s="$s" -v e="$e" 'BEGIN { printf "%.1f", e - s }'
}

echo "== installed"
systemctl is-active --quiet prometheus-node-exporter; check "prometheus-node-exporter active" $?
[ "$(systemctl is-enabled asyla-textfile-sources.timer)" = enabled ]; check "asyla-textfile-sources.timer enabled (held during the test)" $?
deny=$(systemctl show -p IPAddressDeny --value prometheus-node-exporter)
allow=$(systemctl show -p IPAddressAllow --value prometheus-node-exporter)
echo "  IPAddressDeny=$deny IPAddressAllow=$allow"
[[ "$deny" == *0.0.0.0/0* && "$allow" == *10.0.0.150* ]]; check "address filter: deny any, allow 10.0.0.150" $?
dpkg-query -W -f='${Version}\n' prometheus-node-exporter
[ "$(dpkg-query -W -f='${db:Status-Status}' prometheus-node-exporter-collectors 2>/dev/null)" != installed ]; check "recommends not installed (prometheus-node-exporter-collectors)" $?

echo "== served"
run_copy >/dev/null
scrape > "$T/m"; check "scrape answers on localhost" $?
grep -qx 'node_textfile_scrape_error 0' "$T/m"; check "every textfile parses (node_textfile_scrape_error 0)" $?
grep -q '^asyla_textfile_source_ok{file="smart.prom",.*} 1$' "$T/m"; check "smart.prom copied" $?
src_mtime=$(stat -c %Y "$SMART")
got=$(awk -F' ' '/^node_textfile_mtime_seconds\{file="\/var\/lib\/node_exporter\/textfile_collector\/smart.prom"\}/ { printf "%d", $2 }' "$T/m")
[ "$got" = "$src_mtime" ]; check "smart.prom served with its source's mtime ($got vs $src_mtime)" $?
grep -q '^asyla_nfs_mount_up' "$T/m"; check "asyla_nfs.prom served too" $?
grep -q '^node_filesystem_size_bytes{.*mountpoint="/mnt/docker"' "$T/m"; check "filesystem: /mnt/docker in" $?
grep -q '^node_filesystem_size_bytes{.*mountpoint="/mnt/nas' "$T/m"; [ $? -ne 0 ]; check "filesystem: /mnt/nas out" $?
grep -q '^node_network_.*device="veth' "$T/m"; [ $? -ne 0 ]; check "network: no veth device" $?
echo "  series: $(grep -vc '^#' "$T/m") (smart.prom $(grep -vc '^#' "$DIR/smart.prom"))"

echo "== sources that fail"
mkfifo "$T/fifo.prom"
printf '# TYPE asyla_test_good gauge\nasyla_test_good 1\n' > "$T/good.prom"
printf '%s\n' "$SMART" "$T/fifo.prom" "$T/missing.prom" "$T/good.prom" | sudo tee "$LIST" >/dev/null
echo stale | sudo tee "$DIR/missing.prom" >/dev/null   # a copy left from before: must go
since=$(date '+%Y-%m-%d %H:%M:%S')
took=$(run_copy)
awk -v t="$took" 'BEGIN { exit !(t < 15) }'; check "copy run ends within its limit with a FIFO in the list (${took}s)" $?
scrape > "$T/m"
grep -q '^asyla_textfile_source_ok{file="fifo.prom",.*} 0$' "$T/m"; check "FIFO: ok 0" $?
[ ! -e "$DIR/missing.prom" ]; check "missing source: its copy removed" $?
grep -q '^asyla_textfile_source_ok{file="good.prom",.*} 1$' "$T/m" && grep -qx 'asyla_test_good 1' "$T/m"; check "good source: copied and served" $?
grep -qx 'node_textfile_scrape_error 0' "$T/m"; check "still every textfile parses" $?
sleep 1
j=$(sudo journalctl -u "$UNIT" --since "$since" --no-pager -o cat)
grep -q 'TEXTFILE_SOURCE_DOWN file=fifo.prom .*reason=no_answer' <<<"$j"; check "journal: fifo.prom DOWN no_answer" $?
grep -q 'TEXTFILE_SOURCE_DOWN file=missing.prom .*reason=missing' <<<"$j"; check "journal: missing.prom DOWN missing" $?
pgrep -f "cp --preserve=timestamps -- $T/fifo.prom" >/dev/null; [ $? -ne 0 ]; check "no reader left behind" $?
sudo cp "$T/list.saved" "$LIST"
sudo rm -f "$DIR/good.prom" "$DIR/fifo.prom"

echo "== the NAS not answering (about 45 s)"
before=$(sha256sum < "$DIR/smart.prom")
sudo nft add table inet "$TABLE"
sudo nft add chain inet "$TABLE" out '{ type filter hook output priority 0; }'
sudo nft add rule inet "$TABLE" out ip daddr "$NAS" drop
dropped=$(date +%s)
sudo sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null   # no cached answer for the source
took=$(run_copy)
awk -v t="$took" 'BEGIN { exit !(t < 15) }'; check "copy run ends within its limit with the NAS away (${took}s)" $?
s=$(date +%s.%N); scrape > "$T/m"; rc=$?; e=$(date +%s.%N)
st=$(awk -v s="$s" -v e="$e" 'BEGIN { printf "%.2f", e - s }')
[ $rc -eq 0 ] && awk -v t="$st" 'BEGIN { exit !(t < 3) }'; check "scrape answers at once meanwhile (${st}s)" $?
grep -q '^asyla_textfile_source_ok{file="smart.prom",.*} 0$' "$T/m"; check "smart.prom: ok 0" $?
[ "$(sha256sum < "$DIR/smart.prom")" = "$before" ]; check "smart.prom: last copy kept" $?
left=$((45 - ($(date +%s) - dropped))); [ "$left" -le 0 ] || sleep "$left"
sudo nft delete table inet "$TABLE"
for i in $(seq 30); do timeout 5 stat -f "$(dirname "$SMART")" >/dev/null 2>&1 && break; sleep 2; done
run_copy >/dev/null
scrape > "$T/m"
grep -q '^asyla_textfile_source_ok{file="smart.prom",.*} 1$' "$T/m"; check "after the NAS is back: smart.prom copied" $?
j=$(sudo journalctl -u "$UNIT" --since "@$dropped" --no-pager -o cat)
grep -q 'TEXTFILE_SOURCE_UP file=smart.prom' <<<"$j"; check "journal: smart.prom UP" $?

echo "== test01: $fails failure(s)"
[ "$fails" -eq 0 ]
