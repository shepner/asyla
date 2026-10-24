#!/bin/sh
# Read-only health of one Proxmox VE node (vmh01, vmh02, vmh03). Installed by vmh/setup.sh (part
# health) as /usr/local/sbin/asyla-vmh-health; host-maintenance's monitor runs it over SSH with a
# forced-command key. Changes nothing. One line per check, tab-separated:
#   STATUS<TAB>KEY<TAB>DETAIL      STATUS is ok, warn or crit
# Exit 0 always (the caller reads the lines); 2 if this is not a Proxmox node.
set -u

[ "$(id -u)" = 0 ] || { echo "asyla-vmh-health: run as root" >&2; exit 2; }
command -v pveversion >/dev/null 2>&1 || { echo "asyla-vmh-health: not a Proxmox VE host" >&2; exit 2; }

node=$(hostname -s)
case "$node" in
    vmh01|vmh02) role=production; nc_to=10.0.0.37 ;;
    vmh03) role=canary; nc_to= ;;
    *) role=unknown; nc_to= ;;
esac

r() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
has() { command -v "$1" >/dev/null 2>&1; }
one() { tr '\n' ' ' | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//'; }

r ok node "$node $role pve $(pveversion | sed 's#^pve-manager/##; s#/.*##') up $(awk '{ printf "%d", $1 / 86400 }' /proc/uptime)d"

# ---- storage
if has zpool; then
    s=$(zpool status -x 2>&1 | one)
    case "$s" in "all pools are healthy"|"no pools available") r ok zfs "$s" ;; *) r crit zfs "$s" ;; esac
fi
for d in $(lsblk -dno NAME,TYPE | awk '$2 == "disk" && $1 !~ /^(zd|rbd|nbd|loop)/ { print $1 }'); do
    has smartctl || break
    h=$(smartctl -H "/dev/$d" 2>/dev/null | grep -E -m1 'overall-health|SMART Health Status' | sed 's/.*: *//')
    used=$(smartctl -A "/dev/$d" 2>/dev/null | awk '/Percentage Used:/ { gsub("%", "", $3); print $3; exit }')
    wear=$(smartctl -A "/dev/$d" 2>/dev/null | awk '/Wear_Leveling_Count|Media_Wearout_Indicator|Percent_Lifetime_Remain/ { print $4 + 0; exit }')
    detail="${h:-n/a}${used:+ used=$used%}${wear:+ wear=$wear}"
    if [ -n "$h" ] && [ "$h" != PASSED ] && [ "$h" != OK ]; then r crit "disk.$d" "$detail"
    elif [ -n "$used" ] && [ "$used" -ge 90 ]; then r warn "disk.$d" "$detail"
    elif [ -n "$wear" ] && [ "$wear" -le 10 ]; then r warn "disk.$d" "$detail"
    else r ok "disk.$d" "$detail"; fi
done
p=$(df -P / | awk 'NR == 2 { sub("%", "", $5); print $5 }')
if [ "$p" -ge 93 ]; then r crit fs.root "$p% used"; elif [ "$p" -ge 85 ]; then r warn fs.root "$p% used"; else r ok fs.root "$p% used"; fi
for v in $(lvs --noheadings -o vg_name,lv_name,lv_attr,data_percent 2>/dev/null | awk '$3 ~ /^t/ { printf "%s/%s=%d\n", $1, $2, $4 }'); do
    n=${v#*=}
    if [ "$n" -ge 90 ]; then r crit "thin.${v%=*}" "$n% data"; elif [ "$n" -ge 80 ]; then r warn "thin.${v%=*}" "$n% data"; else r ok "thin.${v%=*}" "$n% data"; fi
done
# Swap on a ZFS zvol is where the 2026-05-24 vmh02 deadlock started; any real use of it is worth a look.
z=$(swapon --noheadings --bytes --show=NAME,USED 2>/dev/null | awk '$1 ~ /^\/dev\/zd/ { u += $2 } END { printf "%d", u / 1048576 }')
if [ -n "$z" ] && [ "$z" -ge 1024 ]; then r warn swap.zvol "${z} MiB used on a zvol"; fi

# ---- services and PVE
f=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{ print $1 }' | one)
[ -z "$f" ] && r ok systemd "no failed units" || r warn systemd "failed: $f"
if [ -f /etc/pve/corosync.conf ]; then
    q=$(pvecm status 2>/dev/null)
    quorate=$(printf '%s\n' "$q" | awk -F': *' '/^Quorate:/ { print $2 }')
    flags=$(printf '%s\n' "$q" | awk -F': *' '/^Flags:/ { print $2 }')
    votes=$(printf '%s\n' "$q" | awk -F': *' '/^Total votes:|^Expected votes:/ { printf "%s=%s ", $1, $2 }')
    if [ "$quorate" != Yes ]; then r crit cluster "not quorate: $votes$flags"
    else r ok cluster "quorate $votes$flags"; fi
    # Members: every node in corosync.conf online, and the nodelist is the one vmc01 should have.
    want="vmh01 vmh02 vmh03"
    conf=$(awk '$1 == "name:" { print $2 }' /etc/pve/corosync.conf | sort | one)
    online=$(pvecm nodes 2>/dev/null | awk '$1 ~ /^[0-9]+$/ { print $3 }' | sort | one)
    off=$(for n in $conf; do case " $online " in (*" $n "*) ;; (*) printf '%s ' "$n" ;; esac; done | one)
    if [ -z "$online" ]; then r warn members "pvecm nodes listed no members"
    elif [ -n "$off" ]; then r warn members "offline: $off (online: $online)"
    elif [ "$conf" != "$want" ]; then r warn members "configured: $conf; expected $want"
    else r ok members "$online online"; fi
    if systemctl -q is-enabled corosync-qdevice 2>/dev/null; then
        case "$flags" in *Qdevice*) r ok qdevice "Qdevice in flags" ;; *) r warn qdevice "corosync-qdevice enabled but no Qdevice flag: $flags" ;; esac
    fi
fi
if [ "$node" = vmh03 ] && has corosync-qnetd-tool; then
    r warn qnetd "corosync-qnetd still installed; vmh03 is a member now (vmh03/apply.sh remove-qnetd)"
fi
since=$(( $(date +%s) - 86400 ))
te=$(pvesh get "/nodes/$node/tasks" --errors 1 --since "$since" --limit 100 --output-format json 2>/dev/null \
    | grep -o '"type":"[^"]*"' | sed 's/"type":"//; s/"//' | sort | uniq -c | awk '{ printf "%s x%s ", $2, $1 }')
[ -z "$te" ] && r ok tasks "no failed PVE tasks in 24h" || r warn tasks "failed PVE tasks in 24h: $te"

# ---- kernel, reboot, crash capture
running=$(uname -r)
pinned=$(proxmox-boot-tool kernel list 2>/dev/null | awk '/^Pinned kernel:/ { getline; print $1 }')
newest=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'proxmox-kernel-*-pve-signed' 'proxmox-kernel-*-pve' 2>/dev/null \
    | awk '$1 ~ /^ii/ { sub(/^proxmox-kernel-/, "", $2); sub(/-signed$/, "", $2); print $2 }' | sort -V | tail -n1)
boots=${pinned:-$newest}
if [ -n "$boots" ] && [ "$boots" != "$running" ]; then r warn kernel "running $running, next boot $boots${pinned:+ (pinned)}"
else r ok kernel "running $running${pinned:+ (pinned)}"; fi
[ -e /run/reboot-required ] && r warn reboot "/run/reboot-required: $(one </run/reboot-required.pkgs 2>/dev/null)"
if [ "$role" != unknown ]; then
    if [ "$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null)" = 1 ]; then
        r ok kdump "loaded, $(awk '{ printf "%d", $1 / 1048576 }' /sys/kernel/kexec_crash_size) MiB"
    else
        r warn kdump "not loaded (crashkernel reserved: $(awk '{ printf "%d", $1 / 1048576 }' /sys/kernel/kexec_crash_size 2>/dev/null) MiB)"
    fi
fi
dumps=$(find /var/crash -mindepth 1 -maxdepth 1 -type d -newermt '-30 days' 2>/dev/null | sed 's#.*/##' | one)
[ -n "$dumps" ] && r warn crash.dump "kdump saved a crash in the last 30 days: $dumps (/var/crash)"
# By the record's own file (dmesg-efi-*, dmesg-erst-*: the crash's date), not the directory, which is
# the date systemd-pstore archived it: vmh02's 2026-05-29 ERST record came out at the 2026-10-24 boot.
pstore=$(find /var/lib/systemd/pstore -mindepth 2 -maxdepth 2 -type f ! -name dmesg.txt -newermt '-30 days' \
    -printf '%h\n' 2>/dev/null | sort -u | wc -l)
[ "$pstore" -gt 0 ] && r warn crash.pstore "$pstore pstore record(s) in the last 30 days"
ht=$(journalctl -k --since -24h --no-pager -q 2>/dev/null | grep -c 'blocked for more than')
[ "$ht" -gt 0 ] && r warn hung-task "$ht hung-task warning(s) in 24h"
if [ -n "$nc_to" ]; then
    d=/sys/kernel/config/netconsole/asyla
    if [ "$(cat "$d/enabled" 2>/dev/null)" = 1 ]; then r ok netconsole "-> $(cat "$d/remote_ip"):$(cat "$d/remote_port")"
    else r warn netconsole "no netconsole target to $nc_to"; fi
fi
if [ "$role" = canary ]; then
    systemctl -q is-active asyla-netconsole-rx 2>/dev/null && r ok netconsole-rx "active" || r warn netconsole-rx "asyla-netconsole-rx not active"
    for l in /var/log/netconsole/*.log; do
        [ -f "$l" ] || continue
        n=$(grep -c -E 'Kernel panic|BUG:|Oops|blocked for more than|Call Trace' "$l")
        [ "$n" -gt 0 ] && r warn "netconsole.${l##*/}" "$n panic/oops/hung-task line(s) received; see $l on vmh03"
    done
fi

# ---- updates
up=$(sed -n 's/^Start-Date: \([0-9-]*\).*/\1/p' /var/log/unattended-upgrades/unattended-upgrades-dpkg.log 2>/dev/null | tail -n1)
last=$(grep -h -E 'INFO (No packages found|All upgrades installed)|ERROR' /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null | tail -n1)
case "$last" in
    *ERROR*) r warn unattended-upgrades "last run: $last" ;;
    "") has unattended-upgrade && r warn unattended-upgrades "no run logged yet" ;;
    *) r ok unattended-upgrades "last run $(printf '%s' "$last" | cut -c1-10)${up:+, last install $up}" ;;
esac
sim=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null)
n=$(printf '%s\n' "$sim" | grep -c '^Inst ')
s=$(printf '%s\n' "$sim" | grep '^Inst ' | grep -c -- '-security')
lists=$(find /var/lib/apt/lists -maxdepth 1 -name '*_InRelease' -mtime -3 2>/dev/null | wc -l)
if [ "$lists" -eq 0 ]; then r warn apt "package lists older than 3 days"
elif [ "$s" -gt 0 ] && [ "$role" = production ]; then r warn apt "$n upgradable, $s from security (unattended-upgrades should have taken these)"
else r ok apt "$n upgradable, $s security"; fi

# ---- clock
[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && r ok time "NTP synchronized" || r warn time "clock not NTP-synchronized"
exit 0
