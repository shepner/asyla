#!/bin/bash
# d01/apps/media/push-where-to-stream.sh (asyla #1247): the ssh it runs, with ssh stubbed on PATH.
# The default target and no -i; SSH_IDENTITY adds -i and IdentitiesOnly; RESTART=1 adds a second ssh
# that restarts where-to-stream and waits for /healthz, and a failed wait fails the push. A repo with
# no serve.py is refused before any ssh. Nothing here reaches a host.
# Run: bash scripts/tests/test_push_where_to_stream_sh.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUSH="$REPO/d01/apps/media/push-where-to-stream.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }

# The stub: one line of arguments per call in $T/calls, stdin drained; the Nth call exits with the
# Nth word of STUB_EXITS (default 0).
mkdir -p "$T/bin"
printf '%s\n' '#!/bin/bash' \
  'n=$(( $(wc -l <"$STUB_LOG" 2>/dev/null || echo 0) + 1 ))' \
  'printf "%s\n" "$*" >>"$STUB_LOG"' \
  'cat >/dev/null' \
  'set -- ${STUB_EXITS:-}; shift $(( n - 1 )) 2>/dev/null || set --' \
  'exit "${1:-0}"' >"$T/bin/ssh"
chmod +x "$T/bin/ssh"

# A where-to-stream stand-in: a committed serve.py.
W="$T/wts"
mkdir -p "$W"
echo 'print("stand-in")' >"$W/serve.py"
git -C "$W" init -q
git -C "$W" add serve.py
git -C "$W" -c user.name=t -c user.email=t@invalid commit -q -m stand-in

push() {  # ENV... -- runs the push with the stub; output in $T/out, calls in $T/calls
  rm -f "$T/calls"
  env PATH="$T/bin:$PATH" STUB_LOG="$T/calls" "$@" bash "$PUSH" "$W" >"$T/out" 2>&1
}

push D01_SSH=d01
rc=$?
[ "$rc" = 0 ] && ok "a plain push exits 0" || bad "a plain push exits 0" "exit $rc: $(cat "$T/out")"
[ "$(wc -l <"$T/calls" | tr -d ' ')" = 1 ] && ok "a plain push is one ssh" || bad "a plain push is one ssh" "$(cat "$T/calls")"
grep -q '^d01 set -e; rm -rf ' "$T/calls" && ok "the default target, no -i" || bad "the default target, no -i" "$(cat "$T/calls")"
grep -q 'docker restart' "$T/calls" && bad "no restart without RESTART=1" || ok "no restart without RESTART=1"

push D01_SSH=docker@test01 SSH_IDENTITY=/k/docker_rsa RESTART=1
rc=$?
[ "$rc" = 0 ] && ok "a push with RESTART=1 exits 0" || bad "a push with RESTART=1 exits 0" "exit $rc: $(cat "$T/out")"
[ "$(grep -c '^-i /k/docker_rsa -o IdentitiesOnly=yes docker@test01 ' "$T/calls")" = 2 ] \
  && ok "SSH_IDENTITY: both calls take -i and IdentitiesOnly, to D01_SSH" || bad "SSH_IDENTITY: both calls take -i" "$(cat "$T/calls")"
sed -n 2p "$T/calls" | grep -q 'docker restart where-to-stream' && sed -n 2p "$T/calls" | grep -q '/healthz' \
  && ok "the second call restarts where-to-stream and waits for /healthz" || bad "the second call restarts and waits" "$(cat "$T/calls")"
grep -q '\[OK\] where-to-stream restarted' "$T/out" && ok "it says the restart answered" || bad "it says the restart answered" "$(cat "$T/out")"

push D01_SSH=docker@test01 RESTART=1 STUB_EXITS="0 1"
rc=$?
[ "$rc" != 0 ] && grep -q 'did not answer /healthz' "$T/out" && ok "a restart that does not answer fails the push" \
  || bad "a restart that does not answer fails the push" "exit $rc: $(cat "$T/out")"

rm "$W/serve.py"
push D01_SSH=d01
rc=$?
[ "$rc" != 0 ] && [ ! -s "$T/calls" ] && ok "a repo with no serve.py is refused before any ssh" \
  || bad "a repo with no serve.py is refused before any ssh" "exit $rc: $(cat "$T/calls" 2>/dev/null)"

exit "$fail"
