#!/bin/sh
# Read-only health of one Proxmox VE node (vmh01, vmh02, vmh03). Installed by vmh/setup.sh (part
# health) as /usr/local/sbin/asyla-vmh-health; host-maintenance's monitor runs it over SSH with a
# forced-command key. Changes nothing on the node; its only writes are its own state in
# /var/lib/asyla-vmh-health (a journal cursor, held kernel findings, SMART counters by serial, BMC
# SEL hashes and held SEL findings) and the asyla_hw_* textfile
# /var/lib/prometheus/node-exporter/asyla-vmh-health.prom (#610 step 5, hw_textfile below).
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
#   py bmc-need STATE INFO           exit 0 when `sel elist` is needed (INFO: `sel info` output)
#   py bmc STATE NOW INFO ELIST SDR  the BMC's SEL and sensors (#610 step 3, as the hub's bmc_health);
#                                    SEL hashes and held findings in STATE/bmc.json. A file is "-" when
#                                    not read. A new SEL entry that is critical or non-recoverable is
#                                    crit, any other warns, held 24 h; the first read only remembers the
#                                    SEL. A sensor at cr/nr/lcr/ucr/lnr/unr is crit, nc/lnc/unc warns
#                                    (live, not held); ns is not judged.
py() {
    python3 -I - "$@" <<'PY'
import datetime, hashlib, json, os, re, sys

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
# BMC (#610 step 3), copied from the hub's tools/export_nas_smart.py (SEL_CRIT, SDR_STATUS, SDR_*_STATE):
# keep the two the same. SEL event text that is critical or non-recoverable; any other new entry warns.
SEL_CRIT = re.compile(r"Uncorrectable|Non-recoverable|\b(?:Lower|Upper) Critical going|Failure detected|AC lost"
                      r"|Redundancy Lost|Critical Interrupt|Bus Fatal|\bIERR\b|Thermal Trip|\bFRB[123]\b", re.I)
# `sdr elist` status column; ns (no reading) is not judged.
SDR_STATUS = {"nr": "urgent", "lnr": "urgent", "unr": "urgent", "cr": "urgent", "lcr": "urgent", "ucr": "urgent",
              "nc": "warn", "lnc": "warn", "unc": "warn"}
SDR_CRIT_STATE = re.compile(r"Failure detected|AC lost|Redundancy Lost|Uncorrectable|Non-recoverable", re.I)
SDR_WARN_STATE = re.compile(r"Predictive Failure|Drive Fault|Redundancy Degraded", re.I)
SEL_FP = ("Entries", "Last Add Time", "Last Del Time")


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


def bkey(s):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", s).strip("_") or "-"


def read(p):
    with open(p, errors="replace") as f:
        return f.read()


def sel_info(text):
    """`ipmitool sel info`: {label: value} for its "Label : value" lines."""
    return {m.group(1).strip(): m.group(2).strip() for m in re.finditer(r"^([A-Za-z][\w ]*?)\s*: (.*)$", text, re.M)}


def sel_fp(si):
    return "|".join(si.get(k, "") for k in SEL_FP)


def sel_entries(text):
    """`ipmitool sel elist`: "%4x | date | time | sensor | event | Asserted[ | Reading ...]"; a pre-init
    stamp prints "Pre-Init" and the raw stamp. vmh01/vmh02 (2026-11-22): two-digit years, the sensor
    field is the type only, the event can be empty or "()"."""
    out_ = []
    for line in text.splitlines():
        f = [p.strip() for p in line.split("|")]
        if len(f) < 5 or not re.fullmatch(r"[0-9a-fA-F]+", f[0]):
            continue
        out_.append({"when": f"{f[1]} {f[2]}", "sensor": f[3], "event": f[4], "dir": f[5] if len(f) > 5 else "",
                     "line": " | ".join(f), "hash": hashlib.sha256("|".join(f[:6]).encode()).hexdigest()[:16]})
    return out_


def bmc_need(state, info_path):
    """Exit 0 when `sel elist` is needed: no SEL remembered yet, or sel info's count or times changed."""
    st, si = load(os.path.join(state, "bmc.json")), sel_info(read(info_path))
    sys.exit(0 if "seen" not in st or not si.get("Entries") or sel_fp(si) != st.get("info") else 1)


def bmc(state, now, info_path, elist_path, sdr_path):
    """INFO, ELIST, SDR: ipmitool output files, or "-" when not read (bmc_check printed why). The first
    SEL read only remembers its entries (by hash); a later new entry is held HOLD_H by sensor and event."""
    path = os.path.join(state, "bmc.json")
    st = load(path)
    held = st.setdefault("held", {})
    n_sel, n_new = "?", 0
    if info_path != "-":
        si = sel_info(read(info_path))
        n_sel = si.get("Entries", "?")
        if si.get("Overflow") == "true":
            out("warn", "bmc.sel-full", f"BMC SEL is full ({si.get('Percent Used', '?')} used): new events are dropped")
        if elist_path != "-":
            entries = sel_entries(read(elist_path))
            new = [e for e in entries if e["hash"] not in set(st["seen"])] if "seen" in st else []
            st["seen"], st["info"], n_new = sorted({e["hash"] for e in entries}), sel_fp(si), len(new)
            for e in new:
                sev = "warn" if e["dir"] == "Deasserted" or not SEL_CRIT.search(e["event"]) else "urgent"
                h = held.setdefault(f"bmc.sel.{bkey(e['sensor'])}.{bkey(e['event'])}",
                                    {"severity": sev, "sensor": e["sensor"], "event": e["event"], "count": 0,
                                     "first": e["when"]})
                if sev == "urgent":
                    h["severity"] = "urgent"
                h.update(count=h["count"] + 1, last=e["when"], seen=now, sample=e["line"][:SAMPLE])
    for k in [k for k, h in held.items() if now - h.get("seen", 0) > HOLD_H * 3600]:
        del held[k]
    save(path, st)
    sensors, probs = 0, []
    if sdr_path != "-":
        for line in read(sdr_path).splitlines():
            f = [p.strip() for p in line.split("|")]
            if len(f) < 5 or not re.fullmatch(r"[0-9A-Fa-f]{2}h", f[1]):
                continue
            sensors += 1
            name, status, reading = f[0], f[2].lower(), " | ".join(f[4:])
            if status == "ns":
                continue
            sev = SDR_STATUS.get(status)
            if SDR_CRIT_STATE.search(reading):
                sev = "urgent"
            elif sev is None and SDR_WARN_STATE.search(reading):
                sev = "warn"
            if sev:
                probs.append(("crit" if sev == "urgent" else "warn", f"bmc.sensor.{bkey(name)}",
                              f"BMC sensor {name}: status {f[2]}, {reading}"))
    out("ok", "bmc", f"SEL {n_sel} entries, {n_new} new, {len(held)} held for {HOLD_H} h"
        + (f"; {sensors} sensors, {len(probs)} out of range" if sdr_path != "-" else ""))
    for k in sorted(held):
        h = held[k]
        out("crit" if h["severity"] == "urgent" else "warn", k,
            f"BMC SEL: {h['sensor']}: {h['event'] or '-'}: {h['count']} new entr(ies), {h['first']} to {h['last']} "
            f"(BMC clock, UTC); last: {h['sample']}")
    for p in probs:
        out(*p)


mode, state = sys.argv[1], sys.argv[2]
os.makedirs(state, mode=0o700, exist_ok=True)
if mode == "bmc-need":
    bmc_need(state, sys.argv[3])
now = int(sys.argv[3])
if mode == "kern":
    kern(state, now, *sys.argv[4:6])
elif mode == "smart":
    smart(state, now, sys.argv[4:])
elif mode == "bmc":
    bmc(state, now, *sys.argv[4:7])
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

# ipmi SECONDS ARGS...: one read-only ipmitool call, under a fixed locale and zone (its dates go through
# strftime, and a SEL entry's text is hashed) and a timeout. Only sel info, sel elist and sdr elist.
ipmi() {
    local t="$1"; shift
    case "$*" in "sel info"|"sel elist"|"sdr elist") ;; *) echo "ipmi: refusing ipmitool $*" >&2; return 2 ;; esac
    LC_ALL=C TZ=UTC timeout -k 2 "$t" ipmitool "$@"
}

# bmc_check STATE NOW: the BMC's SEL and sensors through /dev/ipmi* (KCS: vmh01, vmh02; vmh03 has none).
# `sel info`, then `sel elist` only when py bmc-need says the SEL changed, then `sdr elist`; never
# anything that writes to the BMC. Timeouts 10 + 20 + 10 s keep a hung BMC inside the monitor's 90 s
# (2026-11-22: sel info 0.07 s, a 194-entry elist 3.8 s, sdr elist 0.9 s).
bmc_check() {
    local state="$1" now="$2" d="$1/bmc" dev info=- elist=- sdr=- rc
    for dev in "${ASYLA_VMH_DEV:-/dev}"/ipmi*; do [ -e "$dev" ] && break; dev=; done
    [ -n "$dev" ] || { r ok bmc none; return; }
    has ipmitool || { r warn bmc "$dev present but ipmitool not found: BMC not checked"; return; }
    has python3 || { r warn bmc "python3 not found: BMC not checked"; return; }
    mkdir -p "$d" && chmod 700 "$state" || { r warn bmc "state directory $state not writable"; return; }
    rm -f "$d"/*.txt
    ipmi 10 sel info >"$d/info.txt" 2>"$d/err.txt"; rc=$?
    if [ "$rc" -eq 0 ]; then
        info="$d/info.txt"
        if py bmc-need "$state" "$info"; then
            ipmi 20 sel elist >"$d/elist.txt" 2>"$d/err.txt"; rc=$?
            if [ "$rc" -eq 0 ]; then elist="$d/elist.txt"
            else r warn bmc.sel "BMC SEL entries not read: sel elist exit $rc $(one <"$d/err.txt" | cut -c1-160)"; fi
        fi
    else
        r warn bmc.sel "BMC SEL not read: sel info exit $rc $(one <"$d/err.txt" | cut -c1-160)"
    fi
    ipmi 10 sdr elist >"$d/sdr.txt" 2>"$d/err.txt"; rc=$?
    if [ "$rc" -eq 0 ]; then sdr="$d/sdr.txt"
    else r warn bmc.sdr "BMC sensors not read: sdr elist exit $rc $(one <"$d/err.txt" | cut -c1-160)"; fi
    py bmc "$state" "$now" "$info" "$elist" "$sdr"
}

# ---- asyla_hw_* textfile (asyla #610 step 5)
# The hardware-problem contract the asyla checkers share, as the hub's tools/export_nas_smart.py
# (render_hw_prom) writes it; d06's operations Prometheus scrapes it through this node's
# node_exporter (vmh/setup.sh part node_exporter) and alerts on it (asyla-hosts
# d06/apps/observability/prometheus/rules/asyla-hw.yml):
#   asyla_hw_problem{host,key,severity} 1     one series per open hardware problem; crit is
#                                             "urgent", warn is "warning", never "critical"
#   asyla_hw_check_last_run_timestamp_seconds{host,checker="vmh-health"}
# Only the hardware checks (#610 steps 2-3, plus ZFS pool health) are problems here: kern*, disk*,
# smart*, bmc*, zfs. The rest (apt, reboot, cluster, ...) stay with the host-maintenance monitor.
# hw_textfile DIR HOST NOW < health lines: writes DIR/asyla-vmh-health.prom through a temp file and a
# rename, so node_exporter never reads half a file. One series per key; crit wins over warn.
HW_PROM_NAME=asyla-vmh-health.prom
hw_textfile() {
    local dir="$1" host="$2" now="$3" tmp
    mkdir -p "$dir" 2>/dev/null || return 1
    tmp="$dir/.$HW_PROM_NAME.$$"
    awk -F'\t' -v host="$host" -v now="$now" '
        function esc(v) { gsub(/[\\"\n]/, "_", v); return v }
        $1 != "crit" && $1 != "warn" { next }
        $2 !~ /^(kern|disk|smart|bmc|zfs)([.].*)?$/ { next }
        { sev = ($1 == "crit") ? "urgent" : "warning"
          if (!($2 in s) || sev == "urgent") s[$2] = sev
          if (!($2 in seen)) { seen[$2] = 1; order[++n] = $2 } }
        END {
            print "# HELP asyla_hw_problem An open hardware problem (asyla #610): 1 while the checker reports it."
            print "# TYPE asyla_hw_problem gauge"
            for (i = 1; i <= n; i++)
                printf "asyla_hw_problem{host=\"%s\",key=\"%s\",severity=\"%s\"} 1\n", esc(host), esc(order[i]), s[order[i]]
            print "# HELP asyla_hw_check_last_run_timestamp_seconds When the hardware checker last ran."
            print "# TYPE asyla_hw_check_last_run_timestamp_seconds gauge"
            printf "asyla_hw_check_last_run_timestamp_seconds{host=\"%s\",checker=\"vmh-health\"} %d\n", esc(host), now
        }' >"$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$dir/$HW_PROM_NAME" || { rm -f "$tmp"; return 1; }
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

# Every check's line goes to stdout as before and to HW_LINES, from which hw_textfile writes the
# asyla_hw_* textfile once the checks are done (#610 step 5).
HW_DIR=/var/lib/prometheus/node-exporter
HW_LINES=$(mktemp) || { echo "asyla-vmh-health: mktemp failed" >&2; exit 2; }
{
r ok node "$node $role pve $(pveversion | sed 's#^pve-manager/##; s#/.*##') up $(awk '{ printf "%d", $1 / 86400 }' /proc/uptime)d"

# ---- storage
if has zpool; then
    s=$(zpool status -x 2>&1 | one)
    case "$s" in "all pools are healthy"|"no pools available") r ok zfs "$s" ;; *) r crit zfs "$s" ;; esac
fi
# The only state health keeps (#610): the kernel journal cursor, kernel findings held for 24 h,
# each disk serial's counters, and the BMC's SEL hashes and held SEL findings. One run at a time holds it (the monitor every 15 min, apply.sh health).
STATE=/var/lib/asyla-vmh-health
now=$(date +%s)
mkdir -p "$STATE" && chmod 700 "$STATE"
if exec 9>"$STATE/lock" && { ! has flock || flock -w 60 9; }; then
    disk_check "$STATE" "$now"
    kern_check "$STATE" "$now"
    bmc_check "$STATE" "$now"
else
    r warn kern "another health run held $STATE/lock for 60 s: kernel, SMART and BMC not checked"
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
} | tee "$HW_LINES"
hw_textfile "$HW_DIR" "$node" "$(date +%s)" <"$HW_LINES" \
    || r warn hw.textfile "$HW_DIR/$HW_PROM_NAME not written: d06 sees no asyla_hw_* series from this node"
rm -f "$HW_LINES"
exit 0
