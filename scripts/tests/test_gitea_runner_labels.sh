#!/bin/bash
# Offline test of the label choice in docker/gitea-runner/gitea-runner.sh: d01-d03 keep their fixed
# labels, any other host takes [runner] labels from its own <host>/host.toml, and a host with no
# usable labels is refused. Runs `gitea-runner.sh status` (read-only) from a temp copy of the
# tree, with a stub `hostname` first on PATH. Nothing is installed and no host is contacted.
#
#   scripts/tests/test_gitea_runner_labels.sh
#
# Exit 0 when every case passes.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts/docker" "$T/bin"
cp -R "$REPO/docker/gitea-runner" "$T/scripts/docker/"
fails=0

# case NAME HOST SPEC WANT: WANT is the labels line of `status`, or REFUSED.
case_() {
  local name="$1" host="$2" spec="$3" want="$4" out rc got
  rm -rf "$T/scripts/$host"
  mkdir -p "$T/scripts/$host/apps/gitea-runner"
  ln -s ../../../docker/gitea-runner/gitea-runner.sh "$T/scripts/$host/apps/gitea-runner/gitea-runner.sh"
  [ -z "$spec" ] || printf '%s\n' "$spec" > "$T/scripts/$host/host.toml"
  printf '#!/bin/sh\necho %s\n' "$host" > "$T/bin/hostname"
  chmod +x "$T/bin/hostname"
  out=$(PATH="$T/bin:$PATH" bash "$T/scripts/$host/apps/gitea-runner/gitea-runner.sh" status 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then got=REFUSED; else got=$(sed -n 's/^labels: *//p' <<<"$out"); fi
  if [ "$got" = "$want" ]; then echo "ok    $name: $got"; else echo "FAIL  $name: got '$got', want '$want'"; fails=$((fails + 1)); fi
}

case_ "d03 keeps its fixed labels" d03 "" "asyla:host,d03:host,docker:host"
case_ "d03 ignores labels in its spec" d03 $'[runner]\nlabels = ["build-test"]' "asyla:host,d03:host,docker:host"
case_ "test01 takes its spec's label" test01 $'[runner]\nenabled = true\nlabels = ["build-test"]' "build-test:host"
# While test01 rehearses a production host ([replica], no runner: e.g. gap G1), its hello spec as at 226904e.
if grep -q '^\[replica\]' "$REPO/test01/host.toml"; then
  case_ "test01's hello spec (226904e)" test01 "$(git -C "$REPO" show 226904e:test01/host.toml)" "build-test:host"
else
  case_ "the repo's own test01 spec" test01 "$(cat "$REPO/test01/host.toml")" "build-test:host"
fi
case_ "several labels, in order" d04 $'[runner]\nlabels = ["theorg", "prod", "d04"]' "theorg:host,prod:host,d04:host"
case_ "no spec" d09 "" REFUSED
case_ "a spec with no labels" d04 $'[runner]\nenabled = true' REFUSED
case_ "an empty list" d04 $'[runner]\nlabels = []' REFUSED
case_ "a label with a space" d04 $'[runner]\nlabels = ["build test"]' REFUSED
case_ "a label that is not a name" d04 $'[runner]\nlabels = ["docker:host"]' REFUSED
case_ "labels not a list" d04 $'[runner]\nlabels = "build-test"' REFUSED

[ "$fails" -eq 0 ] && echo "all cases passed" || echo "$fails case(s) failed"
exit $((fails > 0))
