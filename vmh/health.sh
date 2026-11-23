#!/bin/sh
# Read-only health of one Proxmox VE node (vmh01, vmh02, vmh03). Installed by vmh/setup.sh (part
# health) as /usr/local/sbin/asyla-vmh-health; host-maintenance's monitor runs it over SSH with a
# forced-command key. Changes nothing on the node; its only writes are its own state in
# /var/lib/asyla-vmh-health (a journal cursor, held kernel findings, SMART counters by serial).
# One line per check, tab-separated:
#   STATUS<TAB>KEY<TAB>DETAIL      STATUS is ok, warn or crit
# Exit 0 always (the caller reads the lines); 2 if this is not a Proxmox node.
set -u

r() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
has() { command -v "$1" >/dev/null 2>&1; }
one() { tr '\n' ' ' | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//'; }

# The last real unattended-upgrades run in LOG: "START<TAB>OUTCOME LINE", START as YYYY-MM-DD HH:MM:SS.
# A --dry-run also logs "All upgrades installed" (vmh02, 2026-10-24); apt-daily's download-only run
# logs "Starting" and no outcome (vmh01, 2026-11-02 03:36). Only runs with an outcome count.
uu_last_run() {
    awk '/INFO Starting unattended upgrades script/ { dry = 0; st = $1 " " substr($2, 1, 8) }
        /Option --dry-run given/ { dry = 1 }
        !dry && /INFO (No packages found|All upgrades installed)|ERROR/ { s = st; l = $0 }
        END { if (l != "") printf "%s\t%s\n", s, l }' "$1" 2>/dev/null
}

# The apt line. Security packages pending on production warn only once the last unattended-upgrades
# run started after the lists that offer them were fetched: until then they are waiting for the
# morning run, not missed by it (vmh01/vmh02, 2026-11-02: vim-common, vim-tiny, xxd fetched 03:36,
# installed 06:37). With no run in 36 hours they warn anyway.
# Args: ROLE N SECURITY LISTS_FRESH(0|1) RUN_EPOCH(empty: none) FETCHED_EPOCH NOW_EPOCH RUN_START
apt_verdict() {
    local role="$1" n="$2" s="$3" fresh="$4" run="$5" fetched="${6:-0}" now="$7" when="$8"
    if [ "$fresh" -eq 0 ]; then r warn apt "package lists older than 3 days"
    elif [ "$s" -eq 0 ] || [ "$role" != production ]; then r ok apt "$n upgradable, $s security"
    elif [ -z "$run" ]; then r warn apt "$n upgradable, $s from security; no unattended-upgrades run logged"
    elif [ $((now - run)) -gt 129600 ]; then r warn apt "$n upgradable, $s from security; no unattended-upgrades run since $when"
    elif [ "$fetched" -gt "$run" ]; then r ok apt "$n upgradable, $s security, fetched after the $when run: for the next unattended-upgrades run"
    else r warn apt "$n upgradable, $s from security, still pending after the $when unattended-upgrades run"; fi
}

# ---- kernel log patterns and SMART by serial (asyla #610 step 2)
# py MODE STATE_DIR NOW_EPOCH ARGS...: the kernel and SMART checks, in python3 for smartctl's JSON and
# for the same regex engine as the asyla hub's tools/export_nas_smart.py (#610 step 1, proved on
# nas01's 2026-10-20 kern.log), whose KERN_PATTERNS, KERN_DEVICE and severities PATTERNS and DEVICE
# copy: keep the two lists the same. "urgent" there prints crit here; the monitor sends crit as urgent.
#   py kern STATE NOW LINES [NOTE]   LINES: journal lines (short-iso, UTC) since the last run. Each
#                                    match is held in STATE/kern-held.json, keyed by kind and device,
#                                    for 24 h after its last line, so a run every 15 min keeps it open.
#   py smart STATE NOW JSON...       one `smartctl --json -a` per disk, the file named DEV.json. Keys
#                                    by serial (device names move between boots); counters per serial
#                                    in STATE/smart.json, so a rise warns for 7 days.
py() {
    python3 -I - "$@" <<'PY'
import datetime, json, os, re, sys

HOLD_H = 24
RISE_WINDOW_H = 7 * 24
SAMPLE = 160
NVME_WEAR_WARN = 80       # percent used, as nas01
WEAR_LEFT_WARN = 10       # ATA wear indicator, normalised value
TEMP_WARN_C = {"ssd": 70, "hdd": 55}  # when the drive reports no operating limit of its own

PATTERNS = [(k, s, l, re.compile(p)) for k, s, l, p in (
    ("nic-removed", "urgent", "NIC or PCIe adapter removed", r"Adapter removed|pciehp\b.*Card not present"),
    ("nvme-removed", "urgent", "NVMe controller removed",
     r"\bnvme\d*\S*: .*(Removing after probe failure|Disabling device after reset failure)"),
    ("pool-suspended", "urgent", "ZFS pool suspended",
     r"has encountered an uncorrectable I/O failure and has been suspended"),
    ("nic-ecc", "warn", "NIC internal ECC error", r"Received ECC Err"),
    ("nic-reset", "warn", "NIC adapter reset or hang",
     r"Reset adapter|RXDCTL\.ENABLE .*not cleared|Detected Tx Unit Hang|NETDEV WATCHDOG|transmit queue \d+ timed out"),
    ("nic-firmware", "warn", "NIC firmware error", r"firmware error detected"),
    ("pcie-aer", "warn", "PCIe AER error", r"\bAER: .*error received|PCIe Bus Error"),
    ("hw-error", "warn", "machine check or hardware error",
     r"\[Hardware Error\]|Machine check events logged|\bEDAC \S+: .*\b[CU]E\b"),
    ("ata-scsi", "warn", "ATA or SCSI error or reset",
     r"\bata\d+(\.\d+)?: (hard resetting link|SError|exception Emask|failed command|COMRESET failed"
     r"|link is slow to respond)|\bsd \d+:\d+:\d+:\d+: .*(FAILED Result|timing out command|abort)"
     r"|\bmpt[23]sas_cm\d+: .*fault_state|\btask abort\b"),
    ("nvme-timeout", "warn", "NVMe timeout or controller reset",
     r"\bnvme\d*\S*: .*(I/O \d+ (\(\S+\) )?QID \d+ timeout|controller is down|resetting controller)"),
    ("io-error", "warn", "block I/O error",
     r"I/O error, dev |Buffer I/O error|critical medium error|Medium Error|Unrecovered read error"),
    ("zio-error", "warn", "ZFS I/O error", r"\bzio pool="),
    ("fs-error", "warn", "filesystem error",
     r"EXT4-fs error|XFS \(\S+\): .*(Corruption|metadata I/O error|Internal error)|BTRFS (error|critical)"),
    ("nfsd-error", "warn", "NFS server error",
     r"\bnfsd: .*(error|failed|too many)|\bNFSD: .*(failed|error)|rpc-srv/\w+: nfsd: (got error|sent \d+ when)"
     r"|\blockd: .*(failed|cannot)"),
    ("oom", "warn", "out of memory kill", r"Out of memory: Kill|oom-kill:|invoked oom-killer"),
    ("kernel-fault", "warn", "kernel oops, lockup or hung task",
     r"kernel BUG at|general protection fault|\bOops: |soft lockup|hard LOCKUP|blocked for more than \d+ seconds"
     r"|rcu\S*: .*detected stalls?|Kernel panic"),
)]
DEVICE = [re.compile(p) for p in (
    r"\b([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])\b", r"\bdev (\w+)", r"\[(sd[a-z]+|nvme\d+n\d+)\]",
    r"\b(nvme\d+)(?:n\d+)?\b", r"\b(ata\d+)(?:\.\d+)?:", r"\bsd (\d+:\d+:\d+:\d+)", r"\bzio pool=(\S+)",
    r"Pool '([^']+)'", r"\b(mpt[23]sas_cm\d+)")]
# ATA attribute id -> counter. A rise in any counter warns for RISE_WINDOW_H; pending above 0 warns.
ATA_COUNTERS = {5: "reallocated_sectors", 197: "pending_sectors", 198: "offline_uncorrectable",
                187: "reported_uncorrect", 199: "crc_errors"}
RISE = ("reallocated_sectors", "offline_uncorrectable", "reported_uncorrect", "crc_errors", "nvme_media_errors")
WEAR_NAMES = re.compile(r"Wear_Leveling_Count|Media_Wearout_Indicator|Percent_Lifetime_Remain")


def out(status, key, detail):
    """One STATUS<TAB>KEY<TAB>DETAIL line; a tab or newline in DETAIL (a kernel line) becomes a space."""
    detail = re.sub(r"\s+", " ", str(detail)).strip()
    print(f"{status}\t{key}\t{detail}")


def keypart(s):
    return re.sub(r"[^A-Za-z0-9_.:-]", "_", str(s))


def when(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%d %H:%MZ")


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save(path, data):
    with open(path + ".new", "w") as f:
        json.dump(data, f, sort_keys=True)
    os.replace(path + ".new", path)


def match(line):
    """(kind, severity, label, device) for the first PATTERNS entry LINE matches, else None."""
    for kind, sev, label, rx in PATTERNS:
        if rx.search(line):
            for d in DEVICE:
                m = d.search(line)
                if m:
                    return kind, sev, label, m.group(1)
            return kind, sev, label, "-"
    return None


def kern(state, now, lines_path, note=""):
    path = os.path.join(state, "kern-held.json")
    held, new, hits = load(path), 0, 0
    with open(lines_path, errors="replace") as f:
        for line in f:
            if line.startswith("-- cursor: ") or not line.strip():
                continue
            new += 1
            m = match(line)
            if not m:
                continue
            kind, sev, label, dev = m
            hits += 1
            s = re.match(r"^\d{4}-(\d\d-\d\d)T(\d\d:\d\d:\d\d)", line)
            stamp = f"{s.group(1)} {s.group(2)}Z" if s else "?"
            key = f"kern.{kind}" + (f".{keypart(dev)}" if dev != "-" else "")
            h = held.setdefault(key, {"severity": sev, "label": label, "device": dev, "count": 0, "first": stamp})
            h.update(count=h["count"] + 1, last=stamp, seen=now, sample=line.strip()[:SAMPLE])
    for k in [k for k, h in held.items() if now - h.get("seen", 0) > HOLD_H * 3600]:
        del held[k]
    save(path, held)
    out("ok", "kern", note or f"{new} new kernel line(s), {hits} matched, {len(held)} held for {HOLD_H} h")
    for k in sorted(held):
        h = held[k]
        out("crit" if h["severity"] == "urgent" else "warn", k,
            f"{h['label']} on {h['device']}: {h['count']} line(s), {h['first']} to {h['last']}: {h['sample']}")


def raw_count(a):
    """An ATA counter's raw: the leading number of its string (vendors pack more into the value)."""
    m = re.match(r"\s*(\d+)", str(a.get("raw", {}).get("string", "")))
    return int(m.group(1)) if m else a.get("raw", {}).get("value")


def smart(state, now, files):
    path = os.path.join(state, "smart.json")
    st = load(path)
    for fp in files:
        dev = os.path.basename(fp)[:-len(".json")]
        try:
            with open(fp) as f:
                d = json.load(f)
        except (OSError, ValueError):
            out("warn", f"disk.{keypart(dev)}", f"/dev/{dev}: smartctl gave no JSON")
            continue
        rc = d.get("smartctl", {}).get("exit_status", 1)
        serial = str(d.get("serial_number", "")).strip()
        if rc & 0b11 or not serial or "device" not in d:
            msgs = " ".join(m.get("string", "") for m in d.get("smartctl", {}).get("messages", []))
            out("warn", f"disk.{keypart(dev)}", f"/dev/{dev}: SMART not read: smartctl exit {rc} {msgs}")
            continue
        key, who = "disk." + keypart(serial), f"{d.get('model_name', '?')} /dev/{dev}"
        proto, v, used, wear, cw = d["device"].get("protocol"), {}, None, None, 0
        if proto == "ATA":
            for a in d.get("ata_smart_attributes", {}).get("table", []):
                if a.get("id") in ATA_COUNTERS:
                    v[ATA_COUNTERS[a["id"]]] = raw_count(a)
                elif wear is None and WEAR_NAMES.search(a.get("name", "")):
                    wear = a.get("value")
        elif proto == "NVMe":
            log = d.get("nvme_smart_health_information_log", {})
            used, cw = log.get("percentage_used"), log.get("critical_warning", 0)
            v["nvme_media_errors"] = log.get("media_errors")
        elif "scsi_grown_defect_list" in d:
            v["reallocated_sectors"] = d["scsi_grown_defect_list"]
        t = d.get("temperature", {})
        temp = t.get("current")
        limit = (t.get("op_limit_max") or d.get("nvme_composite_temperature_threshold", {}).get("warning")
                 or TEMP_WARN_C["ssd" if proto == "NVMe" or d.get("rotation_rate") == 0 else "hdd"])
        passed = d.get("smart_status", {}).get("passed")
        detail = (f"{'PASSED' if passed else 'FAILED' if passed is False else 'n/a'} {who}"
                  + (f" used={used}%" if used is not None else "") + (f" wear={wear}" if wear is not None else "")
                  + (f" {round(temp * 9 / 5 + 32)}F" if temp is not None else ""))
        if passed is False:
            out("crit", key, detail)
        elif (used is not None and used >= NVME_WEAR_WARN) or (wear is not None and wear <= WEAR_LEFT_WARN):
            out("warn", key, detail)
        else:
            out("ok", key, detail)
        if cw:
            out("crit", key + ".nvme-critical", f"{who}: NVMe critical warning 0x{cw:02x}")
        if (v.get("pending_sectors") or 0) > 0:
            out("warn", key + ".pending", f"{who}: {v['pending_sectors']} pending sector(s)")
        if temp is not None and temp >= limit:
            out("warn", key + ".temp", f"{who}: {round(temp * 9 / 5 + 32)}F, at or over its {round(limit * 9 / 5 + 32)}F limit")
        s = st.setdefault(serial, {})
        s["seen"] = now
        for k in RISE:
            val = v.get(k)
            if val is None:
                continue
            prev = s.get(k)
            rose = prev.get("rose_at") if prev else None
            if prev is not None and val > prev["value"]:
                rose = now
            s[k] = {"value": val, "rose_at": rose}
            if rose is not None and now - rose < RISE_WINDOW_H * 3600:
                out("warn", f"{key}.{k.replace('_', '-')}", f"{who}: {k.replace('_', ' ')} rose to {val} at {when(rose)}")
    for k in [k for k, s in st.items() if now - s.get("seen", 0) > 30 * 86400]:
        del st[k]
    save(path, st)


mode, state, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
os.makedirs(state, mode=0o700, exist_ok=True)
if mode == "kern":
    kern(state, now, *sys.argv[4:6])
elif mode == "smart":
    smart(state, now, sys.argv[4:])
else:
    sys.exit(f"py: unknown mode {mode}")
PY
}

# kern_check STATE NOW: the kernel journal (_TRANSPORT=kernel, the lines -k shows, but across boots, so
# lines just before a crash or reboot are read after it) since the cursor in STATE/kern.cursor. The
# vmh nodes keep no kern.log (vmh01/vmh02 stopped writing theirs on 2026-10-24; vmh03 has none). The
# first run only sets the cursor. The cursor moves only after py has held the lines' matches.
kern_check() {
    local state="$1" now="$2" cf="$1/kern.cursor" lines="$1/kern.lines" c
    has python3 || { r warn kern "python3 not found: kernel patterns not checked"; return; }
    mkdir -p "$state" && chmod 700 "$state" || { r warn kern "state directory $state not writable"; return; }
    if ! [ -s "$cf" ]; then
        c=$(journalctl -k -n 0 --show-cursor --no-pager -q 2>/dev/null | sed -n 's/^-- cursor: //p' | tail -n1)
        [ -n "$c" ] || { r warn kern "journal not read: no cursor from journalctl -k"; return; }
        : >"$lines"
        py kern "$state" "$now" "$lines" "first run: cursor set at the end of the journal; later runs read from here" \
            && printf '%s\n' "$c" >"$cf"
        return
    fi
    if ! journalctl _TRANSPORT=kernel --after-cursor="$(cat "$cf")" --show-cursor -o short-iso --utc --no-pager -q \
        >"$lines" 2>"$lines.err"; then
        r warn kern "journal not read after the saved cursor: $(one <"$lines.err" | cut -c1-160) (remove $cf to restart from now)"
        return
    fi
    c=$(sed -n 's/^-- cursor: //p' "$lines" | tail -n1)
    py kern "$state" "$now" "$lines" && [ -n "$c" ] && printf '%s\n' "$c" >"$cf.new" && mv "$cf.new" "$cf"
}

# disk_check STATE NOW: one `smartctl --json -a` per whole disk (not zvols, rbd, nbd or loop), then py smart.
disk_check() {
    local state="$1" now="$2" dir="$1/smart" d
    has smartctl || return 0
    has python3 || { r warn smart "python3 not found: SMART not checked"; return; }
    mkdir -p "$dir" && chmod 700 "$state" || { r warn smart "state directory $state not writable"; return; }
    rm -f "$dir"/*.json
    for d in $(lsblk -dno NAME,TYPE | awk '$2 == "disk" && $1 !~ /^(zd|rbd|nbd|loop)/ { print $1 }'); do
        smartctl --json -a "/dev/$d" >"$dir/$d.json" 2>/dev/null
    done
    set -- "$dir"/*.json
    [ -e "$1" ] || return 0
    py smart "$state" "$now" "$@"
}

# Tests source this file for the functions above only (scripts/tests/test_vmh_health_sh.sh).
[ "${ASYLA_VMH_HEALTH_FUNCTIONS_ONLY:-}" = 1 ] && return 0

[ "$(id -u)" = 0 ] || { echo "asyla-vmh-health: run as root" >&2; exit 2; }
command -v pveversion >/dev/null 2>&1 || { echo "asyla-vmh-health: not a Proxmox VE host" >&2; exit 2; }

node=$(hostname -s)
case "$node" in
    vmh01|vmh02) role=production; nc_to=10.0.0.37 ;;
    vmh03) role=canary; nc_to= ;;
    *) role=unknown; nc_to= ;;
esac

r ok node "$node $role pve $(pveversion | sed 's#^pve-manager/##; s#/.*##') up $(awk '{ printf "%d", $1 / 86400 }' /proc/uptime)d"

# ---- storage
if has zpool; then
    s=$(zpool status -x 2>&1 | one)
    case "$s" in "all pools are healthy"|"no pools available") r ok zfs "$s" ;; *) r crit zfs "$s" ;; esac
fi
# The only state health keeps (#610): the kernel journal cursor, kernel findings held for 24 h, and
# each disk serial's counters. One run at a time holds it (the monitor every 15 min, apply.sh health).
STATE=/var/lib/asyla-vmh-health
now=$(date +%s)
mkdir -p "$STATE" && chmod 700 "$STATE"
if exec 9>"$STATE/lock" && { ! has flock || flock -w 60 9; }; then
    disk_check "$STATE" "$now"
    kern_check "$STATE" "$now"
else
    r warn kern "another health run held $STATE/lock for 60 s: kernel and SMART not checked"
fi
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
# Hung tasks are kern.kernel-fault now (kern_check, above).
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
uu=$(uu_last_run /var/log/unattended-upgrades/unattended-upgrades.log)
start=$(printf '%s' "$uu" | cut -f1)
last=$(printf '%s' "$uu" | cut -f2-)
case "$last" in
    *ERROR*) r warn unattended-upgrades "last run: $last" ;;
    "") has unattended-upgrade && r warn unattended-upgrades "no run logged yet" ;;
    *) r ok unattended-upgrades "last run $(printf '%s' "$last" | cut -c1-10)${up:+, last install $up}" ;;
esac
sim=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null)
n=$(printf '%s\n' "$sim" | grep -c '^Inst ')
s=$(printf '%s\n' "$sim" | grep '^Inst ' | grep -c -- '-security')
lists=$(find /var/lib/apt/lists -maxdepth 1 -name '*_InRelease' -mtime -3 2>/dev/null | wc -l)
# Fetched = ctime: apt sets an index's mtime to the server's Last-Modified (vmh01 2026-11-02, the
# security InRelease: mtime 11-01 14:43, fetched 11-02 03:36).
fetched=$(find /var/lib/apt/lists -maxdepth 1 -name '*security*_InRelease' -printf '%C@\n' 2>/dev/null | sort -n | tail -n1)
[ -n "$fetched" ] || fetched=$(find /var/lib/apt/lists -maxdepth 1 -name '*_InRelease' -printf '%C@\n' 2>/dev/null | sort -n | tail -n1)
run=; [ -n "$start" ] && run=$(date -d "$start" +%s 2>/dev/null)
apt_verdict "$role" "$n" "$s" "$([ "$lists" -gt 0 ] && echo 1 || echo 0)" "$run" "${fetched%.*}" "$(date +%s)" "$(printf '%s' "$start" | cut -c1-16)"

# ---- clock
[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && r ok time "NTP synchronized" || r warn time "clock not NTP-synchronized"
exit 0
