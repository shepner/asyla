#!/bin/sh
# vmh03: standalone Proxmox VE 9 host (not in cluster vmc01) that holds vmc01's third quorum vote
# with corosync-qnetd (asyla decision vmc01-quorum-third-vote). Runs as root on vmh03, piped from
# the workstation by vmh03/apply.sh; idempotent. Modes:
#   check                  read-only: hardware facts and the state below; non-zero if anything is off
#   setup                  apt repos as vmh02 has them, the TCP 5403 rule, corosync-qnetd; then check
#   add-setup-key B64      authorize vmh01's root key (ssh-rsa B64) for `pvecm qdevice setup`
#   remove-setup-key [B64] remove that key again (the decision's step 8)
set -eu

HOST=vmh03
ADDRESS=10.0.0.37
NODES="10.0.0.35, 10.0.0.36"   # vmh01, vmh02: the only sources allowed on TCP 5403
PORT=5403
NFT=/etc/asyla/qnetd.nft
UNIT=/etc/systemd/system/asyla-qnetd-firewall.service
KEY_MARK=asyla-qdevice-setup-vmh01
AUTH=/root/.ssh/authorized_keys
SOURCES=/etc/apt/sources.list.d

say() { printf '%s\n' "$*"; }
die() { printf 'vmh03 setup: %s\n' "$*" >&2; exit 1; }

# install_file DEST MODE: write stdin to DEST only if it differs; sets CHANGED=1 when it writes.
install_file() {
    tmp=$(mktemp)
    cat >"$tmp"
    if [ -f "$1" ] && cmp -s "$tmp" "$1"; then
        rm -f "$tmp"; say "ok      $1"; return 0
    fi
    mkdir -p "$(dirname "$1")"
    install -m "$2" "$tmp" "$1"; rm -f "$tmp"
    CHANGED=1; say "changed $1"
}

# disable_sources FILE: every deb822 stanza in FILE gets "Enabled: false" (as vmh02 has it).
disable_sources() {
    awk '
        /^Enabled:/ { next }
        /^[[:space:]]*$/ { if (open) print "Enabled: false"; open = 0; print; next }
        { open = 1; print }
        END { if (open) print "Enabled: false" }
    ' "$1" | install_file "$1" 644
}

repos() {
    install_file "$SOURCES/proxmox.sources" 644 <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    # No subscription, and no Ceph on this host.
    for f in "$SOURCES/pve-enterprise.sources" "$SOURCES/ceph.sources"; do
        if [ -f "$f" ]; then disable_sources "$f"; fi
    done
    apt-get update -q
}

firewall() {
    command -v nft >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -q nftables
    CHANGED=0
    install_file "$NFT" 644 <<EOF
# asyla-hosts vmh03/setup.sh: corosync-qnetd (TCP $PORT) answers only vmh01 and vmh02.
# Its own table, so pve-firewall and anything else keep theirs; the first two lines make a reload atomic.
table inet asyla_qnetd
delete table inet asyla_qnetd
table inet asyla_qnetd {
    chain input {
        type filter hook input priority filter; policy accept;
        tcp dport $PORT ip saddr { $NODES } accept
        tcp dport $PORT drop
    }
}
EOF
    rules=$CHANGED
    CHANGED=0
    install_file "$UNIT" 644 <<EOF
[Unit]
Description=asyla: TCP $PORT (corosync-qnetd) only from vmh01 and vmh02
Wants=network-pre.target
Before=network-pre.target corosync-qnetd.service shutdown.target
Conflicts=shutdown.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $NFT
ExecReload=/usr/sbin/nft -f $NFT
ExecStop=/usr/sbin/nft delete table inet asyla_qnetd

[Install]
WantedBy=sysinit.target
EOF
    if [ "$CHANGED" = 1 ]; then systemctl daemon-reload; fi
    systemctl enable -q asyla-qnetd-firewall.service
    if [ "$rules" = 1 ] || [ "$CHANGED" = 1 ] || ! systemctl -q is-active asyla-qnetd-firewall.service; then
        systemctl reload-or-restart asyla-qnetd-firewall.service
        say "changed asyla-qnetd-firewall.service (re)loaded"
    else
        say "ok      asyla-qnetd-firewall.service"
    fi
}

qnetd() {
    if dpkg-query -W -f='${Status}' corosync-qnetd 2>/dev/null | grep -q 'install ok installed'; then
        say "ok      corosync-qnetd installed"
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q corosync-qnetd
        say "changed corosync-qnetd installed"
    fi
    systemctl enable -q --now corosync-qnetd.service
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
    say "== ssh host keys (compare when vmh01 asks during pvecm qdevice setup)"
    for k in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
        if [ -f "$k" ]; then ssh-keygen -lf "$k"; fi
    done
    say "== state"
    ip -4 -o addr show | grep -q " $ADDRESS/24 " || flag "$ADDRESS/24 not on any interface"
    for f in "$SOURCES/pve-enterprise.sources" "$SOURCES/ceph.sources"; do
        [ -f "$f" ] || continue
        if awk '/^Types:/ { n++ } /^Enabled: false/ { d++ } END { exit !(n == d) }' "$f"; then
            say "ok      $f disabled"
        else
            flag "$f has an enabled stanza"
        fi
    done
    [ -f "$SOURCES/proxmox.sources" ] && say "ok      $SOURCES/proxmox.sources present" \
        || flag "$SOURCES/proxmox.sources missing"
    for u in asyla-qnetd-firewall.service corosync-qnetd.service; do
        if systemctl -q is-active "$u" && systemctl -q is-enabled "$u"; then
            say "ok      $u active and enabled"
        else
            flag "$u not active and enabled"
        fi
    done
    if nft list table inet asyla_qnetd >/dev/null 2>&1; then nft list table inet asyla_qnetd
    else flag "nft table inet asyla_qnetd missing"; fi
    ss -Htln "sport = :$PORT" | grep -q . && say "ok      listening on TCP $PORT" \
        || flag "nothing listening on TCP $PORT"
    if command -v corosync-qnetd-tool >/dev/null; then
        apt-cache policy corosync-qnetd | sed -n '1,3p'
        corosync-qnetd-tool -s || flag "corosync-qnetd-tool -s failed"
        corosync-qnetd-tool -l || true
    fi
    if grep -q "$KEY_MARK" "$AUTH" 2>/dev/null; then
        say "note    vmh01's setup key is authorized ($KEY_MARK); remove it after pvecm qdevice setup"
    else
        say "ok      no setup key authorized"
    fi
    [ "$bad" = 0 ] || die "check found problems (FAIL lines above)"
    say "check: all ok"
}

b64_ok() { printf '%s' "$1" | grep -Eq '^AAAA[A-Za-z0-9+/]+=*$'; }

add_setup_key() {
    b64_ok "${1:-}" || die "add-setup-key needs vmh01's ssh-rsa key body (base64)"
    if grep -qF "$1" "$AUTH" 2>/dev/null; then
        say "ok      vmh01's key already in $AUTH"
    else
        # Appends through the PVE symlink to /etc/pve/priv/authorized_keys.
        printf 'ssh-rsa %s %s\n' "$1" "$KEY_MARK" >>"$AUTH"
        say "changed vmh01's key added to $AUTH ($KEY_MARK)"
    fi
}

remove_setup_key() {
    [ -z "${1:-}" ] || b64_ok "$1" || die "remove-setup-key: not a key body"
    tmp=$(mktemp)
    if [ -n "${1:-}" ]; then
        grep -vF -e "$KEY_MARK" -e "$1" "$AUTH" >"$tmp" || true
    else
        grep -vF -e "$KEY_MARK" "$AUTH" >"$tmp" || true
    fi
    if cmp -s "$tmp" "$AUTH"; then
        say "ok      no setup key in $AUTH"
    else
        cat "$tmp" >"$AUTH"   # write through the symlink, not over it
        say "changed setup key removed from $AUTH"
    fi
    rm -f "$tmp"
}

[ "$(id -u)" = 0 ] || die "run as root"
[ "$(hostname -s)" = "$HOST" ] || die "this is $(hostname -s), not $HOST"
command -v pveversion >/dev/null || die "not a Proxmox VE host"

case "${1:-check}" in
    check) check ;;
    setup) repos; firewall; qnetd; check ;;
    add-setup-key) add_setup_key "${2:-}" ;;
    remove-setup-key) remove_setup_key "${2:-}" ;;
    *) die "unknown mode ${1}: check | setup | add-setup-key B64 | remove-setup-key [B64]" ;;
esac
