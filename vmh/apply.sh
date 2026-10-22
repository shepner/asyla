#!/usr/bin/env bash
# Run the shared Proxmox node scripts on vmh01, vmh02 or vmh03 from the workstation. Hypervisors
# pull nothing; they are configured from here (asyla decision hypervisor-scripts). Usage:
#   vmh/apply.sh survey NODE...           read-only facts; two or more nodes print side by side
#   vmh/apply.sh check NODE               read-only: does the node match vmh/setup.sh? (exit 1 if not)
#   vmh/apply.sh setup NODE [PART...]     converge the node (idempotent); PARTs as in vmh/setup.sh
#   vmh/apply.sh patch NODE [--dry-run]   apt upgrade, no reboot; on vmh01/vmh02 only what vmh03 has
#                                         run for setup.sh's SOAK_DAYS (vmh03's list is read first)
#   vmh/apply.sh kernel NODE VERSION|none [--next-boot]   pin a kernel ABI for the next boot(s)
#   vmh/apply.sh cleanup NODE [--dry-run] old kernels (PVE's keep list), old kdump initrds, apt cache
#   vmh/apply.sh health NODE              read-only: vmh/health.sh, as host-maintenance runs it
# vmh01 and vmh02 are production (asyla critical-infra, CRI-1): any mode other than survey, check and
# health also needs --production, given only after the operator approved that exact command.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$HOME/.ssh/shepner_rsa")

address() {
    case "$1" in
        vmh01) echo 10.0.0.35 ;;
        vmh02) echo 10.0.0.36 ;;
        vmh03) echo 10.0.0.37 ;;
        *) echo "apply.sh: unknown node $1 (vmh01, vmh02, vmh03)" >&2; return 1 ;;
    esac
}

usage() { sed -n '2,14p' "$0" >&2; exit 2; }

[ $# -ge 2 ] || usage
mode=$1; shift

production=0
args=()
for a in "$@"; do
    if [ "$a" = --production ]; then production=1; else args+=("$a"); fi
done
set -- "${args[@]}"

if [ "$mode" = survey ]; then
    out=$(mktemp -d)
    trap 'rm -rf "$out"' EXIT
    for node in "$@"; do
        addr=$(address "$node")
        "${SSH[@]}" "root@$addr" sh -s <"$HERE/survey.sh" >"$out/$node" \
            || echo "survey=FAILED on $node" >>"$out/$node"
    done
    if [ -n "${VMH_SURVEY_OUT:-}" ]; then mkdir -p "$VMH_SURVEY_OUT" && cp "$out"/* "$VMH_SURVEY_OUT"/; fi
    if [ $# -eq 1 ]; then cat "$out/$1"; exit 0; fi
    exec python3 "$HERE/survey_table.py" "$out"/*
fi

node=$1; shift
addr=$(address "$node")
case "$mode" in
    check|health) ;;
    setup|patch|kernel|cleanup)
        if [ "$node" != vmh03 ] && [ "$production" != 1 ]; then
            echo "apply.sh: $node is production (CRI-1). Run '$mode' there only with the operator's" \
                 "approval of this exact command, and add --production." >&2
            exit 3
        fi ;;
    *) usage ;;
esac

# setup.sh gets its payloads as shell variables in front of it (base64, one line each).
b64() { base64 <"$1" | tr -d '\n'; }
prelude="HEALTH_B64='$(b64 "$HERE/health.sh")'
RX_B64='$(b64 "$HERE/netconsole-rx.py")'
"
if [ "$mode" = patch ] && [ "$node" != vmh03 ]; then
    # Read-only on vmh03: which versions it runs, and since when.
    canary=$(mktemp)
    trap 'rm -f "$canary"' EXIT
    { printf '%s' "$prelude"; cat "$HERE/setup.sh"; } | "${SSH[@]}" "root@$(address vmh03)" sh -s -- canary-list \
        | gzip -c >"$canary"
    [ "$(gzip -dc "$canary" | wc -l)" -gt 100 ] || { echo "apply.sh: vmh03's package list is short or empty" >&2; exit 1; }
    prelude="${prelude}CANARY_B64='$(b64 "$canary")'
"
fi
{ printf '%s' "$prelude"; cat "$HERE/setup.sh"; } | "${SSH[@]}" "root@$addr" sh -s -- "$mode" "$@"
