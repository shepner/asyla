#!/bin/bash
# Port proxies: a host port that forwards to a container port published on loopback only, open to
# the listed addresses only. For a container theOrg's trends Prometheus scrapes (asyla standard
# ASY-TRD) on a host with no host firewall: a Docker-published port bypasses the host's INPUT rules,
# so the container publishes on 127.0.0.1 and this proxy is the only way in from the LAN.
#
# From this host's host.toml (HOST_SPEC), one table per proxy:
#   [[port_proxy]]
#   name = "switch-snmp"          # units asyla-proxy-NAME.socket and asyla-proxy-NAME.service
#   listen = 9116                 # the host port
#   target = "127.0.0.1:19116"    # the loopback-published container port
#   allow = ["10.0.0.150"]        # who may connect, besides localhost
#
# The port is limited to `allow` by the socket unit's IPAddressDeny=any / IPAddressAllow= (systemd
# BPF filter on the socket's listening and connection sockets, systemd.resource-control(5)), as
# node_exporter.sh limits 9100; no host firewall rule. systemd-socket-proxyd (in systemd) runs on
# the first connection, as a dynamic user, and may connect to localhost only. A proxy dropped from
# host.toml has its units stopped and removed.
#
# --units DIR: write the unit files into DIR and stop (no root, no systemctl; for tests).

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

UNIT_DIR=/etc/systemd/system
ONLY_UNITS=""
if [ "${1:-}" = "--units" ]; then
    UNIT_DIR="${2:?--units needs a directory}"
    ONLY_UNITS=1
elif [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

SPEC="${HOST_SPEC:?HOST_SPEC must name the host.toml of this host}"
[ -f "$SPEC" ] || { log_error "HOST_SPEC $SPEC is not a file"; exit 1; }
PROXYD=/usr/lib/systemd/systemd-socket-proxyd

# [[port_proxy]] from the spec, checked: one "NAME LISTEN TARGET ALLOW,ALLOW" line each.
spec_lines=$(python3 - "$SPEC" <<'PY'
import ipaddress, re, sys, tomllib
proxies = tomllib.load(open(sys.argv[1], "rb")).get("port_proxy")
if not isinstance(proxies, list) or not proxies:
    sys.exit(f"{sys.argv[1]}: no [[port_proxy]] tables")
names, ports = set(), set()
for p in proxies:
    unknown = set(p) - {"name", "listen", "target", "allow"}
    if unknown:
        sys.exit(f"[[port_proxy]]: unknown keys {sorted(unknown)}")
    name, listen, target, allow = p.get("name"), p.get("listen"), p.get("target"), p.get("allow")
    if not (isinstance(name, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,30}", name)) or name in names:
        sys.exit(f"[[port_proxy]] name {name!r}: lower-case letters, digits and -, unique")
    if not (isinstance(listen, int) and not isinstance(listen, bool) and 1 <= listen <= 65535) or listen in ports:
        sys.exit(f"[[port_proxy]] {name}: listen must be a port, unique on the host")
    m = re.fullmatch(r"127\.0\.0\.1:(\d{1,5})", target) if isinstance(target, str) else None
    if not m or not 1 <= int(m[1]) <= 65535 or int(m[1]) == listen:
        sys.exit(f"[[port_proxy]] {name}: target must be 127.0.0.1:PORT (loopback only), not the listen port")
    if not isinstance(allow, list) or not allow:
        sys.exit(f"[[port_proxy]] {name}: allow must list at least one address")
    for a in allow:
        try:
            ipaddress.ip_network(a, strict=True)
        except (TypeError, ValueError):
            sys.exit(f"[[port_proxy]] {name} allow: {a!r} is not an address or prefix")
    names.add(name); ports.add(listen)
    print(name, listen, target, ",".join(allow))
PY
) || { log_error "Bad [[port_proxy]] in $SPEC"; exit 1; }

mkdir -p "$UNIT_DIR"
wanted=""
while read -r name listen target allow; do
    unit="asyla-proxy-$name"
    wanted="$wanted $unit"
    log_info "Writing $unit.socket (port $listen from localhost and: ${allow//,/ }) -> $target..."
    {
        echo "# Written by asyla-hosts build/setup/port_proxy.sh from host.toml [[port_proxy]] $name."
        echo "[Unit]"
        echo "Description=asyla port proxy $name: :$listen to $target"
        echo ""
        echo "[Socket]"
        echo "ListenStream=$listen"
        echo "IPAddressDeny=any"
        echo "IPAddressAllow=localhost"
        for a in ${allow//,/ }; do echo "IPAddressAllow=$a"; done
        echo ""
        echo "[Install]"
        echo "WantedBy=sockets.target"
    } > "$UNIT_DIR/$unit.socket.new"
    {
        echo "# Written by asyla-hosts build/setup/port_proxy.sh from host.toml [[port_proxy]] $name."
        echo "[Unit]"
        echo "Description=asyla port proxy $name: :$listen to $target"
        echo "Requires=$unit.socket"
        echo "After=$unit.socket"
        echo ""
        echo "[Service]"
        echo "ExecStart=$PROXYD --connections-max=16 $target"
        echo "DynamicUser=yes"
        echo "PrivateTmp=yes"
        echo "PrivateDevices=yes"
        echo "ProtectSystem=strict"
        echo "ProtectHome=yes"
        echo "NoNewPrivileges=yes"
        echo "CapabilityBoundingSet="
        echo "RestrictAddressFamilies=AF_INET AF_INET6"
        echo "IPAddressDeny=any"
        echo "IPAddressAllow=localhost"
    } > "$UNIT_DIR/$unit.service.new"
    mv -f "$UNIT_DIR/$unit.socket.new" "$UNIT_DIR/$unit.socket"
    mv -f "$UNIT_DIR/$unit.service.new" "$UNIT_DIR/$unit.service"
done <<<"$spec_lines"

[ -z "$ONLY_UNITS" ] || exit 0

[ -x "$PROXYD" ] || { log_error "$PROXYD not found (part of systemd)"; exit 1; }

# A proxy no longer in host.toml: stop and remove its units.
for f in "$UNIT_DIR"/asyla-proxy-*.socket; do
    [ -e "$f" ] || continue
    unit=$(basename "$f" .socket)
    case " $wanted " in *" $unit "*) continue ;; esac
    log_info "Removing $unit (not in host.toml)..."
    systemctl disable --now "$unit.socket" 2>/dev/null || true
    systemctl stop "$unit.service" 2>/dev/null || true
    rm -f "$UNIT_DIR/$unit.socket" "$UNIT_DIR/$unit.service"
done

systemctl daemon-reload
for unit in $wanted; do
    systemctl enable "$unit.socket"
    # A changed allow list or port takes effect now. The proxy goes first (systemd refuses to start a
    # socket whose service still runs); open connections drop, and the next one starts it again.
    systemctl stop "$unit.service"
    systemctl restart "$unit.socket"
done

# Check: each socket is listening with its filter set. The target container may not be up yet
# (a fresh build starts apps later), so the path through is checked by build_host.py verify.
while read -r name listen target allow; do
    unit="asyla-proxy-$name"
    systemctl is-active --quiet "$unit.socket" || { log_error "$unit.socket is not active"; exit 1; }
    [ "$(systemctl show -p IPAddressDeny --value "$unit.socket")" != "" ] || { log_error "$unit.socket has no IPAddressDeny"; exit 1; }
    ss -ltnH "sport = :$listen" | grep -q . || { log_error "nothing listens on port $listen"; exit 1; }
    log_info "$unit.socket listening on $listen, filtered"
done <<<"$spec_lines"
