#!/bin/sh
# vmh03: the third member of cluster vmc01 since 2026-10-23 (asyla decision vmc01-quorum-third-vote,
# L3), and the testbed and canary. Its shared node configuration is vmh/setup.sh; this file keeps the
# facts check and the removal of the qnetd role it held before the join. Runs as root on vmh03, piped
# from the workstation by vmh03/apply.sh; idempotent. Modes:
#   check          read-only: hardware facts, ssh host keys, no qnetd left; non-zero if anything is off
#   remove-qnetd   purge corosync-qnetd, its nft table inet asyla_qnetd, firewall unit and files; then check
set -eu

HOST=vmh03
ADDRESS=10.0.0.37
NFT=/etc/asyla/qnetd.nft
UNIT=/etc/systemd/system/asyla-qnetd-firewall.service
KEY_MARK=asyla-qdevice-setup-vmh01   # the old setup key's comment; never added (no qdevice was set up)
AUTH=/root/.ssh/authorized_keys

say() { printf '%s\n' "$*"; }
die() { printf 'vmh03 setup: %s\n' "$*" >&2; exit 1; }

installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

remove_qnetd() {
    # The daemon first, then its firewall: 5403 is never open to the LAN while qnetd listens.
    if dpkg-query -W -f='${Status}' corosync-qnetd 2>/dev/null | grep -q 'ok installed\|config-files'; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -q corosync-qnetd
        say "changed corosync-qnetd purged"
    else
        say "ok      corosync-qnetd not installed"
    fi
    if [ -f "$UNIT" ]; then
        systemctl disable -q --now asyla-qnetd-firewall.service || true
        rm -f "$UNIT"; systemctl daemon-reload
        say "changed asyla-qnetd-firewall.service removed"
    else
        say "ok      asyla-qnetd-firewall.service absent"
    fi
    if nft list table inet asyla_qnetd >/dev/null 2>&1; then
        nft delete table inet asyla_qnetd; say "changed nft table inet asyla_qnetd deleted"
    else
        say "ok      nft table inet asyla_qnetd absent"
    fi
    if [ -f "$NFT" ]; then rm -f "$NFT"; say "changed $NFT removed"; else say "ok      $NFT absent"; fi
    rmdir /etc/asyla 2>/dev/null || true
    # Left for review, not removed here: what corosync-qnetd pulled in (libnss3-tools, auto).
    r=$(apt-get -s autoremove 2>/dev/null | sed -n 's/^Remv \([^ ]*\).*/\1/p' | tr '\n' ' ')
    [ -z "$r" ] || say "note    apt autoremove would remove: $r(not run)"
}

check() {
    bad=0
    flag() { say "FAIL    $*"; bad=1; }
    say "== facts"
    lscpu | grep -E '^(Model name|CPU\(s\)|Thread|Core|Socket|Virtualization):' || true
    say "vmx flags: $(grep -c vmx /proc/cpuinfo || true)"
    free -g
    lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINTS
    pveversion
    ip -br addr show scope global
    ip route show default
    say "== ssh host keys"
    for k in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
        if [ -f "$k" ]; then ssh-keygen -lf "$k"; fi
    done
    say "== state"
    ip -4 -o addr show | grep -q " $ADDRESS/24 " || flag "$ADDRESS/24 not on any interface"
    installed corosync-qnetd && flag "corosync-qnetd still installed (remove-qnetd)" || say "ok      no corosync-qnetd"
    [ -f "$UNIT" ] && flag "$UNIT still present (remove-qnetd)" || say "ok      no asyla-qnetd-firewall.service"
    nft list table inet asyla_qnetd >/dev/null 2>&1 && flag "nft table inet asyla_qnetd still loaded (remove-qnetd)" \
        || say "ok      no nft table inet asyla_qnetd"
    grep -q "$KEY_MARK" "$AUTH" 2>/dev/null && flag "$AUTH still has the qdevice setup key ($KEY_MARK)" \
        || say "ok      no qdevice setup key"
    [ "$bad" = 0 ] || die "check found problems (FAIL lines above)"
    say "check: all ok (the node configuration itself: vmh/apply.sh check vmh03)"
}

[ "$(id -u)" = 0 ] || die "run as root"
[ "$(hostname -s)" = "$HOST" ] || die "this is $(hostname -s), not $HOST"
command -v pveversion >/dev/null || die "not a Proxmox VE host"

case "${1:-check}" in
    check) check ;;
    remove-qnetd) remove_qnetd; check ;;
    *) die "unknown mode ${1}: check | remove-qnetd" ;;
esac
