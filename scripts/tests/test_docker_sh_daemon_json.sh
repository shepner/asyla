#!/bin/bash
# build/setup/docker.sh --print-daemon-json: the daemon.json a host spec gives (asyla #1237). With
# no [docker] table the bytes are origin/master's DAEMON_JSON_WANT exactly (so the hosts built
# before ci01 see no change); the design's ci01 table gives the expected JSON; bad values are
# refused. containerd_root leaves the JSON unchanged; --print-containerd-dropin gives its
# containerd.service drop-in (nothing without the key) and --check-data-disk refuses a root on the
# root filesystem (findmnt is a stand-in). No root; nothing is written outside a temp directory
# and no host is contacted.
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

# containerd_root is not a daemon.json key: it leaves --print-daemon-json unchanged.
CR='containerd_root = "/mnt/docker/containerd"'
render "$CI
$CR"
cmp -s "$T/out" "$T/want-ci01" && ok "containerd_root: the ci01 JSON unchanged" || bad "containerd_root: the ci01 JSON unchanged" "$(diff "$T/want-ci01" "$T/out"; cat "$T/err")"
if [ -f "$T/want-default" ]; then
  render "[docker]
$CR"
  cmp -s "$T/out" "$T/want-default" && ok "only containerd_root: origin/master's default bytes" \
    || bad "only containerd_root: origin/master's default bytes" "$(cat "$T/out" "$T/err")"
fi

# --print-containerd-dropin: the containerd.service drop-in, or nothing without containerd_root.
dropin() {   # dropin SPEC_TEXT|- : --print-containerd-dropin into $T/out
  if [ "$1" = - ]; then
    env -u HOST_SPEC bash "$STEP" --print-containerd-dropin > "$T/out" 2> "$T/err"
  else
    printf '%s\n' "$1" > "$T/host.toml"
    HOST_SPEC="$T/host.toml" bash "$STEP" --print-containerd-dropin > "$T/out" 2> "$T/err"
  fi
}
cat > "$T/want-dropin" <<'EOF'
# build/setup/docker.sh (asyla-hosts): containerd's root (the containerd image store's images and
# snapshots) is on the data disk; wait for it, and start containerd with that root.
[Unit]
RequiresMountsFor=/mnt/docker/containerd

[Service]
ExecStart=
ExecStart=/usr/bin/containerd --root /mnt/docker/containerd
EOF
dropin "$CI
$CR"
cmp -s "$T/out" "$T/want-dropin" && ok "containerd_root: the expected drop-in" || bad "containerd_root: the expected drop-in" "$(diff "$T/want-dropin" "$T/out"; cat "$T/err")"
for c in "no HOST_SPEC|-" "no [docker] table|[vm]
node = \"vmh01\"" "an empty [docker] table|[docker]" "[docker] without containerd_root|$CI"; do
  name="${c%%|*}"; spec="${c#*|}"
  dropin "$spec"; rc=$?
  [ "$rc" -eq 0 ] && [ ! -s "$T/out" ] && ok "$name: no containerd drop-in" || bad "$name: no containerd drop-in" "rc=$rc $(cat "$T/out" "$T/err")"
done
n=0
for spec in "$REPO"/*/host.toml; do
  HOST_SPEC="$spec" bash "$STEP" --print-containerd-dropin > "$T/out" 2>&1 || bad "$(basename "$(dirname "$spec")"): drop-in renders" "$(cat "$T/out")"
  if grep -q '^containerd_root = "/mnt/docker/containerd"$' "$spec"; then
    cmp -s "$T/out" "$T/want-dropin" || bad "$(basename "$(dirname "$spec")"): the expected drop-in" "$(cat "$T/out")"
  else
    [ ! -s "$T/out" ] || bad "$(basename "$(dirname "$spec")"): no containerd drop-in" "$(cat "$T/out")"
  fi
  n=$((n + 1))
done
ok "every repo spec ($n): the drop-in only where containerd_root is set (any failure above)"
for h in ci01; do
  grep -q '^containerd_root = "/mnt/docker/containerd"$' "$REPO/$h/host.toml" && ok "$h sets containerd_root" || bad "$h sets containerd_root"
done

# --check-data-disk: data_root and containerd_root must not be on the root filesystem. findmnt is
# a stand-in on PATH that prints FAKE_MOUNT (the mount holding the path).
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "$FAKE_MOUNT"\n' > "$T/bin/findmnt"; chmod +x "$T/bin/findmnt"
disk() {   # disk MOUNT SPEC_TEXT : --check-data-disk with findmnt answering MOUNT
  printf '%s\n' "$2" > "$T/host.toml"
  FAKE_MOUNT="$1" PATH="$T/bin:$PATH" HOST_SPEC="$T/host.toml" bash "$STEP" --check-data-disk > "$T/out" 2> "$T/err"
}
disk /mnt/docker "$CI
$CR" && ok "--check-data-disk: both on the data disk: passes" || bad "--check-data-disk: both on the data disk" "$(cat "$T/out" "$T/err")"
disk / "[docker]
$CR"; rc=$?
[ "$rc" -ne 0 ] && grep -qF "containerd_root /mnt/docker/containerd would be on the root filesystem" "$T/err" \
  && ok "refused: a containerd_root on the root filesystem" || bad "refused: a containerd_root on the root filesystem" "rc=$rc $(cat "$T/err")"
disk / "$CI"; rc=$?
[ "$rc" -ne 0 ] && grep -qF "data_root /mnt/docker/engine would be on the root filesystem" "$T/err" \
  && ok "refused: a data_root on the root filesystem" || bad "refused: a data_root on the root filesystem" "rc=$rc $(cat "$T/err")"
disk / '[docker]
registry_mirrors = ["http://127.0.0.1:5000"]' && ok "--check-data-disk: neither key: passes" || bad "--check-data-disk: neither key" "$(cat "$T/err")"

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
refused "a relative containerd_root" $'[docker]\ncontainerd_root = "mnt/docker/containerd"' "containerd_root must be an absolute path"
refused "a containerd_root with .." $'[docker]\ncontainerd_root = "/mnt/docker/../containerd"' "containerd_root must be an absolute path"
refused "a containerd_root that is not a string" $'[docker]\ncontainerd_root = 1' "containerd_root must be an absolute path"
refused "a containerd_root inside data_root" $'[docker]\ndata_root = "/mnt/docker/engine"\ncontainerd_root = "/mnt/docker/engine/containerd"' "must be separate directories"
refused "a data_root inside containerd_root" $'[docker]\ndata_root = "/mnt/docker/c/engine"\ncontainerd_root = "/mnt/docker/c"' "must be separate directories"
refused "a containerd_root equal to data_root" $'[docker]\ndata_root = "/mnt/docker/engine"\ncontainerd_root = "/mnt/docker/engine"' "must be separate directories"
for opt in --print-containerd-dropin --check-data-disk; do
  printf '%s\n' $'[docker]\ncontainerd_root = "containerd"' > "$T/host.toml"
  HOST_SPEC="$T/host.toml" bash "$STEP" "$opt" > "$T/out" 2> "$T/err"; rc=$?
  [ "$rc" -ne 0 ] && [ ! -s "$T/out" ] && grep -qF "containerd_root must be an absolute path" "$T/err" \
    && ok "refused by $opt: a relative containerd_root" || bad "refused by $opt: a relative containerd_root" "rc=$rc $(cat "$T/out" "$T/err")"
done
refused "an ftp mirror" $'[docker]\nregistry_mirrors = ["ftp://127.0.0.1:5000"]' "must be an http(s) URL"
refused "a mirror with no scheme" $'[docker]\nregistry_mirrors = ["127.0.0.1:5000"]' "must be an http(s) URL"
refused "a mirror with a path" $'[docker]\nregistry_mirrors = ["http://127.0.0.1:5000/v2"]' "must be an http(s) URL"
refused "mirrors not a list" $'[docker]\nregistry_mirrors = "http://127.0.0.1:5000"' "must be a non-empty list of URLs"

[ "$fails" -eq 0 ] && echo "all cases passed" || echo "$fails case(s) failed"
exit $((fails > 0))
