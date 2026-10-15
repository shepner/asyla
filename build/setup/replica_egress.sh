#!/usr/bin/env bash
# Replica egress block (build_host.py, apps phase of a [replica] spec, before any app starts).
# A replica runs a production host's apps on restored data (secrets included), so nothing on it
# may write outward: mirrors, webhooks, mail, update checks, runners. nftables table
# inet asyla_replica_egress:
#   output:  lo, established/related, the host's own containers (docker0, br-*), the LAN, ICMPv6
#            (neighbour discovery); everything else is dropped.
#   forward: established/related and traffic into the containers (published ports); everything
#            else is dropped, so a container reaches nothing off the host, the LAN included.
# A oneshot unit (Before=docker.service) loads it at every boot. Idempotent: the table is
# replaced as a whole. Run as root. REPLICA_LAN overrides the LAN (default 10.0.0.0/24).
set -euo pipefail

LAN="${REPLICA_LAN:-10.0.0.0/24}"
RULES=/etc/asyla/replica-egress.nft
UNIT=asyla-replica-egress.service

[ "$(id -u)" -eq 0 ] || { echo "[ERROR] $0: run as root" >&2; exit 1; }
[[ "$LAN" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || { echo "[ERROR] REPLICA_LAN '$LAN' is not a CIDR" >&2; exit 1; }

if ! command -v nft >/dev/null 2>&1; then
    echo "[INFO] Installing nftables"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables >/dev/null
fi
NFT=$(command -v nft)

install -d -m 755 /etc/asyla
tmp=$(mktemp "$RULES.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
# asyla replica egress block (build/setup/replica_egress.sh in asyla-hosts); do not edit here.
table inet asyla_replica_egress
delete table inet asyla_replica_egress
table inet asyla_replica_egress {
    chain output {
        type filter hook output priority 0; policy drop;
        oifname "lo" accept
        ct state established,related accept
        oifname "docker0" accept
        oifname "br-*" accept
        ip daddr $LAN accept
        meta l4proto ipv6-icmp accept
        counter comment "dropped: off the LAN"
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
        oifname "docker0" accept
        oifname "br-*" accept
        counter comment "dropped: a container going off the host"
    }
}
EOF
"$NFT" -c -f "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$RULES"
trap - EXIT

cat > "/etc/systemd/system/$UNIT" <<EOF
[Unit]
Description=asyla replica egress block (LAN and established only)
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$NFT -f $RULES

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$UNIT" >/dev/null 2>&1
"$NFT" -f "$RULES"
systemctl start "$UNIT"
"$NFT" list table inet asyla_replica_egress >/dev/null
echo "[INFO] Replica egress block in place: LAN $LAN, established and the host's containers only ($UNIT enabled)"
