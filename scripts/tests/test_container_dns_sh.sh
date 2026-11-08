#!/bin/bash
# build/setup/container_dns.sh --dropin: the resolved drop-in it writes, written once and rewritten
# when it differs; and every host spec whose containers ask the host's resolved takes the step.
# No root, no systemctl; nothing here reaches a host.
# Run: bash scripts/tests/test_container_dns_sh.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STEP="$REPO/build/setup/container_dns.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }

bash -n "$STEP" && ok "the step parses" || bad "the step parses"

F="$T/conf.d/no-etc-hosts.conf"
out=$(bash "$STEP" --dropin "$T/conf.d" 2>&1)
[ "$out" = changed ] && ok "first run writes the drop-in" || bad "first run writes the drop-in" "$out"
[ "$(grep -v '^#' "$F" 2>/dev/null | tr '\n' ' ')" = "[Resolve] ReadEtcHosts=no " ] \
  && ok "the drop-in is [Resolve] ReadEtcHosts=no and comments" || bad "the drop-in is [Resolve] ReadEtcHosts=no and comments" "$(cat "$F" 2>&1)"
[ "$(stat -f %Lp "$F" 2>/dev/null || stat -c %a "$F")" = 644 ] && ok "the drop-in is 644" || bad "the drop-in is 644"
out=$(bash "$STEP" --dropin "$T/conf.d" 2>&1)
[ "$out" = same ] && ok "second run changes nothing" || bad "second run changes nothing" "$out"
printf '[Resolve]\nReadEtcHosts=yes\n' > "$F"
out=$(bash "$STEP" --dropin "$T/conf.d" 2>&1)
[ "$out" = changed ] && grep -qx 'ReadEtcHosts=no' "$F" && ok "a drop-in that differs is rewritten" \
  || bad "a drop-in that differs is rewritten" "$out"
ls "$T/conf.d"/*.tmp >/dev/null 2>&1 && bad "no temporary file is left" || ok "no temporary file is left"

out=$(bash "$STEP" 2>&1); rc=$?
if [ "$EUID" -ne 0 ]; then
  [ "$rc" -ne 0 ] && echo "$out" | grep -q 'run as root' && ok "refuses to run without root" || bad "refuses to run without root" "rc=$rc; $out"
fi

# Every host whose containers ask the host's resolved: it runs docker.sh and keeps resolved's stub
# (dns_port.sh turns the stub off and points /etc/resolv.conf at the real servers, as on ns01/ns02).
for spec in "$REPO"/*/host.toml; do
  h=$(basename "$(dirname "$spec")")
  steps=$(python3 -c 'import sys, tomllib; print(" ".join(tomllib.load(open(sys.argv[1], "rb")).get("setup", {}).get("steps", [])))' "$spec")
  case " $steps " in *" docker.sh "*) ;; *) continue ;; esac
  case " $steps " in *" dns_port.sh "*) continue ;; esac
  case " $steps " in
    *" docker.sh "*"container_dns.sh "*) ok "$h takes container_dns.sh after docker.sh" ;;
    *) bad "$h takes container_dns.sh after docker.sh" "$steps" ;;
  esac
done

exit "$fail"
