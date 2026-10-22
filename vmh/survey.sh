#!/bin/sh
# Read-only survey of one Proxmox VE node (vmh01, vmh02, vmh03). Runs as root on the node, piped
# from the workstation by vmh/apply.sh survey. Changes nothing: no apt-get update, no writes.
# Prints one "key=value" line per fact, so nodes can be compared side by side; values never hold
# secrets (authorized_keys and relay settings are reduced to comments and names).
set -u

kv() { printf '%s=%s\n' "$1" "$2"; }
one() { tr '\n' ' ' | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//'; }
has() { command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" = 0 ] || { echo "survey: run as root" >&2; exit 1; }
has pveversion || { echo "survey: not a Proxmox VE host" >&2; exit 1; }

# ---- identity and uptime
kv host "$(hostname -s)"
kv survey.utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
kv uptime.days "$(awk '{ printf "%d", $1 / 86400 }' /proc/uptime)"
kv boot.time "$(uptime -s 2>/dev/null)"
kv cpu "$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo)"
kv mem.gib "$(awk '/^MemTotal/ { printf "%d", $2 / 1048576 }' /proc/meminfo)"
kv mem.available.gib "$(awk '/^MemAvailable/ { printf "%d", $2 / 1048576 }' /proc/meminfo)"

# ---- versions
kv pve.manager "$(pveversion | sed 's#^pve-manager/##; s#/.*##')"
kv kernel.running "$(uname -r)"
kv kernel.installed "$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'proxmox-kernel-*-pve-signed' 'pve-kernel-*-pve' 2>/dev/null \
    | awk '$1 ~ /^ii/ { sub(/^(proxmox|pve)-kernel-/, "", $2); sub(/-signed$/, "", $2); print $2 }' | sort -V | one)"
kv kernel.installed.count "$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'proxmox-kernel-*-pve-signed' 'pve-kernel-*-pve' 2>/dev/null | grep -c '^ii')"
kv kernel.series.meta "$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'proxmox-kernel-[0-9]*' 'pve-kernel-[0-9]*' 2>/dev/null \
    | awk '$1 ~ /^ii/ && $2 ~ /-kernel-[0-9]+\.[0-9]+$/ { sub(/^(proxmox|pve)-kernel-/, "", $2); print $2 }' | sort -V | one)"
newest=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'proxmox-kernel-*-pve-signed' 2>/dev/null \
    | awk '$1 ~ /^ii/ { sub(/^proxmox-kernel-/, "", $2); sub(/-signed$/, "", $2); print $2 }' | sort -V | tail -n1)
kv kernel.newest "$newest"
pinned=$(proxmox-boot-tool kernel list 2>/dev/null | awk '/^Pinned kernel:/ { getline; print $1 }')
kv kernel.pinned "${pinned:-none}"
kv kernel.next-boot "$(cat /etc/kernel/next-boot-pin 2>/dev/null || echo none)"
kv zfs.kmod "$(cat /sys/module/zfs/version 2>/dev/null || echo none)"
kv zfs.userland "$(dpkg-query -W -f='${Version}' zfsutils-linux 2>/dev/null)"
for p in corosync qemu-server pve-qemu-kvm lxc-pve proxmox-backup-client kdump-tools corosync-qdevice corosync-qnetd unattended-upgrades; do
    kv "pkg.$p" "$(dpkg-query -W -f='${db:Status-Abbrev} ${Version}' "$p" 2>/dev/null | awk '$1 ~ /^ii/ { print $2 }')"
done

# ---- patching (from the lists as they are; no apt-get update)
lists=$(find /var/lib/apt/lists -maxdepth 1 -name '*_InRelease' -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort | tail -n1)
kv apt.lists.updated "$lists"
kv apt.last-upgrade "$(zcat -f /var/log/apt/history.log* 2>/dev/null \
    | awk '/^Start-Date:/ { d = $2 } /^Commandline:.*(upgrade|unattended-upgrade)/ { print d }' | sort | tail -n1)"
sim=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null)
kv apt.upgradable "$(printf '%s\n' "$sim" | grep -c '^Inst ')"
kv apt.upgradable.security "$(printf '%s\n' "$sim" | grep '^Inst ' | grep -c -- '-security')"
kv apt.upgradable.kernel "$(printf '%s\n' "$sim" | grep '^Inst ' | grep -c -E '^Inst (proxmox|pve)-kernel-')"
kv apt.removals "$(printf '%s\n' "$sim" | grep -c '^Remv ')"
kv apt.held "$(apt-mark showhold 2>/dev/null | one)"
kv apt.autoremovable "$(apt-get -s -o Debug::NoLocking=1 autoremove 2>/dev/null | grep -c '^Remv ')"
for f in /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    n=$(grep -c '^Types:' "$f"); d=$(grep -c '^Enabled: *false' "$f")
    kv "repo.$(basename "$f" .sources)" "$(grep -h -m1 '^Components:' "$f" | sed 's/^Components: *//') enabled=$((n - d))/$n"
done
[ -s /etc/apt/sources.list ] && kv repo.sources.list "$(grep -c '^deb ' /etc/apt/sources.list) deb lines"
kv apt.reboot-required "$([ -e /run/reboot-required ] && echo yes || echo no)"

# ---- boot and crash capture
kv boot.cmdline "$(sed 's/BOOT_IMAGE=[^ ]* //' /proc/cmdline)"
if [ -s /etc/kernel/proxmox-boot-uuids ]; then
    kv boot.loader "proxmox-boot-tool $(proxmox-boot-tool status 2>/dev/null | grep -o -E '(uefi|grub)' | sort -u | one)"
    kv boot.esps "$(grep -c . /etc/kernel/proxmox-boot-uuids)"
else
    kv boot.loader "grub $([ -d /sys/firmware/efi ] && echo uefi || echo bios)"
fi
kv boot.cmdline.file "$( [ -f /etc/kernel/cmdline ] && echo "/etc/kernel/cmdline: $(cat /etc/kernel/cmdline)" || echo "grub: $(grep -h '^GRUB_CMDLINE_LINUX' /etc/default/grub /etc/default/grub.d/*.cfg 2>/dev/null | one)")"
for s in kernel.panic kernel.panic_on_oops kernel.hardlockup_panic kernel.softlockup_panic \
         kernel.unknown_nmi_panic kernel.panic_on_unrecovered_nmi kernel.hung_task_panic \
         kernel.hung_task_timeout_secs vm.panic_on_oom kernel.sysrq vm.swappiness; do
    kv "sysctl.$s" "$(sysctl -n "$s" 2>/dev/null)"
done
kv sysctl.files "$(grep -l -E 'panic|hung_task' /etc/sysctl.d/*.conf /etc/sysctl.conf 2>/dev/null | one)"
kv crash.kernel.size.mib "$(awk '{ printf "%d", $1 / 1048576 }' /sys/kernel/kexec_crash_size 2>/dev/null)"
kv crash.kernel.loaded "$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null)"
if has kdump-config; then
    kv crash.kdump.status "$(kdump-config status 2>/dev/null | tail -n1 | one)"
fi
kv crash.dumps "$(find /var/crash -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
kv crash.pstore.records "$(find /var/lib/systemd/pstore -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
nc=
if [ -d /sys/kernel/config/netconsole ]; then
    for t in /sys/kernel/config/netconsole/*/; do
        [ -d "$t" ] || continue
        nc="$nc $(basename "$t"):$(cat "$t/enabled")/$(cat "$t/dev_name")->$(cat "$t/remote_ip"):$(cat "$t/remote_port")"
    done
fi
kv crash.netconsole.configfs "${nc:-none}"
kv crash.netconsole.module "$(grep -h -o 'netconsole=[^ ]*' /etc/modprobe.d/*.conf 2>/dev/null | one)"
kv crash.netconsole.boot "$(journalctl -k -b --no-pager -q 2>/dev/null | grep -i netconsole | tail -n2 | sed 's/^.*kernel: //' | one)"
kv crash.serial.consoles "$(grep -o 'console=[^ ]*' /proc/cmdline | one)"
kv crash.serial.getty "$(systemctl list-units --no-legend --plain 'serial-getty@*' 2>/dev/null | awk '{ print $1 "/" $4 }' | one)"
kv journal.hung-task.30d "$(journalctl -k --since -30d --no-pager -q 2>/dev/null | grep -c 'blocked for more than')"
kv journal.persistent "$([ -d /var/log/journal ] && echo yes || echo no) $(journalctl --disk-usage 2>/dev/null | grep -o -E '[0-9.]+[KMGT]')"

# ---- storage, swap, disks
if has zpool; then
    kv zfs.health "$(zpool status -x 2>/dev/null | one)"
    kv zfs.pools "$(zpool list -H -o name,size,alloc,cap,health 2>/dev/null | awk '{ printf "%s(%s,%s,%s) ", $1, $2, $4, $5 }')"
    kv zfs.scrub.last "$(zpool status 2>/dev/null | grep -E 'scan:' | sed 's/^ *scan: //' | one)"
    kv zfs.zvols.swap "$(zfs list -H -t volume -o name 2>/dev/null | grep -c swap)"
fi
kv swap.devices "$(swapon --noheadings --show=NAME,SIZE,USED 2>/dev/null | one)"
kv lvm.thin "$(lvs --noheadings -o vg_name,lv_name,lv_attr,data_percent,metadata_percent 2>/dev/null | awk '$3 ~ /^t/ { printf "%s/%s(data %s%%,meta %s%%) ", $1, $2, $4, $5 }')"
kv fs.root.used "$(df -P / | awk 'NR == 2 { print $5 }')"
if has smartctl; then
    for d in $(lsblk -dno NAME,TYPE | awk '$2 == "disk" && $1 !~ /^(zd|rbd|nbd)/ { print $1 }'); do
        h=$(smartctl -H "/dev/$d" 2>/dev/null | grep -E -m1 'overall-health|SMART Health Status' | sed 's/.*: *//')
        w=$(smartctl -A "/dev/$d" 2>/dev/null | awk '/Wear_Leveling_Count|Media_Wearout_Indicator|Percent_Lifetime_Remain/ { print $4; exit } /Percentage Used:/ { print $3; exit }')
        p=$(smartctl -A "/dev/$d" 2>/dev/null | awk '/Power_On_Hours/ { print $10; exit } /Power On Hours:/ { gsub(",", "", $4); print $4; exit }')
        m=$(lsblk -dno MODEL "/dev/$d" | one)
        kv "disk.$d" "$m health=${h:-n/a} wear=${w:-n/a} hours=${p:-n/a}"
    done
fi

# ---- guests, backups, cluster
kv guests.vm "$(qm list 2>/dev/null | awk 'NR > 1 { printf "%s:%s:%s ", $1, $2, $3 }')"
kv guests.ct "$(pct list 2>/dev/null | awk 'NR > 1 { printf "%s:%s ", $1, $2 }')"
ob=
for c in /etc/pve/qemu-server/*.conf; do
    [ -f "$c" ] || continue
    grep -q '^onboot: *1' "$c" && ob="$ob $(basename "$c" .conf)"
done
kv guests.onboot "${ob# }"
kv backup.jobs "$(cat /etc/pve/jobs.cfg 2>/dev/null | grep -c '^vzdump:')"
kv backup.vzdump.cron "$(cat /etc/pve/vzdump.cron 2>/dev/null | grep -c -v -E '^(#|$|PATH)')"
kv storages "$(pvesm status 2>/dev/null | awk 'NR > 1 { printf "%s(%s,%s) ", $1, $2, $3 }')"
if [ -f /etc/pve/corosync.conf ]; then
    kv cluster.quorum "$(pvecm status 2>/dev/null | awk -F': *' '/^Quorate:|^Expected votes:|^Total votes:|^Flags:/ { printf "%s=%s ", $1, $2 }')"
    kv cluster.qdevice "$(systemctl is-active corosync-qdevice 2>/dev/null)"
else
    kv cluster.quorum "standalone"
fi
has corosync-qnetd-tool && kv qnetd.clusters "$(corosync-qnetd-tool -l 2>/dev/null | grep -c '^Cluster')"

# ---- mail, access, hygiene
kv mail.relayhost "$(postconf -h relayhost 2>/dev/null)"
kv mail.root-alias "$(awk -F': *' '$1 == "root" { print $2 }' /etc/aliases 2>/dev/null)"
kv mail.pve-root-email "$(awk -F: '$1 == "user" && $2 == "root@pam" { print ($7 == "" ? "none" : "set") }' /etc/pve/user.cfg 2>/dev/null)"
kv mail.notify-targets "$(awk '/^[a-z-]+: / { printf "%s ", $0 }' /etc/pve/notifications.cfg 2>/dev/null)"
kv mail.queue "$(mailq 2>/dev/null | tail -n1 | one)"
kv ssh.config "$(sshd -T 2>/dev/null | awk '/^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication) / { printf "%s=%s ", $1, $2 }')"
kv ssh.authorized "$(awk '!/^#/ && NF { print $NF }' /root/.ssh/authorized_keys 2>/dev/null | sort | uniq -c | awk '{ printf "%s%s ", $2, ($1 > 1 ? "(x" $1 ")" : "") }')"
kv firewall.pve "$(pve-firewall status 2>/dev/null | one)"
kv firewall.nft.tables "$(nft list tables 2>/dev/null | awk '{ printf "%s:%s ", $2, $3 }')"
kv systemd.failed "$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{ print $1 }' | one)"
kv timers.asyla "$(systemctl list-timers --all --no-legend --plain 'asyla-*' 2>/dev/null | awk '{ print $(NF-1) }' | one)"
kv cron.root "$(crontab -l 2>/dev/null | grep -c -v -E '^(#|$)')"
kv cron.d "$(ls /etc/cron.d 2>/dev/null | one)"
kv stale.root.big "$(find /root -xdev -type f -size +100M -printf '%f(%sB,%TY-%Tm) ' 2>/dev/null | sed 's/\([0-9]\{1,\}\)[0-9]\{6\}B/\1M/g')"
kv stale.root.dirs "$(find /root -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%f(%TY) ' 2>/dev/null)"
kv stale.snippets "$(find /var/lib/vz/snippets -type f -printf '%f(%TY-%Tm) ' 2>/dev/null)"
kv stale.var-log.big "$(find /var/log -xdev -path /var/log/journal -prune -o -type f -size +100M -printf '%p(%sB) ' 2>/dev/null | sed 's/\([0-9]\{1,\}\)[0-9]\{6\}B/\1M/g')"
kv stale.usr-local "$(find /usr/local/sbin /usr/local/bin -type f -printf '%f ' 2>/dev/null)"
kv stale.units.local "$(find /etc/systemd/system -maxdepth 1 -type f -name '*.service' -printf '%f ' 2>/dev/null)"
exit 0
