#!/usr/bin/env bash
# Run the shared Proxmox node scripts on vmh01, vmh02 or vmh03 from the workstation. Hypervisors
# pull nothing; they are configured from here (asyla decision hypervisor-scripts). Usage:
#   vmh/apply.sh survey NODE...           read-only facts; two or more nodes print side by side
#   vmh/apply.sh check NODE               read-only: does the node match vmh/setup.sh? (exit 1 if not)
#   vmh/apply.sh setup NODE [PART...]     converge the node (idempotent); PARTs as in vmh/setup.sh
#   vmh/apply.sh patch NODE [--dry-run]   the planned upgrade (userspace and kernel packages, no reboot)
#   vmh/apply.sh kernel NODE VERSION      pin VERSION for the next boots (no reboot)
#   vmh/apply.sh cleanup NODE [--dry-run] old kernels (PVE's keep list), apt cache
# vmh01 and vmh02 are production (asyla critical-infra, CRI-1): any mode other than survey and
# check also needs --production, given only after the operator approved that exact command.
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

usage() { sed -n '2,12p' "$0" >&2; exit 2; }

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
    check) ;;
    setup|patch|kernel|cleanup)
        if [ "$node" != vmh03 ] && [ "$production" != 1 ]; then
            echo "apply.sh: $node is production (CRI-1). Run '$mode' there only with the operator's" \
                 "approval of this exact command, and add --production." >&2
            exit 3
        fi ;;
    *) usage ;;
esac

exec "${SSH[@]}" "root@$addr" sh -s -- "$mode" "$@" <"$HERE/setup.sh"
