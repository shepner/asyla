#!/bin/bash
# Every host's update_scripts.sh: which [replica] of = values the updater accepts. It checks out the
# source's tree, so a bad value must stop the run: d0N and ns01/ns02 (a test01 replica of a name
# server) pass, anything else and the host itself are refused. The check is run as each copy has it
# (the line read from the file), not a copy of it here. Run: bash scripts/tests/test_update_scripts_replica_source.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }

# Only the new-form updaters read [replica] (ns01 and vmh0N still have the old GitHub one).
copies=$(cd "$REPO" && grep -l '^REPLICA_OF=""' */update_scripts.sh)
[ -n "$copies" ] || { echo "FAIL no update_scripts.sh found"; exit 1; }
for f in $copies; do
  line=$(grep -E '^[[:space:]]*if ! \[\[ "\$REPLICA_OF" =~ ' "$REPO/$f")
  if [ "$(printf '%s\n' "$line" | grep -c .)" -ne 1 ]; then
    bad "$f: one replica-source check" "found $(printf '%s\n' "$line" | grep -c .)"
    continue
  fi
  # The condition alone: `if COND; then` -> a function returning 0 when the value is refused.
  cond=${line#*if }; cond=${cond%; then*}
  eval "refused() { local REPLICA_OF=\"\$1\" HOSTNAME=\"\$2\"; $cond; }"
  got=""
  for v in d01 d03 d06 ns01 ns02; do refused "$v" test01 && got+=" $v"; done
  [ -z "$got" ] && ok "$f: accepts d01 d03 d06 ns01 ns02 as a source" || bad "$f: refused a valid source" "$got"
  got=""
  for v in ns03 ns1 d10 dd01 test01x "ns02;x" " ns02" "d01 " vmh01 ""; do refused "$v" test01 || got+=" [$v]"; done
  [ -z "$got" ] && ok "$f: refuses ns03, d10, vmh01, padded or joined names" || bad "$f: accepted a bad source" "$got"
  refused ns02 ns02 && refused d03 d03 && ok "$f: refuses the host itself" || bad "$f: accepted the host itself"
done

exit "$fail"
