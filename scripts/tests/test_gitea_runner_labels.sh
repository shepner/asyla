#!/bin/bash
# Offline test of the label choice in docker/gitea-runner/gitea-runner.sh: d01-d03 keep their fixed
# labels, any other host takes [runner] labels from its own <host>/host.toml, and a host with no
# usable labels is refused. Docker mode (asyla #1237): labels NAME:docker://IMAGE, capacity and
# container options in the rendered config, bad values refused; host mode renders byte-for-byte
# what origin/master's script renders. Runs `gitea-runner.sh status` and `config` (both read-only)
# from a temp copy of the tree, with a stub `hostname` first on PATH. Nothing is installed and no
# host is contacted.
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

pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

# host_ TREE HOST SPEC: HOST's apps symlink and host.toml (none when SPEC is empty) in TREE, and
# the hostname stub.
host_() {
  local tree="$1" host="$2" spec="$3"
  rm -rf "$tree/scripts/$host"
  mkdir -p "$tree/scripts/$host/apps/gitea-runner"
  ln -s ../../../docker/gitea-runner/gitea-runner.sh "$tree/scripts/$host/apps/gitea-runner/gitea-runner.sh"
  [ -z "$spec" ] || printf '%s\n' "$spec" > "$tree/scripts/$host/host.toml"
  printf '#!/bin/sh\necho %s\n' "$host" > "$T/bin/hostname"
  chmod +x "$T/bin/hostname"
}

run_() {   # run_ TREE HOST SWITCH...
  local tree="$1" host="$2"; shift 2
  PATH="$T/bin:$PATH" bash "$tree/scripts/$host/apps/gitea-runner/gitea-runner.sh" "$@" 2>&1
}

# case NAME HOST SPEC WANT: WANT is the labels line of `status`, or REFUSED.
case_() {
  local name="$1" host="$2" spec="$3" want="$4" out rc got
  host_ "$T" "$host" "$spec"
  out=$(run_ "$T" "$host" status)
  rc=$?
  if [ "$rc" -ne 0 ]; then got=REFUSED; else got=$(sed -n 's/^labels: *//p' <<<"$out"); fi
  if [ "$got" = "$want" ]; then pass "$name: $got"; else fail "$name: got '$got', want '$want'"; fi
}

# config_ NAME HOST SPEC HAS|LACKS LINE: the rendered config (`config`) has, or lacks, LINE exactly.
config_() {
  local name="$1" host="$2" spec="$3" how="$4" line="$5" out
  host_ "$T" "$host" "$spec"
  if ! out=$(run_ "$T" "$host" config); then fail "$name: config refused: $out"; return; fi
  if grep -qxF -- "$line" <<<"$out"; then
    [ "$how" = HAS ] && pass "$name" || fail "$name: has '$line'"
  else
    [ "$how" = LACKS ] && pass "$name" || fail "$name: no line '$line' in:"$'\n'"$out"
  fi
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
case_ "mode = host said outright" d04 $'[runner]\nlabels = ["theorg"]\nmode = "host"' "theorg:host"
case_ "no spec" d09 "" REFUSED
case_ "a spec with no labels" d04 $'[runner]\nenabled = true' REFUSED
case_ "an empty list" d04 $'[runner]\nlabels = []' REFUSED
case_ "a label with a space" d04 $'[runner]\nlabels = ["build test"]' REFUSED
case_ "a label that is not a name" d04 $'[runner]\nlabels = ["docker:host"]' REFUSED
case_ "labels not a list" d04 $'[runner]\nlabels = "build-test"' REFUSED
case_ "an unknown [runner] key" d04 $'[runner]\nlabels = ["theorg"]\ntags = ["x"]' REFUSED

# Docker mode (the design's ci01 [runner], asyla #1237).
IMG="docker.gitea.com/runner-images:ubuntu-latest"
CI=$'[runner]\nenabled = true\nlabels = ["theorg", "ci", "ci01"]\nmode = "docker"\nimage = "'"$IMG"$'"'
CI_FULL="$CI"$'\ncapacity = 6\ncontainer_options = "--cpus=2 --memory=3g"'
case_ "docker mode: NAME:docker://IMAGE labels" ci01 "$CI_FULL" \
  "theorg:docker://$IMG,ci:docker://$IMG,ci01:docker://$IMG"
case_ "docker mode: an image with a port and a digest" ci01 \
  $'[runner]\nlabels = ["ci"]\nmode = "docker"\nimage = "registry.example:5000/ci/img:1.2@sha256:'"$(printf 'a%.0s' $(seq 64))"$'"' \
  "ci:docker://registry.example:5000/ci/img:1.2@sha256:$(printf 'a%.0s' $(seq 64))"
host_ "$T" ci01 "$CI_FULL"
got=$(run_ "$T" ci01 status | sed -n 's/^mode: *//p')
[ "$got" = docker ] && pass "docker mode: status prints mode: docker" || fail "status mode: got '$got'"
config_ "docker mode: label lines in config.yaml" ci01 "$CI_FULL" HAS "    - \"ci01:docker://$IMG\""
config_ "docker mode: capacity from the spec" ci01 "$CI_FULL" HAS "  capacity: 6"
config_ "docker mode: capacity 10 is gone" ci01 "$CI_FULL" LACKS "  capacity: 10"
config_ "docker mode: a container section" ci01 "$CI_FULL" HAS "container:"
config_ "docker mode: container options" ci01 "$CI_FULL" HAS '  options: "--cpus=2 --memory=3g"'
config_ "docker mode: the comment cites config.example.yaml" ci01 "$CI_FULL" HAS \
  "  # Keys: https://gitea.com/gitea/runner/raw/tag/v4.1.0/internal/pkg/config/config.example.yaml"
config_ "docker mode: no docker_host key (its default)" ci01 "$CI_FULL" LACKS '  docker_host: ""'
config_ "docker mode, no capacity: config.yaml's 10" ci01 "$CI" HAS "  capacity: 10"
config_ "docker mode, no options: no options line" ci01 "$CI" LACKS '  options: ""'
config_ "host mode: no container section" d04 $'[runner]\nlabels = ["theorg"]' LACKS "container:"
host_ "$T" ci01 "$CI_FULL"
out=$(run_ "$T" ci01 config | python3 -c '
import sys
# The rendered file is YAML a reader takes as runner.capacity 6 and container.options: a crude
# check without PyYAML: the container block comes after the runner block, at column 0.
t = sys.stdin.read().splitlines()
print(t.index("runner:") < t.index("container:") and t[-1] == "  options: \"--cpus=2 --memory=3g\"")')
[ "$out" = True ] && pass "docker mode: container block follows the runner block" || fail "container block order: $out"

case_ "docker mode: no image" ci01 $'[runner]\nlabels = ["ci"]\nmode = "docker"' REFUSED
case_ "docker mode: an image with a scheme" ci01 $'[runner]\nlabels = ["ci"]\nmode = "docker"\nimage = "docker://'"$IMG"$'"' REFUSED
case_ "docker mode: an image with a blank" ci01 $'[runner]\nlabels = ["ci"]\nmode = "docker"\nimage = "ubuntu latest"' REFUSED
case_ "docker mode: an image with a comma" ci01 $'[runner]\nlabels = ["ci"]\nmode = "docker"\nimage = "a,b"' REFUSED
case_ "docker mode: an image not a string" ci01 $'[runner]\nlabels = ["ci"]\nmode = "docker"\nimage = 5' REFUSED
case_ "docker mode: options with a ;" ci01 "$CI"$'\ncontainer_options = "--cpus=2; reboot"' REFUSED
case_ "docker mode: options with a quote" ci01 "$CI"$'\ncontainer_options = "--label=\\"x\\""' REFUSED
case_ "docker mode: options with \$()" ci01 "$CI"$'\ncontainer_options = "--name=$(id)"' REFUSED
case_ "docker mode: options not starting with -" ci01 "$CI"$'\ncontainer_options = "cpus=2"' REFUSED
case_ "docker mode: options not a string" ci01 "$CI"$'\ncontainer_options = ["--cpus=2"]' REFUSED
case_ "docker mode: capacity 0" ci01 "$CI"$'\ncapacity = 0' REFUSED
case_ "docker mode: capacity 100" ci01 "$CI"$'\ncapacity = 100' REFUSED
case_ "docker mode: capacity a string" ci01 "$CI"$'\ncapacity = "6"' REFUSED
case_ "docker mode: capacity true" ci01 "$CI"$'\ncapacity = true' REFUSED
case_ "an unknown mode" ci01 $'[runner]\nlabels = ["ci"]\nmode = "kube"' REFUSED
case_ "host mode with an image" d04 $'[runner]\nlabels = ["ci"]\nimage = "'"$IMG"$'"' REFUSED
case_ "host mode with capacity" d04 $'[runner]\nlabels = ["ci"]\nmode = "host"\ncapacity = 6' REFUSED
case_ "host mode with container options" d04 $'[runner]\nlabels = ["ci"]\ncontainer_options = "--cpus=2"' REFUSED

# The script's IMAGE, OPTS and KEYS are build_host.py's RUNNER_IMAGE, RUNNER_OPTS and RUNNER_KEYS.
got=$(python3 - "$REPO" <<'PY'
import re, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts"))
import build_host
sh = (Path(sys.argv[1]) / "docker/gitea-runner/gitea-runner.sh").read_text()
img = re.search(r'^IMAGE = r"(.*)"$', sh, re.M).group(1)
opts = re.search(r'^OPTS = r"(.*)"$', sh, re.M).group(1)
keys = re.search(r'^KEYS = (\(.*\))$', sh, re.M).group(1)
label = f're.fullmatch("{build_host.RUNNER_LABEL.pattern}", l)' in sh
print(img == build_host.RUNNER_IMAGE.pattern and opts == build_host.RUNNER_OPTS.pattern
      and eval(keys) == build_host.RUNNER_KEYS and label)
PY
)
[ "$got" = True ] && pass "image, options, label and key rules are build_host.py's" || fail "rules differ from build_host.py: $got"

# Host mode is unchanged: origin/master's script renders the same config and labels for the same
# spec. Its copy has no `config` switch, so render_config is called from a copy cut before its
# switch dispatch (temp tree only).
O="$T/old"
mkdir -p "$O/scripts/docker/gitea-runner"
if git -C "$REPO" show origin/master:docker/gitea-runner/gitea-runner.sh > "$O/scripts/docker/gitea-runner/gitea-runner.full" \
   && git -C "$REPO" show origin/master:docker/gitea-runner/config.yaml > "$O/scripts/docker/gitea-runner/config.yaml"; then
  { sed '/^if \[ \$# -eq 0 \]; then$/,$d' "$O/scripts/docker/gitea-runner/gitea-runner.full"
    printf '%s\n' 'case "$1" in config) render_config ;; csv) labels_csv ;; esac'
  } > "$O/scripts/docker/gitea-runner/gitea-runner.sh"
  cmp -s "$O/scripts/docker/gitea-runner/config.yaml" "$REPO/docker/gitea-runner/config.yaml" \
    && pass "config.yaml is byte-identical to origin/master's" || fail "config.yaml differs from origin/master's"
  same_() {   # same_ NAME HOST SPEC
    local name="$1" host="$2" spec="$3" a b ca cb
    host_ "$O" "$host" "$spec"; a=$(run_ "$O" "$host" config); ca=$(run_ "$O" "$host" csv)
    host_ "$T" "$host" "$spec"; b=$(run_ "$T" "$host" config); cb=$(run_ "$T" "$host" status | sed -n 's/^labels: *//p')
    if [ -n "$a" ] && [ "$a" = "$b" ] && [ "$ca" = "$cb" ]; then pass "host mode as origin/master: $name"
    else fail "host mode differs from origin/master: $name"$'\n'"--- old ($ca)"$'\n'"$a"$'\n'"--- new ($cb)"$'\n'"$b"; fi
  }
  # Byte-for-byte: compare files, not $(...) (which drops trailing newlines).
  for h in d01 d02 d03; do
    host_ "$O" "$h" ""; run_ "$O" "$h" config > "$T/old.yaml"
    host_ "$T" "$h" ""; run_ "$T" "$h" config > "$T/new.yaml"
    [ -s "$T/old.yaml" ] && cmp -s "$T/old.yaml" "$T/new.yaml" && pass "$h's config.yaml file is byte-identical" || fail "$h's config.yaml bytes differ"
  done
  for h in d01 d02 d03; do same_ "$h (fixed labels)" "$h" ""; done
  for h in d04 d06; do same_ "the repo's $h spec" "$h" "$(cat "$REPO/$h/host.toml")"; done
  # test01 while it runs in host mode (not during a docker-mode proof, asyla #1237).
  if ! grep -q '^mode = "docker"' "$REPO/test01/host.toml"; then
    same_ "the repo's test01 spec" test01 "$(cat "$REPO/test01/host.toml")"
  fi
  same_ "test01's hello spec (226904e)" test01 "$(git -C "$REPO" show 226904e:test01/host.toml)"
  same_ "several labels" d05 $'[runner]\nlabels = ["theorg", "prod", "d05"]'
else
  fail "cannot read origin/master's gitea-runner.sh (git fetch?)"
fi

[ "$fails" -eq 0 ] && echo "all cases passed" || echo "$fails case(s) failed"
exit $((fails > 0))
