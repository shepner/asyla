#!/bin/bash
# build/setup/port_proxy.sh --units: the unit files it writes from [[port_proxy]] (the socket's IP
# filter, the proxy's target and its localhost-only egress) and the spec checks that refuse a bad
# table. No root, no systemctl; nothing here reaches a host.
# Run: bash scripts/tests/test_port_proxy_sh.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STEP="$REPO/build/setup/port_proxy.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }

# d03's own spec: the switch-snmp proxy as deployed.
if HOST_SPEC="$REPO/d03/host.toml" bash "$STEP" --units "$T/d03" >"$T/out" 2>&1; then ok "d03 host.toml is accepted"
else bad "d03 host.toml is accepted" "$(cat "$T/out")"; fi
S="$T/d03/asyla-proxy-switch-snmp.socket"; V="$T/d03/asyla-proxy-switch-snmp.service"
grep -qx "ListenStream=9116" "$S" 2>/dev/null && ok "socket listens on 9116" || bad "socket listens on 9116"
grep -qx "IPAddressDeny=any" "$S" 2>/dev/null && ok "socket denies by default" || bad "socket denies by default"
allows=$(grep '^IPAddressAllow=' "$S" 2>/dev/null | tr '\n' ' ')
[ "$allows" = "IPAddressAllow=localhost IPAddressAllow=10.0.0.150 " ] && ok "socket allows localhost and 10.0.0.150 only" \
  || bad "socket allows localhost and 10.0.0.150 only" "$allows"
grep -qx "ExecStart=/usr/lib/systemd/systemd-socket-proxyd --connections-max=16 127.0.0.1:19116" "$V" 2>/dev/null \
  && ok "proxy forwards to 127.0.0.1:19116" || bad "proxy forwards to 127.0.0.1:19116"
[ "$(grep '^IPAddress' "$V" 2>/dev/null | tr '\n' ' ')" = "IPAddressDeny=any IPAddressAllow=localhost " ] \
  && ok "proxy may connect to localhost only" || bad "proxy may connect to localhost only"
grep -qx "DynamicUser=yes" "$V" 2>/dev/null && ok "proxy runs as a dynamic user" || bad "proxy runs as a dynamic user"
grep -qF '"127.0.0.1:19116:9116"' "$REPO/d03/apps/switch-monitor/compose.yml" \
  && ok "compose publishes the exporter on loopback only" || bad "compose publishes the exporter on loopback only"

# Bad tables are refused, and nothing is written for them.
refused() {  # NAME TOML
  printf '%s\n' "$2" > "$T/spec.toml"
  if HOST_SPEC="$T/spec.toml" bash "$STEP" --units "$T/bad" >"$T/out" 2>&1; then bad "refused: $1" "accepted"
  elif ls "$T/bad"/*.socket >/dev/null 2>&1; then bad "refused: $1" "units written"
  else ok "refused: $1"; fi
  rm -rf "$T/bad"
}
P='[[port_proxy]]
name = "x"
listen = 9116'
refused "no tables" '[vm]'
refused "target off loopback" "$P"$'\ntarget = "10.0.0.62:19116"\nallow = ["10.0.0.150"]'
refused "target is the listen port" "$P"$'\ntarget = "127.0.0.1:9116"\nallow = ["10.0.0.150"]'
refused "empty allow" "$P"$'\ntarget = "127.0.0.1:19116"\nallow = []'
refused "allow not an address" "$P"$'\ntarget = "127.0.0.1:19116"\nallow = ["the-mini"]'
refused "host bits in a prefix" "$P"$'\ntarget = "127.0.0.1:19116"\nallow = ["10.0.0.150/24"]'
refused "unknown key" "$P"$'\ntarget = "127.0.0.1:19116"\nallow = ["10.0.0.150"]\nopen = true'
refused "bad name" '[[port_proxy]]
name = "X Y"
listen = 9116
target = "127.0.0.1:19116"
allow = ["10.0.0.150"]'
refused "duplicate port" "$P"$'\ntarget = "127.0.0.1:19116"\nallow = ["10.0.0.150"]\n[[port_proxy]]\nname = "y"\nlisten = 9116\ntarget = "127.0.0.1:19117"\nallow = ["10.0.0.150"]'

exit "$fail"
