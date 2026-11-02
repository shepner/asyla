#!/bin/bash
# vmh/health.sh's apt verdict and unattended-upgrades log reading, sourced for its functions only
# (ASYLA_VMH_HEALTH_FUNCTIONS_ONLY=1): no root, no Proxmox, nothing reaches a node. The case that
# started this: security packages fetched overnight warned "unattended-upgrades should have taken
# these" before the morning run had a chance to (vmh01/vmh02, 2026-11-02).
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

# Sourcing defines the functions and runs no check (no id, pveversion or apt output).
out=$(ASYLA_VMH_HEALTH_FUNCTIONS_ONLY=1 "$SH" -c '. "$0"; echo sourced' "$REPO/vmh/health.sh" 2>&1)
expect "sourcing for functions runs no check" "sourced" "$out"

exit "$fail"
