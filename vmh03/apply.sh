#!/usr/bin/env bash
# Run vmh03/setup.sh on vmh03 from the workstation. Hypervisors pull nothing; they are configured
# from here (asyla decision hypervisor-scripts). Usage:
#   vmh03/apply.sh [check]                     read-only: facts, host keys, no qnetd left (the default)
#   vmh03/apply.sh remove-qnetd --production   purge the qnetd role vmh03 held before it joined vmc01
# vmh03 is a vmc01 member and critical infra (CRI-1) since 2026-10-23: remove-qnetd needs the
# operator's approval of this exact command, and then --production.
# VMH03_ADDRESS overrides the address (default 10.0.0.37).
set -euo pipefail

ADDRESS=${VMH03_ADDRESS:-10.0.0.37}
HERE=$(cd "$(dirname "$0")" && pwd)
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$HOME/.ssh/shepner_rsa")

mode=${1:-check}
case "$mode" in
    check) ;;
    remove-qnetd)
        [ "${2:-}" = --production ] || {
            echo "apply.sh: vmh03 is production (CRI-1). Run 'remove-qnetd' only with the operator's" \
                 "approval of this exact command, and add --production." >&2
            exit 3; } ;;
    *) echo "usage: $0 [check|remove-qnetd --production]" >&2; exit 2 ;;
esac

exec "${SSH[@]}" "root@$ADDRESS" sh -s -- "$mode" <"$HERE/setup.sh"
