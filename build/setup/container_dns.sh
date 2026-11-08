#!/bin/bash
# A container never gets a loopback address for a LAN name: systemd-resolved stops answering from
# /etc/hosts (ReadEtcHosts=no). Programs on the host still read /etc/hosts themselves (nsswitch
# "hosts: files ..." comes first), so the host's own lookups do not change.
#
# Why. Cloud-init writes "127.0.1.1 dNN.asyla.org dNN" into /etc/hosts at every boot (Proxmox's
# user-data has manage_etc_hosts: true; the template is /etc/cloud/templates/hosts.debian.tmpl).
# A service name on the Pi-holes is a CNAME to its host (vikunja.asyla.org -> d06.asyla.org).
# Docker's embedded DNS sends a container's lookups to the host's resolved (127.0.0.53). While
# resolved holds that CNAME in its cache, it answers the target from /etc/hosts: 127.0.1.1, which
# inside a container is the container itself. The Pi-holes have given local answers a 60 s TTL since
# 2026-11-08 13:31Z (5b1114b), so the CNAME is cached; with TTL 0 nothing was cached. d06's
# alert-relay got "Connection refused" from Vikunja from 14:20Z that day (asyla hub backlog
# 2026-11-08-hosts-gitlab-failed-pipeline-mail-becomes-vikunja-tasks-decide-the).
#
# Run as root by the build (build_host.py setup phase). On a running host, this step alone:
#   build_host.py HOST build --only setup --step container_dns.sh --apply
# Idempotent: the drop-in is written, and resolved reloaded (not restarted), only when it differs.
# Then each name on a 127.0.1.1 line of /etc/hosts that has a dot is looked up through resolved,
# and the step fails if any answer is still a loopback address.
# --dropin DIR: write the drop-in into DIR and stop (no root, no systemctl; for the tests).
set -euo pipefail

NAME=no-etc-hosts.conf
DIR=/etc/systemd/resolved.conf.d

want() {
    printf '%s\n' '# build/setup/container_dns.sh (asyla-hosts): containers ask this resolved through' \
        '# Docker'"'"'s DNS; never answer them from /etc/hosts (127.0.1.1 is the container itself).' \
        '[Resolve]' 'ReadEtcHosts=no'
}

# Writes DIR/NAME when it differs; prints "changed" or "same".
write_dropin() {
    local file="$1/$NAME"
    if [ -f "$file" ] && want | cmp -s - "$file"; then echo same; return; fi
    install -d -m 755 "$1"
    want > "$file.tmp"
    chmod 644 "$file.tmp"
    mv -f "$file.tmp" "$file"
    echo changed
}

if [ "${1:-}" = "--dropin" ]; then
    write_dropin "${2:?usage: container_dns.sh --dropin DIR}"
    exit 0
fi

[ "$EUID" -eq 0 ] || { echo "[ERROR] run as root" >&2; exit 1; }

if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    echo "[INFO] systemd-resolved is not running: containers use the servers in /etc/resolv.conf; nothing to do"
    exit 0
fi

if [ "$(write_dropin "$DIR")" = changed ]; then
    systemctl reload systemd-resolved
    resolvectl flush-caches
    echo "[INFO] $DIR/$NAME written (ReadEtcHosts=no); systemd-resolved reloaded, caches flushed"
else
    echo "[INFO] $DIR/$NAME already in place"
fi

# Proof: the host's own names, asked through resolved, are no longer loopback.
fail=0
names=$(awk '$1 == "127.0.1.1" { for (i = 2; i <= NF && $i !~ /^#/; i++) if ($i ~ /\./) print $i }' /etc/hosts)
for n in $names; do
    out=$(resolvectl query --legend=no -4 "$n" 2>&1) || true
    addrs=$(printf '%s\n' "$out" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | tr '\n' ' ')
    if [ -z "$addrs" ]; then
        echo "[WARN] resolved did not answer $n, so the step cannot prove it: $(printf '%s' "$out" | head -1)"
    elif printf '%s\n' $addrs | grep -q '^127\.'; then
        echo "[ERROR] resolved still answers $n with $addrs(from /etc/hosts)" >&2
        fail=1
    else
        echo "[OK] resolved answers $n with ${addrs% }, not /etc/hosts' 127.0.1.1"
    fi
done
[ -n "$names" ] || echo "[INFO] /etc/hosts has no 127.0.1.1 name with a dot; nothing to prove"
exit "$fail"
