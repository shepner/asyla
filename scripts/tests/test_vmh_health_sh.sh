#!/bin/bash
# vmh/health.sh's apt verdict and unattended-upgrades log reading, sourced for its functions only
# (ASYLA_VMH_HEALTH_FUNCTIONS_ONLY=1): no root, no Proxmox, nothing reaches a node. The case that
# started this: security packages fetched overnight warned "unattended-upgrades should have taken
# these" before the morning run had a chance to (vmh01/vmh02, 2026-11-02). Also the #610 kernel
# patterns and SMART by serial (py, kern_check, disk_check), with stand-in journalctl, lsblk, smartctl,
# and the BMC check (bmc_check) on real vmh01/vmh02 ipmitool output through a stand-in ipmitool.
# Run: bash scripts/tests/test_vmh_health_sh.sh   (also under dash when it is installed: the hosts' sh)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

if [ "${1:-}" != --inner ]; then
  rc=0
  echo "== bash"; bash "${BASH_SOURCE[0]}" --inner || rc=1
  if command -v dash >/dev/null; then echo "== dash"; VMH_HEALTH_SH=dash bash "${BASH_SOURCE[0]}" --inner || rc=1
  else echo "skip dash (not installed)"; fi
  exit "$rc"
fi
SH=${VMH_HEALTH_SH:-bash}

fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }
# call FUNCTION ARGS...: run one of health.sh's functions in the shell under test.
call() { ASYLA_VMH_HEALTH_FUNCTIONS_ONLY=1 "$SH" -c '. "$0"; "$@"' "$REPO/vmh/health.sh" "$@"; }
expect() {  # NAME WANT GOT
  if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "want [$2] got [$3]"; fi
}

# ---- uu_last_run: vmh01's 2026-11-02 log, then a dry run after it.
cat >"$T/uu.log" <<'EOF'
2026-11-01 06:38:03,515 INFO Starting unattended upgrades script
2026-11-01 06:38:06,019 INFO Packages that will be upgraded: libnss3
2026-11-01 06:38:09,443 INFO All upgrades installed
2026-11-02 03:36:05,535 INFO Starting unattended upgrades script
2026-11-02 03:36:05,535 INFO Allowed origins are: origin=Debian,codename=trixie-security,label=Debian-Security
2026-11-02 06:36:59,364 INFO Starting unattended upgrades script
2026-11-02 06:37:02,939 INFO Packages that will be upgraded: vim-common vim-tiny xxd
2026-11-02 06:37:07,269 INFO All upgrades installed
EOF
got=$(call uu_last_run "$T/uu.log")
expect "last real run: the 06:36 one, not the 03:36 download-only start" \
  "$(printf '2026-11-02 06:36:59\t2026-11-02 06:37:07,269 INFO All upgrades installed')" "$got"

cp "$T/uu.log" "$T/uu-dry.log"
cat >>"$T/uu-dry.log" <<'EOF'
2026-11-02 18:02:44,890 INFO Starting unattended upgrades script
2026-11-02 18:02:44,899 INFO Option --dry-run given, *not* performing real actions
2026-11-02 18:03:57,500 INFO All upgrades installed
EOF
expect "a later --dry-run does not count" "2026-11-02 06:36:59" "$(call uu_last_run "$T/uu-dry.log" | cut -f1)"

printf '2026-11-03 06:40:00,000 INFO Starting unattended upgrades script\n2026-11-03 06:40:05,000 ERROR boom\n' >>"$T/uu.log"
expect "an ERROR outcome is the last run" "$(printf '2026-11-03 06:40:00\t2026-11-03 06:40:05,000 ERROR boom')" \
  "$(call uu_last_run "$T/uu.log")"
expect "no log: nothing" "" "$(call uu_last_run "$T/missing.log")"

# ---- apt_verdict ROLE N SECURITY LISTS_FRESH RUN_EPOCH FETCHED_EPOCH NOW_EPOCH RUN_START
# Epochs on one day: run_prev = 11-01 06:38, fetched = 11-02 03:36, run = 11-02 06:37.
run_prev=1000000; fetched=$((run_prev + 75480)); run=$((run_prev + 86340)); now=$((run + 3600))
v() { call apt_verdict "$@" | cut -f1,3; }

expect "the 2026-11-02 false alarm: fetched after the last run, before the morning one -> ok" \
  "$(printf 'ok\t3 upgradable, 3 security, fetched after the 2026-11-01 06:38 run: for the next unattended-upgrades run')" \
  "$(v production 3 3 1 "$run_prev" "$fetched" $((fetched + 600)) "2026-11-01 06:38")"
expect "still pending after a run that saw them -> warn" \
  "$(printf 'warn\t3 upgradable, 3 from security, still pending after the 2026-11-02 06:36 unattended-upgrades run')" \
  "$(v production 3 3 1 "$run" "$fetched" "$now" "2026-11-02 06:36")"
expect "fetched after the last run but no run for 36 h -> warn" \
  "$(printf 'warn\t3 upgradable, 3 from security; no unattended-upgrades run since 2026-11-01 06:38')" \
  "$(v production 3 3 1 "$run_prev" "$fetched" $((run_prev + 129601)) "2026-11-01 06:38")"
expect "no run logged -> warn" \
  "$(printf 'warn\t3 upgradable, 3 from security; no unattended-upgrades run logged')" \
  "$(v production 3 3 1 "" "$fetched" "$now" "")"
expect "no security pending -> ok" "$(printf 'ok\t5 upgradable, 0 security')" \
  "$(v production 5 0 1 "$run" "$fetched" "$now" "2026-11-02 06:36")"
expect "the canary takes every origin itself: pending security -> ok" "$(printf 'ok\t3 upgradable, 3 security')" \
  "$(v canary 3 3 1 "$run" "$fetched" "$now" "2026-11-02 06:36")"
expect "lists older than 3 days -> warn first" "$(printf 'warn\tpackage lists older than 3 days')" \
  "$(v production 3 3 0 "$run" "$fetched" "$now" "2026-11-02 06:36")"
expect "no lists fetched at all (empty FETCHED) -> pending warns" \
  "$(printf 'warn\t3 upgradable, 3 from security, still pending after the 2026-11-02 06:36 unattended-upgrades run')" \
  "$(v production 3 3 1 "$run" "" "$now" "2026-11-02 06:36")"

# ---- py kern: the #610 kernel patterns (copied from the asyla hub's tools/export_nas_smart.py).
# The NIC lines are the shape of nas01's 2026-10-20 kern.log, as journalctl -o short-iso --utc
# prints them; the others are shaped after common kernel messages, not captured from a vmh.
NOW=1795000000   # 2026-11-18 11:06Z
cat >"$T/kern1.lines" <<'EOF'
2026-11-18T05:16:12+00:00 vmh01 kernel: ixgbe 0000:0c:00.0 enp12s0f0: Received ECC Err, initiating reset
2026-11-18T05:16:12+00:00 vmh01 kernel: ixgbe 0000:0c:00.0 enp12s0f0: Reset adapter
2026-11-18T05:19:40+00:00 vmh01 kernel: ixgbe 0000:0c:00.0 enp12s0f0: Received ECC Err, initiating reset
2026-11-18T05:23:36+00:00 vmh01 kernel: ixgbe 0000:0c:00.0: Adapter removed
2026-11-18T05:24:00+00:00 vmh01 kernel: INFO: task txg_sync:1234 blocked for more than 122 seconds.
2026-11-18T05:25:00+00:00 vmh01 kernel: I/O error, dev sdb, sector 123456 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 2
2026-11-18T05:26:00+00:00 vmh01 kernel: ixgbe 0000:0c:00.0: Multiqueue Enabled: Rx Queue count = 12, Tx Queue count = 12 XDP Queue count = 0
2026-11-18T05:26:00+00:00 vmh01 kernel: pcieport 0000:00:1c.0: AER: enabled with IRQ 120
2026-11-18T05:26:00+00:00 vmh01 kernel: mce: CPU0: Thermal monitoring enabled (TM1)
2026-11-18T05:26:01+00:00 vmh01 kernel: vmbr0: port 2(tap100i0) entered forwarding state
-- cursor: fixture-cursor-2
EOF
kv() { call py "$@" | cut -f1,2 | tr '\t' ' ' | sort | tr '\n' ';'; }
call py kern "$T/st" "$NOW" "$T/kern1.lines" >"$T/kern1.out"
expect "kern: each pattern by kind and device, removed is crit, the rest warn, clean lines match nothing" \
  "crit kern.nic-removed.0000:0c:00.0;ok kern;warn kern.io-error.sdb;warn kern.kernel-fault;warn kern.nic-ecc.0000:0c:00.0;warn kern.nic-reset.0000:0c:00.0;" \
  "$(cut -f1,2 "$T/kern1.out" | tr '\t' ' ' | sort | tr '\n' ';')"
expect "kern: the ok line counts new, matched and held lines" \
  "$(printf 'ok\tkern\t10 new kernel line(s), 6 matched, 5 held for 24 h')" "$(awk -F'\t' '$2 == "kern"' "$T/kern1.out")"
expect "kern: a finding's detail has its count, first and last time, and a sample" \
  "NIC internal ECC error on 0000:0c:00.0: 2 line(s), 11-18 05:16:12Z to 11-18 05:19:40Z: 2026-11-18T05:19:40+00:00 vmh01 kernel: ixgbe 0000:0c:00.0 enp12s0f0: Received ECC Err, initiating reset" \
  "$(awk -F'\t' '$2 == "kern.nic-ecc.0000:0c:00.0" { print $3 }' "$T/kern1.out")"
expect "kern: the same lines again add to the counts" "4 line(s)" \
  "$(call py kern "$T/st" "$NOW" "$T/kern1.lines" | awk -F'\t' '$2 == "kern.nic-ecc.0000:0c:00.0" { print $3 }' | grep -o '4 line(s)')"
expect "kern: held for 24 h with no new lines (a 15-minute monitor keeps the task open)" \
  "crit kern.nic-removed.0000:0c:00.0;ok kern;warn kern.io-error.sdb;warn kern.kernel-fault;warn kern.nic-ecc.0000:0c:00.0;warn kern.nic-reset.0000:0c:00.0;" \
  "$(kv kern "$T/st" $((NOW + 23 * 3600)) /dev/null)"
expect "kern: dropped once unseen for over 24 h" "ok kern;" "$(kv kern "$T/st" $((NOW + 25 * 3600)) /dev/null)"
printf '2026-11-18T06:00:00+00:00 vmh01 kernel: ata3.00: exception Emask 0x0 SAct 0x0\tSErr 0x0 action 0x6\n' >"$T/tab.lines"
expect "kern: a tab in a kernel line does not split the detail (the monitor splits on tabs)" "3 ata3" \
  "$(call py kern "$T/st" "$NOW" "$T/tab.lines" | awk -F'\t' '$2 ~ /^kern\.ata-scsi/ { print NF, substr($2, 15) }')"

# ---- kern_check with a stand-in journalctl: first run sets the cursor only; the next reads after it.
mkdir -p "$T/bin"
cat >"$T/bin/journalctl" <<'EOF'
#!/bin/sh
# Stand-in: -n 0 gives the tail cursor; --after-cursor gives the lines after it.
[ -n "${FAKE_JOURNAL_FAIL:-}" ] && { echo "Failed to seek to cursor: Invalid argument" >&2; exit 1; }
for a in "$@"; do
  case "$a" in
    -n) echo "-- cursor: fixture-cursor-1"; exit 0 ;;
    --after-cursor=fixture-cursor-1) cat "$FAKE_JOURNAL_LINES"; exit 0 ;;
    --after-cursor=*) exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$T/bin/journalctl"
kc() { FAKE_JOURNAL_LINES="$T/kern1.lines" PATH="$T/bin:$PATH" call kern_check "$@"; }
rm -rf "$T/kc"
expect "kern_check: the first run sets the cursor and reports no older lines" \
  "$(printf 'ok\tkern\tfirst run: cursor set at the end of the journal; later runs read from here')" \
  "$(kc "$T/kc" "$NOW")"
expect "kern_check: the cursor file holds the journal's cursor" "fixture-cursor-1" "$(cat "$T/kc/kern.cursor")"
expect "kern_check: the next run reads the lines after it" "6" "$(kc "$T/kc" "$NOW" | grep -c .)"
expect "kern_check: the cursor moves to the last line read" "fixture-cursor-2" "$(cat "$T/kc/kern.cursor")"
expect "kern_check: a run with no new lines keeps the cursor and the held findings" \
  "6 fixture-cursor-2" "$(kc "$T/kc" "$NOW" | grep -c .) $(cat "$T/kc/kern.cursor")"
got=$(FAKE_JOURNAL_FAIL=1 kc "$T/kc" "$NOW")
case "$got" in
  "$(printf 'warn\tkern\tjournal not read after the saved cursor: Failed to seek to cursor')"*) ok "kern_check: a journal error warns" ;;
  *) bad "kern_check: a journal error warns" "got [$got]" ;;
esac
expect "kern_check: ... and keeps the cursor" "fixture-cursor-2" "$(cat "$T/kc/kern.cursor")"

# ---- py smart: smartctl --json -a shapes from vmh01 (PNY, WD SA510 SATA SSDs) and vmh03 (Samsung
# NVMe), 2026-11-22, cut to the fields read. Serials and models are made up.
ata() {  # SERIAL REALLOC PENDING CRC TEMP [PASSED] [EXIT]
  printf '{"smartctl":{"exit_status":%s},"device":{"name":"/dev/x","protocol":"ATA"},"model_name":"Fixture SATA SSD","serial_number":"%s","rotation_rate":0,"smart_status":{"passed":%s},"temperature":{"current":%s},"ata_smart_attributes":{"table":[{"id":5,"name":"Reallocated_Sector_Ct","value":100,"thresh":10,"raw":{"value":%s,"string":"%s"}},{"id":177,"name":"Wear_Leveling_Count","value":45,"thresh":0,"raw":{"value":994,"string":"994"}},{"id":194,"name":"Temperature_Celsius","value":100,"thresh":14,"raw":{"value":137440198680,"string":"24 (Min/Max 19/32)"}},{"id":197,"name":"Current_Pending_Sector","value":100,"thresh":50,"raw":{"value":%s,"string":"%s"}},{"id":199,"name":"UDMA_CRC_Error_Count","value":100,"thresh":0,"raw":{"value":%s,"string":"%s"}}]}}\n' \
    "${7:-0}" "$1" "${6:-true}" "$5" "$2" "$2" "$3" "$3" "$4" "$4"
}
nvme() {  # SERIAL USED CRITICAL_WARNING MEDIA_ERRORS TEMP
  printf '{"smartctl":{"exit_status":0},"device":{"name":"/dev/nvme0","protocol":"NVMe"},"model_name":"Fixture NVMe","serial_number":"%s","smart_status":{"passed":true,"nvme":{"value":%s}},"nvme_composite_temperature_threshold":{"warning":84,"critical":85},"temperature":{"op_limit_max":84,"critical_limit_max":85,"current":%s},"nvme_smart_health_information_log":{"critical_warning":%s,"temperature":%s,"available_spare":100,"available_spare_threshold":10,"percentage_used":%s,"media_errors":%s,"num_err_log_entries":942}}\n' \
    "$1" "$3" "$5" "$3" "$5" "$2" "$4"
}
mkdir -p "$T/j"; rm -rf "$T/ss"; mkdir -p "$T/ss"
ata FIXTURE-SSD-A 0 0 0 24 >"$T/j/sda.json"
nvme FIXTURE-NVME-A 2 0 0 37 >"$T/j/nvme0n1.json"
expect "smart: healthy disks are one ok line each, keyed by serial" \
  "$(printf 'ok\tdisk.FIXTURE-NVME-A\tPASSED Fixture NVMe /dev/nvme0n1 used=2%% 99F\nok\tdisk.FIXTURE-SSD-A\tPASSED Fixture SATA SSD /dev/sda wear=45 75F')" \
  "$(call py smart "$T/ss" "$NOW" "$T/j/nvme0n1.json" "$T/j/sda.json")"
ata FIXTURE-SSD-A 3 2 1 24 >"$T/j/sda.json"
nvme FIXTURE-NVME-A 85 1 4 86 >"$T/j/nvme0n1.json"
expect "smart: rises warn from the baseline; pending warns; NVMe critical warning is crit; wear and temperature warn" \
  "crit disk.FIXTURE-NVME-A.nvme-critical;ok disk.FIXTURE-SSD-A;warn disk.FIXTURE-NVME-A;warn disk.FIXTURE-NVME-A.nvme-media-errors;warn disk.FIXTURE-NVME-A.temp;warn disk.FIXTURE-SSD-A.crc-errors;warn disk.FIXTURE-SSD-A.pending;warn disk.FIXTURE-SSD-A.reallocated-sectors;" \
  "$(kv smart "$T/ss" $((NOW + 900)) "$T/j/nvme0n1.json" "$T/j/sda.json")"
expect "smart: a rise names the new count and when" \
  "Fixture SATA SSD /dev/sda: reallocated sectors rose to 3 at 2026-11-18 11:21Z" \
  "$(call py smart "$T/ss" $((NOW + 1800)) "$T/j/sda.json" | awk -F'\t' '$2 == "disk.FIXTURE-SSD-A.reallocated-sectors" { print $3 }')"
expect "smart: a rise stops warning 7 days later; pending still warns" \
  "ok disk.FIXTURE-SSD-A;warn disk.FIXTURE-SSD-A.pending;" \
  "$(kv smart "$T/ss" $((NOW + 8 * 86400)) "$T/j/sda.json")"
expect "smart: a temperature at the drive's own limit warns, in F" \
  "Fixture NVMe /dev/nvme0n1: 187F, at or over its 183F limit" \
  "$(call py smart "$T/ss" "$NOW" "$T/j/nvme0n1.json" | awk -F'\t' '$2 == "disk.FIXTURE-NVME-A.temp" { print $3 }')"
ata FIXTURE-SSD-B 0 0 0 71 false >"$T/j/sdb.json"
expect "smart: FAILED is crit; an SSD with no limit of its own warns at 70C" \
  "crit disk.FIXTURE-SSD-B;warn disk.FIXTURE-SSD-B.temp;" "$(kv smart "$T/ss" "$NOW" "$T/j/sdb.json")"
ata FIXTURE-SSD-C 0 0 0 24 true 2 >"$T/j/sdc.json"
printf 'not json\n' >"$T/j/sdd.json"
expect "smart: an unreadable disk warns by device name" \
  "warn disk.sdc;warn disk.sdd;" "$(kv smart "$T/ss" "$NOW" "$T/j/sdc.json" "$T/j/sdd.json")"
case "$(grep -c FIXTURE-SSD-A "$T/ss/smart.json")" in 1) ok "smart: counters kept by serial in smart.json" ;; *) bad "smart: counters kept by serial in smart.json" ;; esac

# ---- disk_check with stand-in lsblk and smartctl: whole disks only, zvols skipped.
cat >"$T/bin/lsblk" <<'EOF'
#!/bin/sh
printf 'sda  disk\nzd0  disk\nsda1 part\nnvme0n1 disk\n'
EOF
cat >"$T/bin/smartctl" <<'EOF'
#!/bin/sh
for a in "$@"; do d=$a; done
cat "$FAKE_SMART_DIR/${d#/dev/}.json"
EOF
chmod +x "$T/bin/lsblk" "$T/bin/smartctl"
ata FIXTURE-SSD-A 0 0 0 24 >"$T/j/sda.json"
nvme FIXTURE-NVME-A 2 0 0 37 >"$T/j/nvme0n1.json"
rm -rf "$T/dc"
expect "disk_check: one line per whole disk, zvols and partitions skipped" \
  "ok disk.FIXTURE-NVME-A;ok disk.FIXTURE-SSD-A;" \
  "$(FAKE_SMART_DIR="$T/j" PATH="$T/bin:$PATH" call disk_check "$T/dc" "$NOW" | cut -f1,2 | tr '\t' ' ' | sort | tr '\n' ';')"

# ---- bmc_check (#610 step 3) on real output: vmh01 and vmh02, 2026-11-22, as root, `ipmitool sel info`,
# `sel elist | tail -40` and `sdr elist` under LC_ALL=C TZ=UTC. Both SELs hold only old entries
# (vmh02: correctable ECC on DIMMA1, last 03/03/25), so a first run must report nothing.
mkdir -p "$T/ipmi01" "$T/ipmi02" "$T/dev" "$T/nodev"
cat >"$T/ipmi01/sel-info.txt" <<'EOF'
SEL Information
Version          : 1.5 (v1.5, v2 compliant)
Entries          : 11
Free Space       : 10020 bytes
Percent Used     : 1%
Last Add Time    : 02/11/22 21:01:52 UTC
Last Del Time    : Not Available
Overflow         : false
Supported Cmds   : 'Reserve' 'Get Alloc Info'
# of Alloc Units : 512
Alloc Unit Size  : 20
# Free Units     : 501
Largest Free Blk : 501
Max Record Size  : 20
EOF
cat >"$T/ipmi01/sel-elist.txt" <<'EOF'
   1 | 05/25/15 | 21:25:26 UTC | Unknown #0xff |  | Asserted
   2 | 11/26/15 | 14:48:52 UTC | Unknown #0xff |  | Asserted
   3 | 08/16/16 | 20:18:57 UTC | Unknown #0xff |  | Asserted
   4 | 07/27/17 | 04:15:00 UTC | Unknown #0xff |  | Asserted
   5 | 05/31/18 | 09:43:23 UTC | Unknown #0xff |  | Asserted
   6 | 06/03/20 | 11:30:07 UTC | Unknown #0xff |  | Asserted
   7 | 06/10/20 | 10:59:42 UTC | Unknown #0xff |  | Asserted
   8 |  Pre-Init  |0000000038| Unknown #0xff |  | Asserted
   9 | 09/11/20 | 21:37:22 UTC | Unknown #0xff |  | Asserted
   a | 08/11/21 | 11:35:25 UTC | Unknown #0xff |  | Asserted
   b | 02/11/22 | 21:01:52 UTC | Unknown #0xff |  | Asserted
EOF
cat >"$T/ipmi01/sdr-elist.txt" <<'EOF'
CPU1 Temp        | 01h | ok  |  3.1 | 42 degrees C
CPU2 Temp        | 02h | ok  |  3.2 | 35 degrees C
System Temp      | 11h | ok  |  7.1 | 31 degrees C
Peripheral Temp  | 12h | ok  |  7.2 | 43 degrees C
PCH Temp         | 0Ah | ok  |  7.3 | 49 degrees C
P1-DIMMA1 TEMP   | B0h | ok  | 32.64 | 37 degrees C
P1-DIMMB1 TEMP   | B4h | ok  | 32.65 | 37 degrees C
P1-DIMMC1 TEMP   | B8h | ok  | 32.68 | 44 degrees C
P1-DIMMD1 TEMP   | BCh | ok  | 32.69 | 43 degrees C
P2-DIMME1 TEMP   | D0h | ok  | 32.72 | 37 degrees C
P2-DIMMF1 TEMP   | D4h | ok  | 32.73 | 37 degrees C
P2-DIMMG1 TEMP   | D8h | ok  | 32.76 | 33 degrees C
P2-DIMMH1 TEMP   | DCh | ok  | 32.77 | 33 degrees C
FAN1             | 41h | ok  | 29.1 | 7800 RPM
FAN3             | 43h | ok  | 29.3 | 7650 RPM
FAN4             | 44h | ok  | 29.4 | 7500 RPM
VTT              | 30h | ok  |  7.10 | 1.01 Volts
CPU1 Vcore       | 21h | ok  |  3.3 | 0.88 Volts
CPU2 Vcore       | 22h | ok  |  3.4 | 0.83 Volts
VDIMM ABCD       | 61h | ok  | 32.1 | 1.50 Volts
VDIMM EFGH       | 62h | ok  | 32.2 | 1.49 Volts
+1.1 V           | 31h | ok  |  7.11 | 1.09 Volts
+1.5 V           | 32h | ok  |  7.12 | 1.50 Volts
3.3V             | 33h | ok  |  7.12 | 3.31 Volts
+3.3VSB          | 34h | ok  |  7.14 | 3.31 Volts
5V               | 35h | ok  |  7.15 | 4.99 Volts
+5VSB            | 36h | ok  |  7.16 | 5.06 Volts
12V              | 37h | ok  |  7.17 | 11.98 Volts
VBAT             | 38h | ok  |  7.18 | 3.26 Volts
PS1 Status       | C8h | ok  | 10.1 | Presence detected
EOF
cat >"$T/ipmi02/sel-info.txt" <<'EOF'
SEL Information
Version          : 1.5 (v1.5, v2 compliant)
Entries          : 194
Free Space       : 6360 bytes
Percent Used     : 32%
Last Add Time    : 03/03/25 22:16:17 UTC
Last Del Time    : Not Available
Overflow         : false
Supported Cmds   : 'Reserve' 'Get Alloc Info'
# of Alloc Units : 512
Alloc Unit Size  : 20
# Free Units     : 318
Largest Free Blk : 318
Max Record Size  : 20
EOF
cat >"$T/ipmi02/sel-elist.txt" <<'EOF'
  9b | 10/11/24 | 07:43:27 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  9c | 10/13/24 | 19:58:02 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  9d | 10/13/24 | 19:58:32 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  9e | 10/13/24 | 20:03:14 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  9f | 10/13/24 | 20:08:39 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  a0 | 10/13/24 | 20:08:54 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  a1 | 12/17/24 | 23:19:21 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  a2 | 12/17/24 | 23:19:40 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  a3 | 12/19/24 | 15:31:51 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  a4 | 12/19/24 | 15:32:06 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  a5 | 12/19/24 | 15:32:37 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  a6 | 12/19/24 | 15:33:08 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  a7 | 12/19/24 | 15:33:25 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  a8 | 02/03/25 | 22:00:05 UTC | Unknown #0xff | () | Asserted
  a9 | 03/03/25 | 21:33:18 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  aa | 03/03/25 | 21:33:22 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  ab | 03/03/25 | 21:33:26 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  ac | 03/03/25 | 21:33:43 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  ad | 03/03/25 | 21:33:54 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  ae | 03/03/25 | 21:33:58 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  af | 03/03/25 | 21:34:04 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  b0 | 03/03/25 | 21:34:17 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  b1 | 03/03/25 | 21:34:51 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  b2 | 03/03/25 | 21:34:54 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  b3 | 03/03/25 | 21:35:59 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  b4 | 03/03/25 | 21:37:05 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  b5 | 03/03/25 | 21:38:23 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  b6 | 03/03/25 | 21:40:16 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  b7 | 03/03/25 | 21:40:41 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  b8 | 03/03/25 | 21:40:56 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  b9 | 03/03/25 | 21:42:41 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  ba | 03/03/25 | 21:47:23 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  bb | 03/03/25 | 21:47:34 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  bc | 03/03/25 | 21:47:40 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  bd | 03/03/25 | 21:47:56 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  be | 03/03/25 | 21:48:00 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  bf | 03/03/25 | 22:00:54 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  c0 | 03/03/25 | 22:14:53 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  c1 | 03/03/25 | 22:16:17 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted
  c2 | 03/03/25 | 22:16:17 UTC | Unknown #0xff | () | Asserted
EOF
cat >"$T/ipmi02/sdr-elist.txt" <<'EOF'
CPU1 Temp        | 01h | ok  |  3.1 | 36 degrees C
CPU2 Temp        | 02h | ok  |  3.2 | 30 degrees C
System Temp      | 11h | ok  |  7.1 | 30 degrees C
Peripheral Temp  | 12h | ok  |  7.2 | 42 degrees C
PCH Temp         | 0Ah | ok  |  7.3 | 55 degrees C
P1-DIMMA1 TEMP   | B0h | ok  | 32.64 | 36 degrees C
P1-DIMMB1 TEMP   | B4h | ok  | 32.65 | 36 degrees C
P1-DIMMC1 TEMP   | B8h | ok  | 32.68 | 35 degrees C
P1-DIMMD1 TEMP   | BCh | ok  | 32.69 | 32 degrees C
P2-DIMME1 TEMP   | D0h | ok  | 32.72 | 29 degrees C
P2-DIMMF1 TEMP   | D4h | ok  | 32.73 | 32 degrees C
P2-DIMMG1 TEMP   | D8h | ok  | 32.76 | 33 degrees C
P2-DIMMH1 TEMP   | DCh | ok  | 32.77 | 30 degrees C
FAN1             | 41h | ok  | 29.1 | 6375 RPM
FAN3             | 43h | ok  | 29.3 | 6825 RPM
FAN4             | 44h | ok  | 29.4 | 7125 RPM
VTT              | 30h | ok  |  7.10 | 0.99 Volts
CPU1 Vcore       | 21h | ok  |  3.3 | 0.85 Volts
CPU2 Vcore       | 22h | ok  |  3.4 | 0.86 Volts
VDIMM ABCD       | 61h | ok  | 32.1 | 1.34 Volts
VDIMM EFGH       | 62h | ok  | 32.2 | 1.33 Volts
+1.1 V           | 31h | ok  |  7.11 | 1.09 Volts
+1.5 V           | 32h | ok  |  7.12 | 1.49 Volts
3.3V             | 33h | ok  |  7.12 | 3.22 Volts
+3.3VSB          | 34h | ok  |  7.14 | 3.26 Volts
5V               | 35h | ok  |  7.15 | 4.93 Volts
+5VSB            | 36h | ok  |  7.16 | 4.99 Volts
12V              | 37h | ok  |  7.17 | 11.87 Volts
VBAT             | 38h | ok  |  7.18 | 3.17 Volts
EOF
cat >"$T/bin/ipmitool" <<'EOF'
#!/bin/sh
# Stand-in: logs the call and its locale, prints $FAKE_IPMI_DIR/<arg1>-<arg2>.txt.
echo "ipmitool $* LC_ALL=$LC_ALL TZ=$TZ" >>"$FAKE_IPMI_LOG"
[ -n "${FAKE_IPMI_FAIL:-}" ] && { echo "Could not open device at /dev/ipmi0 or /dev/ipmi/0" >&2; exit 1; }
cat "$FAKE_IPMI_DIR/$1-$2.txt"
EOF
cat >"$T/bin/timeout" <<'EOF'
#!/bin/sh
# Stand-in (macOS has none): logs its arguments, drops -k N and the duration, runs the rest.
echo "timeout $*" >>"$FAKE_IPMI_LOG"
[ "$1" = -k ] && shift 2
shift
exec "$@"
EOF
chmod +x "$T/bin/ipmitool" "$T/bin/timeout"
: >"$T/dev/ipmi0"
bc_() {  # FIXTURE_DIR STATE NOW: bmc_check with the stand-ins and $T/dev/ipmi0
  FAKE_IPMI_DIR="$1" FAKE_IPMI_LOG="$T/ipmi.log" ASYLA_VMH_DEV="$T/dev" PATH="$T/bin:$PATH" call bmc_check "$2" "$3"
}
calls() { grep '^ipmitool' "$T/ipmi.log" | cut -d' ' -f2,3 | tr '\n' ';'; }

expect "bmc: no /dev/ipmi* prints ok bmc none" "$(printf 'ok\tbmc\tnone')" \
  "$(ASYLA_VMH_DEV="$T/nodev" PATH="$T/bin:$PATH" FAKE_IPMI_LOG="$T/ipmi.log" call bmc_check "$T/bn" "$NOW")"
for h in 01:11:30 02:194:29; do
  n=${h%%:*}; sel=${h#*:}; sel=${sel%%:*}; sdr=${h##*:}
  rm -rf "$T/b$n"; : >"$T/ipmi.log"
  expect "bmc: real vmh$n, first run remembers the SEL and reports nothing" \
    "$(printf 'ok\tbmc\tSEL %s entries, 0 new, 0 held for 24 h; %s sensors, 0 out of range' "$sel" "$sdr")" \
    "$(bc_ "$T/ipmi$n" "$T/b$n" "$NOW")"
  expect "bmc: real vmh$n, first run reads sel info, sel elist, sdr elist under C and UTC" \
    "sel info;sel elist;sdr elist;" "$(calls)"
  expect "bmc: real vmh$n, every call under C and UTC with a timeout" "3 3" \
    "$(grep -c 'LC_ALL=C TZ=UTC$' "$T/ipmi.log") $(grep -c '^timeout -k 2 [0-9]* ipmitool' "$T/ipmi.log")"
  : >"$T/ipmi.log"
  expect "bmc: real vmh$n, unchanged SEL: no elist, nothing reported" \
    "$(printf 'ok\tbmc\tSEL %s entries, 0 new, 0 held for 24 h; %s sensors, 0 out of range;sel info;sdr elist;' "$sel" "$sdr")" \
    "$(bc_ "$T/ipmi$n" "$T/b$n" "$NOW");$(calls)"
done

# vmh02 gains real-shaped entries: a correctable ECC warns, an uncorrectable one is crit.
cp -R "$T/ipmi02" "$T/ipmi02b"
sed 's/^Entries          : 194/Entries          : 196/' "$T/ipmi02/sel-info.txt" >"$T/ipmi02b/sel-info.txt"
printf '%s\n' "  c3 | 11/22/26 | 05:00:00 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted" \
  "  c4 | 11/22/26 | 05:01:00 UTC | Memory | Uncorrectable ECC (@DIMMA1(CPU1)) | Asserted" >>"$T/ipmi02b/sel-elist.txt"
expect "bmc: new SEL entries: correctable warns, uncorrectable is crit, keyed with the DIMM" \
  "crit bmc.sel.Memory.Uncorrectable_ECC_DIMMA1_CPU1;ok bmc;warn bmc.sel.Memory.Correctable_ECC_DIMMA1_CPU1;" \
  "$(bc_ "$T/ipmi02b" "$T/b02" "$NOW" | cut -f1,2 | tr '\t' ' ' | sort | tr '\n' ';')"
expect "bmc: a finding's detail" \
  "BMC SEL: Memory: Correctable ECC (@DIMMA1(CPU1)): 1 new entr(ies), 11/22/26 05:00:00 UTC to 11/22/26 05:00:00 UTC (BMC clock, UTC); last: c3 | 11/22/26 | 05:00:00 UTC | Memory | Correctable ECC (@DIMMA1(CPU1)) | Asserted" \
  "$(bc_ "$T/ipmi02b" "$T/b02" "$NOW" | awk -F'\t' '$2 == "bmc.sel.Memory.Correctable_ECC_DIMMA1_CPU1" { print $3 }')"
expect "bmc: held for 24 h with no new entries" "2 held" \
  "$(bc_ "$T/ipmi02b" "$T/b02" $((NOW + 23 * 3600)) | awk -F'\t' '$2 == "bmc"' | grep -o '2 held')"
expect "bmc: dropped once unseen for over 24 h" \
  "$(printf 'ok\tbmc\tSEL 196 entries, 0 new, 0 held for 24 h; 29 sensors, 0 out of range')" \
  "$(bc_ "$T/ipmi02b" "$T/b02" $((NOW + 25 * 3600)))"

# Sensors: lnc warns, ucr and a failure state are crit, ns (no reading) is not judged; a full SEL warns.
cp -R "$T/ipmi01" "$T/ipmi01b"
sed -e 's/^FAN1             | 41h | ok  | 29.1 | 7800 RPM/FAN1             | 41h | lnc | 29.1 | 300 RPM/' \
    -e 's/^System Temp      | 11h | ok  |  7.1 | 31 degrees C/System Temp      | 11h | ucr |  7.1 | 86 degrees C/' \
    -e 's/^FAN3             | 43h | ok  | 29.3 | 7650 RPM/FAN3             | 43h | ns  | 29.3 | No Reading/' \
    -e 's/^PS1 Status       | C8h | ok  | 10.1 | Presence detected/PS1 Status       | C8h | ok  | 10.1 | Presence detected, Failure detected/' \
    "$T/ipmi01/sdr-elist.txt" >"$T/ipmi01b/sdr-elist.txt"
printf 'FAN2             | 42h | ns  | 29.2 | Redundancy Lost\n' >>"$T/ipmi01b/sdr-elist.txt"
sed 's/^Overflow         : false/Overflow         : true/' "$T/ipmi01/sel-info.txt" >"$T/ipmi01b/sel-info.txt"
expect "bmc: sensor statuses and a full SEL" \
  "crit bmc.sensor.PS1_Status;crit bmc.sensor.System_Temp;ok bmc;warn bmc.sel-full;warn bmc.sensor.FAN1;" \
  "$(bc_ "$T/ipmi01b" "$T/b01" "$NOW" | cut -f1,2 | tr '\t' ' ' | sort | tr '\n' ';')"

# An unreadable BMC warns for both reads and remembers nothing.
rm -rf "$T/bf"
got=$(FAKE_IPMI_FAIL=1 bc_ "$T/ipmi01" "$T/bf" "$NOW" | cut -f1,2 | tr '\t' ' ' | sort | tr '\n' ';')
expect "bmc: an unreadable BMC warns for the SEL and the sensors" "ok bmc;warn bmc.sdr;warn bmc.sel;" "$got"
case "$(cat "$T/bf/bmc.json" 2>/dev/null)" in *seen*) bad "bmc: ... and remembers no SEL" ;; *) ok "bmc: ... and remembers no SEL" ;; esac
got=$(FAKE_IPMI_LOG="$T/ipmi.log" PATH="$T/bin:$PATH" call ipmi 10 sel clear 2>&1; echo "rc=$?")
case "$got" in *"refusing ipmitool sel clear"*"rc=2") ok "bmc: ipmi refuses anything but the three reads" ;;
  *) bad "bmc: ipmi refuses anything but the three reads" "got [$got]" ;; esac

# Sourcing defines the functions and runs no check (no id, pveversion or apt output).
out=$(ASYLA_VMH_HEALTH_FUNCTIONS_ONLY=1 "$SH" -c '. "$0"; echo sourced' "$REPO/vmh/health.sh" 2>&1)
expect "sourcing for functions runs no check" "sourced" "$out"

exit "$fail"
