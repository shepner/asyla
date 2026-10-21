#!/usr/bin/env bash
# Run vmh03/setup.sh on vmh03 from the workstation. Hypervisors pull nothing; they are configured
# from here (asyla decision hypervisor-scripts). Usage:
#   vmh03/apply.sh [check]             read-only: facts and state (the default)
#   vmh03/apply.sh setup               repos, TCP 5403 rule, corosync-qnetd (idempotent)
#   vmh03/apply.sh add-setup-key       authorize vmh01's root key, just before `pvecm qdevice setup`
#   vmh03/apply.sh remove-setup-key    remove it again, right after
# VMH03_ADDRESS overrides the address (default 10.0.0.37, before the name is in the Pi-hole hosts file).
set -euo pipefail

ADDRESS=${VMH03_ADDRESS:-10.0.0.37}
SETUP_NODE=vmh01   # the node that runs `pvecm qdevice setup`; pvecm uses its /root/.ssh/id_rsa
HERE=$(cd "$(dirname "$0")" && pwd)
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$HOME/.ssh/shepner_rsa")

mode=${1:-check}
key=
case "$mode" in
    check|setup) ;;
    add-setup-key|remove-setup-key)
        # Read-only on vmh01: its root public key. Only the base64 body crosses over.
        read -r type key _ < <("${SSH[@]}" "root@$SETUP_NODE" cat /root/.ssh/id_rsa.pub)
        [[ $type == ssh-rsa && $key =~ ^AAAA[A-Za-z0-9+/]+=*$ ]] \
            || { echo "apply.sh: $SETUP_NODE:/root/.ssh/id_rsa.pub is not an ssh-rsa key" >&2; exit 1; }
        ;;
    *) echo "usage: $0 [check|setup|add-setup-key|remove-setup-key]" >&2; exit 2 ;;
esac

exec "${SSH[@]}" "root@$ADDRESS" sh -s -- "$mode" ${key:+"$key"} <"$HERE/setup.sh"
