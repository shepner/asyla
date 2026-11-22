#!/bin/bash
# build/setup/docker.sh --print-daemon-json: the daemon.json a host spec gives (asyla #1237). With
# no [docker] table the bytes are origin/master's DAEMON_JSON_WANT exactly (so the hosts built
# before ci01 see no change); the design's ci01 table gives the expected JSON; bad values are
# refused. No root; nothing is written outside a temp directory and no host is contacted.
# Run: bash scripts/tests/test_docker_sh_daemon_json.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STEP="$REPO/build/setup/docker.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1${2:+: $2}"; fails=$((fails + 1)); }

render() {   # render SPEC_TEXT|- : --print-daemon-json for that spec ("-": no HOST_SPEC) into $T/out
  if [ "$1" = - ]; then
    env -u HOST_SPEC bash "$STEP" --print-daemon-json > "$T/out" 2> "$T/err"
  else
    printf '%s\n' "$1" > "$T/host.toml"
    HOST_SPEC="$T/host.toml" bash "$STEP" --print-daemon-json > "$T/out" 2> "$T/err"
  fi
}

bash -n "$STEP" && ok "docker.sh parses" || bad "docker.sh parses"

# origin/master's DAEMON_JSON_WANT, as its step wrote it (printf '%s\n'). Only that one
# single-quoted assignment is evaluated, not the script.
if git -C "$REPO" show origin/master:build/setup/docker.sh > "$T/master.sh" 2>/dev/null; then
  assign=$(sed -n "/^DAEMON_JSON_WANT='/,/^}'\$/p" "$T/master.sh")
  if [ -n "$assign" ] && OLD=$(eval "$assign"; printf '%s' "$DAEMON_JSON_WANT") && [ -n "$OLD" ]; then
    printf '%s\n' "$OLD" > "$T/want-default"
    for c in "no HOST_SPEC|-" "a spec with no [docker] table|[vm]
node = \"vmh01\"" "an empty [docker] table|[docker]" "only another [docker...] table|[docker_extra]
x = 1"; do
      name="${c%%|*}"; spec="${c#*|}"
      render "$spec"
      cmp -s "$T/out" "$T/want-default" && ok "$name: origin/master's bytes" \
        || bad "$name: origin/master's bytes" "$(cat "$T/out" "$T/err")"
    done
    n=0
    for spec in "$REPO"/*/host.toml; do
      grep -q '^\[docker\]' "$spec" && continue
      HOST_SPEC="$spec" bash "$STEP" --print-daemon-json > "$T/out" 2>&1
      cmp -s "$T/out" "$T/want-default" || bad "$(basename "$(dirname "$spec")"): origin/master's bytes" "$(cat "$T/out")"
      n=$((n + 1))
    done
    ok "every repo spec without [docker] ($n) renders origin/master's bytes (any failure above)"
  else
    bad "origin/master's DAEMON_JSON_WANT not found"
  fi
else
  bad "cannot read origin/master's docker.sh (git fetch?)"
fi

# The design's ci01 table (ci01-design.md, asyla #1237).
CI='[docker]
data_root = "/mnt/docker/engine"
default_address_pools = [{ base = "10.210.0.0/16", size = 24 }]
registry_mirrors = ["http://127.0.0.1:5000"]'
cat > "$T/want-ci01" <<'EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5",
    "compress": "true"
  },
  "data-root": "/mnt/docker/engine",
  "default-address-pools": [
    {
      "base": "10.210.0.0/16",
      "size": 24
    }
  ],
  "registry-mirrors": [
    "http://127.0.0.1:5000"
  ]
}
EOF
render "$CI"
cmp -s "$T/out" "$T/want-ci01" && ok "the ci01 table: the expected JSON" || bad "the ci01 table" "$(diff "$T/want-ci01" "$T/out"; cat "$T/err")"
render "$CI"; cp "$T/out" "$T/again"; render "$CI"
cmp -s "$T/out" "$T/again" && ok "the same spec gives the same bytes" || bad "the same spec gives the same bytes"
render "[docker]
registry_mirrors = [\"https://mirror.example\"]"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if list(d) == ["log-driver", "log-opts", "registry-mirrors"] else 1)' "$T/out" \
  && ok "one key: only that key is added" || bad "one key: only that key is added" "$(cat "$T/out" "$T/err")"

# refused NAME SPEC NEEDLE: exit non-zero, nothing on stdout, NEEDLE in the message.
refused() {
  local name="$1" spec="$2" needle="$3" rc
  render "$spec"; rc=$?
  if [ "$rc" -ne 0 ] && [ ! -s "$T/out" ] && grep -qF -- "$needle" "$T/err"; then ok "refused: $name"
  else bad "refused: $name" "rc=$rc out=$(cat "$T/out") err=$(cat "$T/err")"; fi
}
refused "an unknown key" $'[docker]\nmtu = 1400' "unknown keys ['mtu']"
refused "a [[docker.x]] sub-table" $'[docker]\n[[docker.x]]\na = 1' "unknown keys ['x']"
refused "a base with host bits" $'[docker]\ndefault_address_pools = [{ base = "10.210.0.1/16", size = 24 }]' "is not an IPv4 network"
refused "a base that is not a CIDR" $'[docker]\ndefault_address_pools = [{ base = "10.210.0.0/33", size = 24 }]' "is not an IPv4 network"
refused "an IPv6 base" $'[docker]\ndefault_address_pools = [{ base = "fd00::/48", size = 64 }]' "is not an IPv4 network"
refused "a size over 30" $'[docker]\ndefault_address_pools = [{ base = "10.210.0.0/16", size = 31 }]' "must be 16-30"
refused "a size under 16" $'[docker]\ndefault_address_pools = [{ base = "10.0.0.0/8", size = 12 }]' "must be 16-30"
refused "a size shorter than the base" $'[docker]\ndefault_address_pools = [{ base = "10.210.0.0/20", size = 18 }]' "must be 16-30 and not shorter"
refused "a size as a string" $'[docker]\ndefault_address_pools = [{ base = "10.210.0.0/16", size = "24" }]' "must be 16-30"
refused "a pool without size" $'[docker]\ndefault_address_pools = [{ base = "10.210.0.0/16" }]' "must have exactly base and size"
refused "an empty pool list" $'[docker]\ndefault_address_pools = []' "must be a non-empty list"
refused "a relative data_root" $'[docker]\ndata_root = "mnt/docker/engine"' "data_root must be an absolute path"
refused "a data_root with .." $'[docker]\ndata_root = "/mnt/docker/../engine"' "data_root must be an absolute path"
refused "a data_root with a space" $'[docker]\ndata_root = "/mnt/docker/my engine"' "data_root must be an absolute path"
refused "an ftp mirror" $'[docker]\nregistry_mirrors = ["ftp://127.0.0.1:5000"]' "must be an http(s) URL"
refused "a mirror with no scheme" $'[docker]\nregistry_mirrors = ["127.0.0.1:5000"]' "must be an http(s) URL"
refused "a mirror with a path" $'[docker]\nregistry_mirrors = ["http://127.0.0.1:5000/v2"]' "must be an http(s) URL"
refused "mirrors not a list" $'[docker]\nregistry_mirrors = "http://127.0.0.1:5000"' "must be a non-empty list of URLs"

[ "$fails" -eq 0 ] && echo "all cases passed" || echo "$fails case(s) failed"
exit $((fails > 0))
