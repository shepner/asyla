#!/bin/sh
# Shared configuration of the Proxmox VE nodes vmh01, vmh02 (cluster vmc01, production) and vmh03
# (standalone testbed and canary). Runs as root on the node, piped from the workstation by
# vmh/apply.sh, which puts HEALTH_B64, RX_B64 and (for patch) CANARY_B64 in front of this file.
# Idempotent. vmh03's own role (corosync-qnetd) stays in vmh03/setup.sh. Modes:
#   check                    read-only: does the node match the parts below? non-zero if not
#   setup [PART...]          converge the parts (default all, in this order), then check
#   patch [--dry-run|--plan] apt upgrade, no reboot. vmh03: everything. Production: only packages at
#                            the version vmh03 has run for SOAK_DAYS (CANARY_B64); the rest is listed.
#                            --plan is read-only: no apt-get update, the lists as they are, simulation
#   kernel VERSION|none [--next-boot]   pin a kernel ABI (e.g. 6.14.11-9-pve) for the next boots
#   cleanup [--dry-run]      old kernels (PVE's own keep list), old kdump initrds, apt cache
#   canary-list              read-only (vmh03): "package version first-installed-epoch source
#                            source-version" per installed package
#   health                   read-only: the health checks (vmh/health.sh), as host-maintenance runs them
# Parts:
#   repos          pve-no-subscription; pve-enterprise and ceph disabled
#   updates        unattended-upgrades: vmh03 all origins (the canary), production Debian-Security
#                  only; never a reboot, never kernel or package removal
#   crash          one sysctl set, kdump-tools (MODULES=most, crashkernel by RAM), serial console
#                  where the board has one, netconsole to vmh03 configured after vmbr0 exists
#   netconsole-rx  vmh03 only: UDP 6666 from vmh01/vmh02, one log per sender with receive times
#   health         /usr/local/sbin/asyla-vmh-health (read-only), and root's authorized_keys line that
#                  lets host-maintenance's monitor (the d03 runner's key) run it and nothing else
set -eu

SOURCES=/etc/apt/sources.list.d
SYSCTL=/etc/sysctl.d/99-crashdebug.conf     # the name vmh01/vmh02 already use, so it replaces theirs
GRUB_DROPIN=/etc/default/grub.d/zz-asyla-crash.cfg
KDUMP_HOOK=/etc/kernel/postinst.d/kdump-tools
NC_DIR=/sys/kernel/config/netconsole/asyla
NC_PORT=6666
RX_SENDERS="vmh01=10.0.0.35 vmh02=10.0.0.36"
CANARY=10.0.0.37                             # vmh03: netconsole receiver and version canary
# host-maintenance's runner key on d03 (its setup/setup-runner-d03.sh; public). On a node it may run
# the health script only, from d03 (its address, or a job container's).
MONITOR_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN8NNenIyQGHyq+UJRcpLsQA9OMk2c9C2+BVuPY98k7x host-maintenance@d03'
MONITOR_OPTS='from="10.0.0.62,172.16.0.0/12",restrict,command="/usr/local/sbin/asyla-vmh-health"'
SOAK_DAYS=${SOAK_DAYS:-7}                    # apply.sh may lower it for --plan only
# One reservation rule for all three; the kernel picks by RAM (vmh03 15 GB: 256M, vmh01/02 125 GB: 512M).
# kdump-tools' own default (512M-:192M) is too small once the kdump initrd carries MODULES=most.
CRASHKERNEL=1G-4G:192M,4G-64G:256M,64G-:512M

say() { printf '%s\n' "$*"; }
die() { printf 'vmh setup: %s\n' "$*" >&2; exit 1; }

# Per node: role, address, serial console, netconsole target.
node=$(hostname -s)
case "$node" in
    vmh01) ROLE=production ADDRESS=10.0.0.35 SERIAL=ttyS0 NC_TO=$CANARY ;;
    vmh02) ROLE=production ADDRESS=10.0.0.36 SERIAL=ttyS0 NC_TO=$CANARY ;;
    vmh03) ROLE=canary     ADDRESS=10.0.0.37 SERIAL=     NC_TO= ;;   # USB NIC: a receiver, not a sender
    *) die "unknown node $node (vmh01, vmh02, vmh03)" ;;
esac

# install_file DEST MODE: write stdin to DEST only if it differs. It is often the end of a pipeline
# (a subshell), so a write is recorded in a file: reset_changed before, changed after.
MARK=$(mktemp -u /tmp/asyla-vmh-changed.XXXXXX)
trap 'rm -f "$MARK"' EXIT
reset_changed() { rm -f "$MARK"; }
changed() { [ -e "$MARK" ]; }
install_file() {
    tmp=$(mktemp)
    cat >"$tmp"
    if [ -f "$1" ] && cmp -s "$tmp" "$1"; then
        rm -f "$tmp"; say "ok      $1"; return 0
    fi
    mkdir -p "$(dirname "$1")"
    install -m "$2" "$tmp" "$1"; rm -f "$tmp"
    : >"$MARK"; say "changed $1"
}

payload() {   # payload NAME: decode a file apply.sh sent in front of this script
    eval "v=\${$1:-}"
    [ -n "$v" ] || die "$1 missing: run this through vmh/apply.sh"
    printf '%s' "$v" | base64 -d
}

installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

apt_install() {
    missing=
    for p in "$@"; do installed "$p" || missing="$missing $p"; done
    [ -z "$missing" ] && return 0
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q $missing
    say "changed installed$missing"
}

boot_refresh() {   # write the kernel cmdline and boot entries the way this node boots
    if [ -s /etc/kernel/proxmox-boot-uuids ]; then proxmox-boot-tool refresh >/dev/null 2>&1; else update-grub >/dev/null 2>&1; fi
    say "changed boot entries refreshed"
}

# ---- repos
disable_sources() {   # every deb822 stanza in $1 gets "Enabled: false"
    awk '
        /^Enabled:/ { next }
        /^[[:space:]]*$/ { if (open) print "Enabled: false"; open = 0; print; next }
        { open = 1; print }
        END { if (open) print "Enabled: false" }
    ' "$1" | install_file "$1" 644
}

part_repos() {
    say "== repos"
    install_file "$SOURCES/proxmox.sources" 644 <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    for f in "$SOURCES/pve-enterprise.sources" "$SOURCES/ceph.sources"; do
        if [ -f "$f" ]; then disable_sources "$f"; fi
    done
    apt-get update -q >/dev/null
    say "ok      apt-get update"
}

# ---- updates
uu_config() {
    if [ "$ROLE" = canary ]; then
        origins='        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename}-updates,label=Debian";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=Proxmox,codename=${distro_codename}";'
        why="vmh03 is the canary: every origin, so new Debian and Proxmox versions run here first."
    else
        origins='        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";'
        why="Production: Debian security fixes only. Proxmox, kernels and the rest go by vmh/apply.sh patch."
    fi
    cat <<EOF
// asyla-hosts vmh/setup.sh (part updates). $why
// No reboot, no removals: kernels move by vmh/apply.sh kernel, old ones go by vmh/apply.sh cleanup.
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
$origins
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Mail "";
Dpkg::Options { "--force-confdef"; "--force-confold"; };
EOF
}

part_updates() {
    say "== updates ($ROLE)"
    apt_install unattended-upgrades
    uu_config | install_file /etc/apt/apt.conf.d/52asyla-unattended-upgrades 644
    install_file /etc/apt/apt.conf.d/20auto-upgrades 644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    for t in apt-daily.timer apt-daily-upgrade.timer; do
        systemctl -q is-enabled "$t" || { systemctl enable -q --now "$t"; say "changed $t enabled"; }
    done
}

# ---- crash capture
sysctl_body() {
    cat <<'EOF'
# asyla-hosts vmh/setup.sh (part crash): the same on vmh01, vmh02 and vmh03.
# A stuck kernel panics instead of sitting silent; kdump then saves a vmcore and the node reboots.
kernel.panic = 10
kernel.panic_on_oops = 1
kernel.hardlockup_panic = 1
kernel.softlockup_panic = 1
kernel.unknown_nmi_panic = 1
kernel.panic_on_unrecovered_nmi = 1
# The 2026-05-24 vmh02 hang (ZFS zvol deadlock) showed itself only as a hung task.
kernel.hung_task_panic = 1
kernel.hung_task_timeout_secs = 120
# OOM kills one guest's qemu rather than panicking the node and every guest with it.
vm.panic_on_oom = 0
EOF
}

sysctls_live() {   # every value of sysctl_body is the running one
    sysctl_body | awk -F' *= *' '/^[a-z]/ { print $1, $2 }' | while read -r k v; do
        [ "$(sysctl -n "$k")" = "$v" ] || echo "$k"
    done | grep -q . && return 1
    return 0
}

cmdline_extra() {
    printf 'crashkernel=%s' "$CRASHKERNEL"
    if [ -n "$SERIAL" ]; then printf ' console=tty0 console=%s,115200n8' "$SERIAL"; fi
}

grub_body() {
    cat <<EOF
# asyla-hosts vmh/setup.sh (part crash). Sorts after kdump-tools.cfg: drops its crashkernel and any
# console= from /etc/default/grub, then adds this node's.
GRUB_CMDLINE_LINUX_DEFAULT="\$(printf '%s' "\$GRUB_CMDLINE_LINUX_DEFAULT" | sed -e 's/ *crashkernel=[^ ]*//g' -e 's/ *console=[^ ]*//g') $(cmdline_extra)"
EOF
}

netconsole_script() {
    cat <<'EOF'
#!/bin/sh
# asyla-hosts vmh/setup.sh (part crash): kernel messages to vmh03 over netconsole, configured
# through configfs once vmbr0 exists (a modprobe option runs before the bridge and fails).
# Usage: asyla-netconsole start|stop REMOTE_IP PORT
set -eu
dir=/sys/kernel/config/netconsole/asyla
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
modprobe netconsole
case "$1" in
    stop) if [ -d "$dir" ]; then echo 0 >"$dir/enabled"; rmdir "$dir"; fi; exit 0 ;;
    start) ;;
    *) echo "usage: $0 start|stop REMOTE_IP PORT" >&2; exit 2 ;;
esac
remote=$2 port=$3
local_ip=$(ip -4 -o addr show dev vmbr0 | awk '{ sub(/\/.*/, "", $4); print $4; exit }')
[ -n "$local_ip" ] || { echo "asyla-netconsole: vmbr0 has no IPv4 address" >&2; exit 1; }
# The receiver's MAC, so frames go to it alone; broadcast if it does not answer now.
ping -c 1 -W 2 "$remote" >/dev/null 2>&1 || true
mac=$(ip neigh show "$remote" dev vmbr0 | awk '/lladdr/ { print $3; exit }')
[ -d "$dir" ] || mkdir "$dir"
[ "$(cat "$dir/enabled")" = 0 ] || echo 0 >"$dir/enabled"
echo vmbr0 >"$dir/dev_name"
echo "$local_ip" >"$dir/local_ip"
echo "$remote" >"$dir/remote_ip"
echo "$port" >"$dir/remote_port"
echo "${mac:-ff:ff:ff:ff:ff:ff}" >"$dir/remote_mac"
echo 1 >"$dir/enabled"
echo "asyla-netconsole: $local_ip -> $remote:$port (${mac:-broadcast})"
EOF
}

part_crash() {
    say "== crash"
    reset_changed
    sysctl_body | install_file "$SYSCTL" 644
    if changed || ! sysctls_live; then sysctl -q -p "$SYSCTL"; say "changed sysctls applied"; fi

    if ! installed kdump-tools; then
        echo 'kdump-tools kdump-tools/use_kdump boolean true' | debconf-set-selections
        apt_install kdump-tools makedumpfile
    fi
    # kdump-tools turns MODULES=most into dep for its initrd; on a ZFS root that initrd cannot find
    # rpool (asyla data/incidents/vmh01-crash-investigation-2026-05-22). Same initrd kind on all nodes.
    if grep -q '^[[:space:]]*KDUMP_MODULES=dep' "$KDUMP_HOOK"; then
        sed -i 's/^\([[:space:]]*\)KDUMP_MODULES=dep.*/\1KDUMP_MODULES=most  # asyla vmh\/setup.sh: ZFS root needs most/' "$KDUMP_HOOK"
        say "changed $KDUMP_HOOK: KDUMP_MODULES=most"
        rm -f /var/lib/kdump/initrd.img-* /var/lib/kdump/vmlinuz-*
        for k in $(linux-version list); do "$KDUMP_HOOK" "$k" >/dev/null; done
        say "changed kdump initrds rebuilt"
    else
        say "ok      $KDUMP_HOOK: KDUMP_MODULES=most"
    fi

    reset_changed
    grub_body | install_file "$GRUB_DROPIN" 644
    if changed || ! grep -qF "crashkernel=$CRASHKERNEL" /boot/grub/grub.cfg 2>/dev/null; then boot_refresh; fi

    if [ -n "$SERIAL" ]; then
        systemctl -q is-enabled "serial-getty@$SERIAL.service" 2>/dev/null \
            || { systemctl enable -q --now "serial-getty@$SERIAL.service"; say "changed serial-getty@$SERIAL enabled"; }
    fi

    if [ -n "$NC_TO" ]; then
        reset_changed
        netconsole_script | install_file /usr/local/sbin/asyla-netconsole 755
        script=0; changed && script=1
        reset_changed
        install_file /etc/systemd/system/asyla-netconsole.service 644 <<EOF
[Unit]
Description=asyla: kernel messages to $NC_TO:$NC_PORT over netconsole (vmh/setup.sh)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/asyla-netconsole start $NC_TO $NC_PORT
ExecStop=/usr/local/sbin/asyla-netconsole stop

[Install]
WantedBy=multi-user.target
EOF
        if changed; then systemctl daemon-reload; fi
        systemctl enable -q asyla-netconsole.service
        if [ "$script" = 1 ] || changed || ! systemctl -q is-active asyla-netconsole.service; then
            systemctl restart asyla-netconsole.service
            say "changed asyla-netconsole.service (re)started"
        else
            say "ok      asyla-netconsole.service"
        fi
    fi

    if [ "$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null)" != 1 ] && [ -s /sys/kernel/kexec_crash_size ] \
        && [ "$(cat /sys/kernel/kexec_crash_size)" != 0 ]; then
        kdump-config load >/dev/null && say "changed kdump loaded"
    fi
}

# ---- netconsole receiver (vmh03)
part_netconsole_rx() {
    say "== netconsole-rx"
    [ "$ROLE" = canary ] || { say "skip    netconsole-rx runs on vmh03 only"; return 0; }
    apt_install python3 nftables
    reset_changed
    payload RX_B64 | install_file /usr/local/sbin/asyla-netconsole-rx 755
    code=0; changed && code=1
    ips=$(printf '%s\n' $RX_SENDERS | sed 's/.*=//' | paste -sd, - | sed 's/,/, /g')
    reset_changed
    install_file /etc/asyla/netconsole.nft 644 <<EOF
# asyla-hosts vmh/setup.sh (part netconsole-rx): UDP $NC_PORT only from vmh01, vmh02 and this host.
table inet asyla_netconsole
delete table inet asyla_netconsole
table inet asyla_netconsole {
    chain input {
        type filter hook input priority filter; policy accept;
        udp dport $NC_PORT iif lo accept
        udp dport $NC_PORT ip saddr { $ips } accept
        udp dport $NC_PORT drop
    }
}
EOF
    rules=0; changed && rules=1
    reset_changed
    install_file /etc/systemd/system/asyla-netconsole-rx.service 644 <<EOF
[Unit]
Description=asyla: netconsole receiver, UDP $NC_PORT from vmh01 and vmh02 (vmh/setup.sh)
After=network.target

[Service]
ExecStartPre=+/usr/sbin/nft -f /etc/asyla/netconsole.nft
ExecStart=/usr/local/sbin/asyla-netconsole-rx $NC_PORT /var/log/netconsole $RX_SENDERS local=127.0.0.1
ExecStopPost=-+/usr/sbin/nft delete table inet asyla_netconsole
Restart=always
RestartSec=5
DynamicUser=yes
LogsDirectory=netconsole
LogsDirectoryMode=0750
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
AmbientCapabilities=
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF
    unit=0; changed && unit=1
    install_file /etc/logrotate.d/asyla-netconsole 644 <<'EOF'
/var/log/netconsole/*.log {
    weekly
    rotate 12
    compress
    missingok
    notifempty
}
EOF
    [ "$unit" = 1 ] && systemctl daemon-reload
    systemctl enable -q asyla-netconsole-rx.service
    if [ "$code" = 1 ] || [ "$rules" = 1 ] || [ "$unit" = 1 ] || ! systemctl -q is-active asyla-netconsole-rx.service; then
        systemctl restart asyla-netconsole-rx.service
        say "changed asyla-netconsole-rx.service (re)started"
    else
        say "ok      asyla-netconsole-rx.service"
    fi
}

# ---- health
monitor_line() { printf '%s %s\n' "$MONITOR_OPTS" "$MONITOR_KEY"; }
# root's authorized_keys is a link into /etc/pve/priv on Proxmox: in a cluster one file for all nodes.
root_keys() { readlink -f /root/.ssh/authorized_keys; }

part_health() {
    say "== health"
    payload HEALTH_B64 | install_file /usr/local/sbin/asyla-vmh-health 755
    ak=$(root_keys)
    if grep -qxF "$(monitor_line)" "$ak" 2>/dev/null; then
        say "ok      $ak: host-maintenance key (health only)"
    else
        # Any other line with this key goes (written in place: the link and pmxcfs stay as they are).
        # The nodes reach each other as root with this file: every other line must survive.
        body=$(printf '%s\n' "$MONITOR_KEY" | awk '{ print $2 }')
        [ ! -e "$ak" ] || [ -r "$ak" ] || die "$ak unreadable"
        before=0 same=0
        if [ -e "$ak" ]; then
            before=$(grep -c . "$ak" || true); same=$(grep -cF -- "$body" "$ak" || true)
            [ -e /root/authorized_keys.before-asyla-vmh ] || cp -p "$ak" /root/authorized_keys.before-asyla-vmh
        fi
        tmp=$(mktemp)
        { if [ -e "$ak" ]; then grep -vF -- "$body" "$ak" || true; fi; monitor_line; } >"$tmp"
        [ "$(grep -c . "$tmp")" -eq $((before - same + 1)) ] || { rm -f "$tmp"; die "$ak: rewrite would lose lines; nothing written"; }
        cat "$tmp" >"$ak"; rm -f "$tmp"
        say "changed $ak: host-maintenance key (health only)"
    fi
}

# ---- check
check() {
    bad=0
    flag() { say "FAIL    $*"; bad=1; }
    okay() { say "ok      $*"; }
    note() { say "note    $*"; }
    want_file() {   # want_file PATH CONTENT-ON-STDIN
        tmp=$(mktemp); cat >"$tmp"
        if [ -f "$1" ] && cmp -s "$tmp" "$1"; then okay "$1"; else flag "$1 differs from vmh/setup.sh"; fi
        rm -f "$tmp"
    }
    say "== check $node ($ROLE)"
    for f in "$SOURCES/pve-enterprise.sources" "$SOURCES/ceph.sources"; do
        [ -f "$f" ] || continue
        if awk '/^Types:/ { n++ } /^Enabled: false/ { d++ } END { exit !(n == d) }' "$f"; then okay "$f disabled"
        else flag "$f has an enabled stanza"; fi
    done
    if grep -q '^[[:space:]]*deb ' /etc/apt/sources.list 2>/dev/null; then
        note "/etc/apt/sources.list has active deb lines (one-line format; review, see vmh/README.md)"
    fi
    installed unattended-upgrades && okay "unattended-upgrades installed" || flag "unattended-upgrades not installed"
    uu_config | want_file /etc/apt/apt.conf.d/52asyla-unattended-upgrades

    sysctl_body | want_file "$SYSCTL"
    sysctl_body | awk -F' *= *' '/^[a-z]/ { print $1, $2 }' | while read -r k v; do
        [ "$(sysctl -n "$k")" = "$v" ] || say "FAIL    sysctl $k is $(sysctl -n "$k"), want $v"
    done | grep . && bad=1
    installed kdump-tools && okay "kdump-tools installed" || flag "kdump-tools not installed"
    grep -q '^[[:space:]]*KDUMP_MODULES=most' "$KDUMP_HOOK" 2>/dev/null && okay "kdump initrd MODULES=most" \
        || flag "$KDUMP_HOOK not patched to KDUMP_MODULES=most"
    grub_body | want_file "$GRUB_DROPIN"
    for w in $(cmdline_extra); do
        grep -qw -- "$w" /proc/cmdline || note "running cmdline lacks $w (applies at the next boot)"
    done
    if [ "$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null)" = 1 ]; then
        okay "kdump loaded, $(awk '{ printf "%d", $1 / 1048576 }' /sys/kernel/kexec_crash_size) MiB reserved"
    else
        note "kdump not loaded (no crashkernel reservation until the next boot)"
    fi
    if [ -n "$SERIAL" ]; then
        systemctl -q is-active "serial-getty@$SERIAL.service" && okay "serial-getty@$SERIAL" || flag "serial-getty@$SERIAL not active"
    fi
    if [ -n "$NC_TO" ]; then
        netconsole_script | want_file /usr/local/sbin/asyla-netconsole
        if [ "$(cat "$NC_DIR/enabled" 2>/dev/null)" = 1 ] && [ "$(cat "$NC_DIR/remote_ip")" = "$NC_TO" ]; then
            okay "netconsole -> $NC_TO:$(cat "$NC_DIR/remote_port") via $(cat "$NC_DIR/dev_name") ($(cat "$NC_DIR/remote_mac"))"
        else
            flag "netconsole target to $NC_TO not enabled"
        fi
    fi
    for f in /etc/modprobe.d/netconsole.conf /etc/modules-load.d/netconsole.conf; do
        [ -f "$f" ] && note "$f: the old boot-time netconsole (fails before vmbr0); see vmh/README.md"
    done
    if [ "$ROLE" = canary ]; then
        systemctl -q is-active asyla-netconsole-rx.service && okay "asyla-netconsole-rx active" \
            || flag "asyla-netconsole-rx not active"
        nft list table inet asyla_netconsole >/dev/null 2>&1 && okay "nft table inet asyla_netconsole" \
            || flag "nft table inet asyla_netconsole missing"
    fi
    [ -x /usr/local/sbin/asyla-vmh-health ] && okay "asyla-vmh-health installed" || flag "asyla-vmh-health missing"
    grep -qxF "$(monitor_line)" "$(root_keys)" 2>/dev/null && okay "host-maintenance key (health only)" \
        || flag "$(root_keys) lacks the host-maintenance line (health only)"
    if [ -n "${HEALTH_B64:-}" ] && [ -x /usr/local/sbin/asyla-vmh-health ]; then
        payload HEALTH_B64 | want_file /usr/local/sbin/asyla-vmh-health
    fi
    [ "$bad" = 0 ] || die "check found problems (FAIL lines above)"
    say "check: all ok"
}

# ---- patch
canary_list() {   # package version first-installed-epoch source source-version, per installed package
    zcat -f $(ls -tr /var/log/dpkg.log*) 2>/dev/null | awk '$3 == "status" && $4 == "installed" {
        sub(/:.*/, "", $5); k = $5 " " $6
        if (!(k in first)) { cmd = "date -d \"" $1 " " $2 "\" +%s"; cmd | getline t; close(cmd); first[k] = t }
    } END { for (k in first) print k, first[k] }' >/tmp/asyla-canary-seen.$$
    dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version} ${source:Package} ${source:Version}\n' \
        | awk -v seen=/tmp/asyla-canary-seen.$$ '
        BEGIN { while ((getline l < seen) > 0) { split(l, a, " "); t[a[1] " " a[2]] = a[3] } }
        $1 ~ /^ii/ { k = $2 " " $3; print $2, $3, (k in t ? t[k] : 0), $4, $5 }'
    rm -f /tmp/asyla-canary-seen.$$
}

apt_upgrade() {   # apt_upgrade ARGS...: non-interactive, keep local conffiles
    DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold "$@"
}

patch() {
    dry=0 plan=0
    case "${1:-}" in --dry-run) dry=1 ;; --plan) dry=1 plan=1 ;; "") ;; *) die "patch [--dry-run|--plan]" ;; esac
    if [ "$plan" = 1 ]; then
        # Read-only: apt-get -s takes no lock, and the lists stay as the node last fetched them.
        newest=$(find /var/lib/apt/lists -maxdepth 1 -name '*_InRelease' -printf '%T@\n' 2>/dev/null | sort -n | tail -n1)
        say "plan    package lists from $(date -d "@${newest%.*}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo unknown) (no apt-get update)"
    else
        apt-get update -q >/dev/null
    fi
    if [ "$ROLE" = canary ]; then
        apt-get -s full-upgrade | awk '/^(Inst|Remv) / { print }' | tee /tmp/asyla-patch.$$ | sed 's/^/plan    /'
        say "patch: $(grep -c '^Inst' /tmp/asyla-patch.$$) to install, $(grep -c '^Remv' /tmp/asyla-patch.$$) to remove"
        rm -f /tmp/asyla-patch.$$
        [ "$dry" = 1 ] && return 0
        apt_upgrade full-upgrade
    else
        canary=$(mktemp); payload CANARY_B64 | gzip -dc >"$canary"
        [ -s "$canary" ] || die "empty canary list"
        cutoff=$(( $(date +%s) - SOAK_DAYS * 86400 ))
        # Every package full-upgrade would install, at its candidate version. Inst lines read
        # "Inst pkg [old] (new repo [arch])", or "Inst pkg (new repo [arch])" for a new package.
        apt-get -s full-upgrade | sed -n 's/^Inst \([^ ]*\) \(\[[^]]*\] \)\{0,1\}(\([^ ]*\) .*/\1 \3/p' >"$canary.plan"
        # The source package of each candidate, so a binary vmh03 does not have (libc6-dev) can go
        # with a sibling vmh03 runs from the same source build (libc6). "pkg ver source source-ver".
        # shellcheck disable=SC2046
        apt-cache show $(awk '{ printf "%s=%s ", $1, $2 }' "$canary.plan") 2>/dev/null | awk '
            /^Package: / { p = $2; v = ""; s = ""; sv = "" } /^Version: / { v = $2 }
            /^Source: / { s = $2; if ($3 ~ /^\(/) { sv = $3; gsub(/[()]/, "", sv) } }
            /^$/ { if (p != "") print p, v, (s == "" ? p : s), (sv == "" ? v : sv); p = "" }
            END { if (p != "") print p, v, (s == "" ? p : s), (sv == "" ? v : sv) }' >"$canary.src"
        # Verdict per candidate: allow (vmh03 has had this version, or a sibling of the same source
        # version, for SOAK_DAYS), soak (it has, for less), new (it has neither).
        awk -v cutoff="$cutoff" '
            FILENAME == ARGV[1] { k = $1 " " $2; t[k] = $3; if ($4 != "") { s = $4 " " $5; if (!(s in st) || $3 < st[s]) st[s] = $3 }; next }
            FILENAME == ARGV[2] { src[$1 " " $2] = $3 " " $4; next }
            { k = $1 " " $2; how = ""
              if (k in t) e = t[k]; else if ((k in src) && (src[k] in st)) { e = st[src[k]]; how = " (source " src[k] " on vmh03)" } else e = ""
              if (e == "") print "new", $1, $2; else if (e <= cutoff) print "allow", $1, $2 how; else print "soak", $1, $2 how }' \
            "$canary" "$canary.src" "$canary.plan" >"$canary.verdict"
        allow=$(awk '$1 == "allow" { printf "%s=%s ", $2, $3 }' "$canary.verdict")
        awk '$1 == "allow" { $1 = "allow  "; print }
             $1 == "soak" { print "held    " $2 " " $3 " (on vmh03 under '"$SOAK_DAYS"' days)" }
             $1 == "new"  { print "held    " $2 " " $3 " (neither this version nor its source on vmh03)" }' "$canary.verdict"
        say "patch: $(grep -c '^allow' "$canary.verdict") allowed, $(grep -c -v '^allow' "$canary.verdict") held"
        if [ -z "$allow" ]; then rm -f "$canary" "$canary".*; say "patch: nothing to do"; return 0; fi
        # The allowed set alone must not pull in anything held, nor remove anything.
        # shellcheck disable=SC2086
        sim=$(apt-get -s install --only-upgrade $allow 2>&1) || { printf '%s\n' "$sim" | tail -n 20; die "simulation failed"; }
        printf '%s\n' "$sim" | grep '^Remv ' && die "the allowed set would remove packages (above)"
        extra=$(printf '%s\n' "$sim" | sed -n 's/^Inst \([^ ]*\) \(\[[^]]*\] \)\{0,1\}(\([^ ]*\) .*/\1 \3/p' \
            | awk 'NR == FNR { if ($1 == "allow") a[$2 " " $3] = 1; next } !(($1 " " $2) in a)' "$canary.verdict" - \
            | tr '\n' ' ')
        rm -f "$canary" "$canary".*
        [ -z "$extra" ] || die "the allowed set pulls in packages not soaked on vmh03: $extra"
        [ "$dry" = 1 ] && { say "patch: the allowed set installs alone and removes nothing; nothing installed (dry run)"; return 0; }
        # shellcheck disable=SC2086
        apt_upgrade install --only-upgrade $allow
    fi
    pinned=$(proxmox-boot-tool kernel list 2>/dev/null | awk '/^Pinned kernel:/ { getline; print $1 }')
    [ -n "$pinned" ] || [ "$ROLE" = canary ] || say "note    no kernel pinned: the next boot takes the newest installed kernel"
    [ -e /run/reboot-required ] && say "note    /run/reboot-required is set (no reboot done)"
    say "patch: done"
}

# ---- kernel
kernel() {
    v=${1:-}; shift || true
    nb=; [ "${1:-}" = --next-boot ] && nb=--next-boot
    [ -n "$v" ] || die "kernel needs a version (e.g. 6.14.11-9-pve) or none"
    if [ "$v" = none ]; then
        proxmox-boot-tool kernel unpin $nb
    else
        case "$v" in *-pve) ;; *) die "kernel version ends in -pve, e.g. 6.14.11-9-pve" ;; esac
        if ! installed "proxmox-kernel-$v-signed" && ! installed "proxmox-kernel-$v"; then
            apt-get update -q >/dev/null
            if apt-cache show "proxmox-kernel-$v-signed" >/dev/null 2>&1; then apt_install "proxmox-kernel-$v-signed"
            else apt_install "proxmox-kernel-$v"; fi
        fi
        proxmox-boot-tool kernel pin "$v" $nb
    fi
    proxmox-boot-tool refresh >/dev/null
    proxmox-boot-tool kernel list
    say "kernel: running $(uname -r); no reboot done"
}

# ---- cleanup
cleanup() {
    dry=0; [ "${1:-}" = --dry-run ] && dry=1
    # Kernel images and series packages to "automatic", so autoremove may take what PVE's own keep
    # list (/etc/apt/apt.conf.d/76pveconf: running, pinned, next-boot, latest two, the two newest
    # series) does not protect. Headers and the helper are not touched.
    kpkgs=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'proxmox-kernel-[0-9]*' 'pve-kernel-[0-9]*' 2>/dev/null \
        | awk '$1 ~ /^ii/ { print $2 }')
    manual=$(apt-mark showmanual $kpkgs 2>/dev/null | tr '\n' ' ')
    /etc/kernel/postinst.d/proxmox-auto-removal "$(uname -r)" >/dev/null 2>&1 || true   # regenerate 76pveconf
    if [ "$dry" = 1 ]; then
        say "would mark automatic: ${manual:-none}"
        # Simulate with the marks applied in a throwaway copy of the extended states.
        tmp=$(mktemp -d); cp /var/lib/apt/extended_states "$tmp/" 2>/dev/null || : >"$tmp/extended_states"
        [ -z "$manual" ] || apt-mark -o Dir::State::extended_states="$tmp/extended_states" auto $manual >/dev/null
        apt-get -s -o Dir::State::extended_states="$tmp/extended_states" autoremove --purge | awk '/^Purg / { print "would purge " $2 }'
        rm -rf "$tmp"
    else
        [ -z "$manual" ] || { apt-mark auto $manual >/dev/null; say "changed marked automatic: $manual"; }
        DEBIAN_FRONTEND=noninteractive apt-get -y -q autoremove --purge
        apt-get clean
        # kdump initrds of kernels that are gone
        for f in /var/lib/kdump/initrd.img-* /var/lib/kdump/vmlinuz-*; do
            [ -e "$f" ] || continue
            k=${f##*/initrd.img-}; k=${k##*/vmlinuz-}
            [ -e "/boot/vmlinuz-$k" ] || { rm -f "$f"; say "changed removed $f"; }
        done
        [ -s /etc/kernel/proxmox-boot-uuids ] && proxmox-boot-tool refresh >/dev/null && say "ok      ESPs refreshed"
    fi
    say "kernels left: $(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'proxmox-kernel-*-pve-signed' 'pve-kernel-*-pve' 2>/dev/null | awk '$1 ~ /^ii/ { sub(/^(proxmox|pve)-kernel-/, "", $2); sub(/-signed$/, "", $2); print $2 }' | sort -V | tr '\n' ' ')"
}

[ "$(id -u)" = 0 ] || die "run as root"
command -v pveversion >/dev/null || die "not a Proxmox VE host"

mode=${1:-check}; [ $# -gt 0 ] && shift
case "$mode" in
    check) check ;;
    setup)
        parts=${*:-repos updates crash netconsole-rx health}
        for p in $parts; do
            case "$p" in
                repos) part_repos ;; updates) part_updates ;; crash) part_crash ;;
                netconsole-rx) part_netconsole_rx ;; health) part_health ;;
                *) die "unknown part $p (repos updates crash netconsole-rx health)" ;;
            esac
        done
        check ;;
    patch) patch "$@" ;;
    kernel) kernel "$@" ;;
    cleanup) cleanup "$@" ;;
    canary-list) canary_list ;;
    health) payload HEALTH_B64 | sh -s -- "$@" ;;
    *) die "unknown mode $mode: check | setup [PART...] | patch [--dry-run] | kernel VERSION|none [--next-boot] | cleanup [--dry-run] | canary-list | health" ;;
esac
