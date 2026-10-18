#!/bin/bash
# Free port 53 for a DNS server container on the host network (Pi-hole on ns01/ns02): turn off
# systemd-resolved's stub listener (127.0.0.53:53) and any host dnsmasq, then check that nothing
# listens on port 53. From ns0x/setup/systemConfig.sh's port-53 block (asyla-hosts 9551f14).
# Run as root by the build (build_host.py setup phase), before the app starts. Idempotent: the
# drop-in is written once, and each step only acts on what is still there.
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "[ERROR] run as root" >&2; exit 1; }

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    DROPIN=/etc/systemd/resolved.conf.d/no-stub.conf
    if [ ! -f "$DROPIN" ]; then
        install -d -m 755 "$(dirname "$DROPIN")"
        printf '%s\n' '[Resolve]' 'DNSStubListener=no' > "$DROPIN"
        echo "[INFO] $DROPIN written"
    fi
    # The stub file names 127.0.0.53, which no longer answers: the host uses the real servers.
    if [ "$(readlink /etc/resolv.conf 2>/dev/null)" != /run/systemd/resolve/resolv.conf ]; then
        ln -sfn /run/systemd/resolve/resolv.conf /etc/resolv.conf
        echo "[INFO] /etc/resolv.conf -> /run/systemd/resolve/resolv.conf"
    fi
    systemctl restart systemd-resolved
fi

if systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -q '^dnsmasq\.service'; then
    systemctl disable --now dnsmasq
    echo "[INFO] host dnsmasq.service stopped and disabled"
fi

listeners=$(ss -Hlntup 'sport = :53' 2>/dev/null || true)
if [ -n "$listeners" ]; then
    echo "[ERROR] port 53 is still in use on the host:" >&2
    echo "$listeners" >&2
    exit 1
fi
echo "[INFO] port 53 is free for the DNS container"
