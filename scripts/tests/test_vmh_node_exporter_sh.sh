#!/bin/bash
# vmh/setup.sh part node_exporter (asyla #610 step 5): Debian's prometheus-node-exporter on :9100 for
# d06's asyla-hw job, TCP 9100 only from 10.0.0.0/24 (an nft table, as netconsole-rx), the textfile
# collector on /var/lib/prometheus/node-exporter. The part and check() run here as functions
# extracted from setup.sh, with their /etc and /var paths under a temp dir and stand-in apt-get,
# dpkg-query, nft, systemctl, ss and curl first in PATH: no root, nothing reaches a node.
# Run: bash scripts/tests/test_vmh_node_exporter_sh.sh   (also under dash when installed: the nodes' sh)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$REPO/vmh/setup.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }
expect() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "want [$2] got [$3]"; fi; }

# ---- the part list: setup, check and the unknown-part message all name node_exporter, after health
for what in 'cparts=" ${*:-' 'parts=${*:-' 'unknown part $p ('; do
    line=$(grep -F "$what" "$SETUP" | head -1)
    case "$line" in *"health node_exporter swap"*) ok "part list ($what): health node_exporter swap" ;;
        *) bad "part list ($what)" "$line" ;; esac
done
grep -qF 'node_exporter) part_node_exporter ;;' "$SETUP" && ok "setup dispatches node_exporter" \
    || bad "setup dispatches node_exporter"

# ---- extract: the node_exporter block, the helpers it uses, and check()
awk '/^# ---- node_exporter/ { on = 1 } /^# ---- swap/ { on = 0 } on' "$SETUP" >"$T/ne.sh"
for f in installed install_file reset_changed changed apt_install; do
    awk -v f="$f" '$0 ~ "^" f "\\(\\) \\{" { on = 1 } on { print } on && /^\}/ { exit }' "$SETUP" >>"$T/ne.sh"
done
awk '/^check\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$SETUP" >>"$T/ne.sh"
grep -q '^part_node_exporter() {' "$T/ne.sh" && grep -q '^check() {' "$T/ne.sh" && grep -q '^ne_nft_body() {' "$T/ne.sh" \
    || { echo "FAIL extracting part_node_exporter, ne_nft_body and check from setup.sh"; exit 1; }
# Paths under the temp dir; the variable names stay, so the drop-in and nft file name the moved paths.
sed -i.bak -e "s#^NE_NFT=/etc/#NE_NFT=$T/root/etc/#" -e "s#^NE_DROPIN=/etc/#NE_DROPIN=$T/root/etc/#" \
    -e "s#^NE_TEXTFILE=/var/#NE_TEXTFILE=$T/root/var/#" "$T/ne.sh"
grep -q "^NE_NFT=$T/" "$T/ne.sh" && grep -q "^NE_DROPIN=$T/" "$T/ne.sh" && grep -q "^NE_TEXTFILE=$T/" "$T/ne.sh" \
    || { echo "FAIL moving NE_* paths under the temp dir"; exit 1; }

# ---- stand-ins: each logs "NAME ARGS" to $T/log; state in $T/state
mkdir -p "$T/bin" "$T/state" "$T/root"
stub() { printf '#!/bin/sh\necho "%s $*" >>"%s/log"\n%s\n' "$1" "$T" "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }
stub dpkg-query "[ \"\$3\" = nftables ] && { printf 'install ok installed'; exit 0; }
[ -e $T/state/installed ] && { printf 'install ok installed'; exit 0; }; exit 1"
stub apt-get ": >$T/state/installed"
stub nft "case \"\$1\" in -f) : >$T/state/table ;; list) [ -e $T/state/table ] ;; esac"
stub systemctl "case \"\$*\" in *is-active*) [ -e $T/state/active ] ;; *restart*) : >$T/state/active ;; esac"
stub ss "[ -e $T/state/active ] && echo 'LISTEN 0 4096 *:9100 *:*'; exit 0"
stub curl "[ -e $T/state/active ] || exit 7
printf '%s\n' '# HELP node_textfile_scrape_error x' \"node_textfile_scrape_error \${FAKE_TF_ERR:-0}\"
[ -n \"\${FAKE_HW:-}\" ] && echo 'asyla_hw_check_last_run_timestamp_seconds{host=\"vmh03\",checker=\"vmh-health\"} 1'
exit 0"

sh_bin=$(command -v dash || echo /bin/sh)
run() {   # run COMMAND...: in the nodes' sh, the extracted functions loaded; sets rc, out
    rm -f "$T/log"
    out=$(PATH="$T/bin:$PATH" "$sh_bin" -c '
        set -eu
        say() { printf "%s\n" "$*"; }
        die() { printf "vmh setup: %s\n" "$*" >&2; exit 1; }
        MARK=$1/mark BADMARK=$1/badmark node=vmh03 ROLE=canary
        . "$1/ne.sh"
        shift
        "$@"' sh "$T" "$@" 2>&1); rc=$?
    log=$(cat "$T/log" 2>/dev/null)
}
lineno() { printf '%s\n' "$log" | grep -nF -- "$1" | head -1 | cut -d: -f1; }

NFT="$T/root/etc/asyla/node-exporter.nft"
DROPIN="$T/root/etc/systemd/system/prometheus-node-exporter.service.d/asyla.conf"

# 1. A fresh node: nothing installed, no table, not running.
run part_node_exporter
expect "fresh: setup exits 0" "0" "$rc"
grep -qx '        tcp dport 9100 ip saddr 10.0.0.0/24 accept' "$NFT" && grep -qx '        tcp dport 9100 drop' "$NFT" \
    && grep -qx '        tcp dport 9100 iif lo accept' "$NFT" \
    && ok "nft: 9100 from lo and 10.0.0.0/24, else drop" || bad "nft rules" "$(cat "$NFT")"
expect "nft: replaces only its own table" "table inet asyla_node_exporter|delete table inet asyla_node_exporter" \
    "$(grep '^table inet\|^delete' "$NFT" | head -2 | paste -sd '|' -)"
grep -qx "ExecStart=/usr/bin/prometheus-node-exporter --web.listen-address=:9100 --collector.textfile.directory=$T/root/var/lib/prometheus/node-exporter" "$DROPIN" \
    && grep -qx 'ExecStart=' "$DROPIN" && grep -qx "ExecStartPre=+/usr/sbin/nft -f $NFT" "$DROPIN" \
    && grep -qx 'ExecStopPost=-+/usr/sbin/nft delete table inet asyla_node_exporter' "$DROPIN" \
    && ok "drop-in: :9100, the textfile dir, the table loaded before each start" || bad "drop-in" "$(cat "$DROPIN")"
grep -qF -- 'apt-get install -y -q --no-install-recommends prometheus-node-exporter' <<<"$log" \
    && ok "installs prometheus-node-exporter without recommends" || bad "apt-get" "$log"
nf=$(lineno "nft -f $NFT"); ap=$(lineno "apt-get install"); dr=$(lineno "systemctl daemon-reload")
[ -n "$nf" ] && [ -n "$ap" ] && [ -n "$dr" ] && [ "$dr" -lt "$ap" ] && [ "$nf" -lt "$ap" ] \
    && ok "table loaded and drop-in reloaded before the package's first start" || bad "order" "$log"
[ -d "$T/root/var/lib/prometheus/node-exporter" ] && ok "textfile dir exists" || bad "textfile dir"
grep -qF 'systemctl enable -q prometheus-node-exporter.service' <<<"$log" && grep -qF 'restart prometheus-node-exporter.service' <<<"$log" \
    && ok "enabled and (re)started" || bad "enable/restart" "$log"

# 2. Again: nothing changes, nothing restarts, nothing installs.
run part_node_exporter
if [ "$rc" = 0 ] && ! grep -q '^changed' <<<"$out" && ! grep -qF restart <<<"$log" && ! grep -qF apt-get <<<"$log"; then
    ok "idempotent: a second run changes nothing"; else bad "idempotent" "rc $rc, out: $out, log: $log"; fi
grep -qF "nft -f $NFT" <<<"$log" && ok "the table is (re)loaded on every run" || bad "nft reload" "$log"

# 3. A changed drop-in restarts; a stopped service restarts.
echo '# hand edit' >>"$DROPIN"
run part_node_exporter
grep -qF 'systemctl daemon-reload' <<<"$log" && grep -qF 'restart prometheus-node-exporter' <<<"$log" \
    && ok "a drifted drop-in is rewritten, reloaded and restarted" || bad "drifted drop-in" "$log"
rm -f "$T/state/active"
run part_node_exporter
grep -qF 'restart prometheus-node-exporter' <<<"$log" && ! grep -qF daemon-reload <<<"$log" \
    && ok "a stopped service is started" || bad "stopped service" "$log"

# 4. check node_exporter
run check node_exporter
[ "$rc" = 0 ] && grep -qF 'check: all ok' <<<"$out" && grep -qF 'note    ' <<<"$out" && grep -qF 'asyla-vmh-health.prom not written yet' <<<"$out" \
    && ok "check: all ok; notes the textfile not written yet" || bad "check ok" "rc $rc, $out"
: >"$T/root/var/lib/prometheus/node-exporter/asyla-vmh-health.prom"
FAKE_HW=1 run check node_exporter
[ "$rc" = 0 ] && grep -qF 'ok      asyla_hw_* served' <<<"$out" && ok "check: asyla_hw_* served once written" || bad "check served" "rc $rc, $out"
run check node_exporter
[ "$rc" != 0 ] && grep -qF 'FAIL    ' <<<"$out" && grep -qF 'does not serve asyla_hw_*' <<<"$out" \
    && ok "check: textfile written but not served fails" || bad "check not served" "rc $rc, $out"
FAKE_HW=1 FAKE_TF_ERR=1 run check node_exporter
[ "$rc" != 0 ] && grep -qF 'textfile collector' <<<"$out" && ok "check: a textfile scrape error fails" || bad "check tf err" "rc $rc, $out"
rm -f "$T/state/active" "$T/state/table"
FAKE_HW=1 run check node_exporter
[ "$rc" != 0 ] && grep -qF 'not active' <<<"$out" && grep -qF 'nothing listens on :9100' <<<"$out" \
    && grep -qF 'asyla_node_exporter missing' <<<"$out" && ok "check: down and unfiltered fails" || bad "check down" "rc $rc, $out"
echo '# hand edit' >>"$NFT"
run check node_exporter
grep -qF "$NFT differs from vmh/setup.sh" <<<"$out" && ok "check: a drifted nft file fails" || bad "check nft drift" "$out"
rm -f "$T/state/installed"
run check node_exporter
grep -qF 'prometheus-node-exporter not installed' <<<"$out" && ok "check: not installed fails" || bad "check not installed" "$out"
if grep -qE 'apt-get|restart|daemon-reload|nft -f|enable' <<<"$log"; then bad "check writes nothing" "$log"
else ok "check writes nothing (no apt-get, nft -f, enable or restart)"; fi

sh -n "$SETUP" && ok "sh -n vmh/setup.sh" || bad "sh -n vmh/setup.sh"
exit "$fail"
