#!/bin/bash
# Offline test of `gitea.sh verify` and `gitea.sh restart verify` (d03/apps/gitea/gitea.sh).
# Touches no host and no real Gitea: `docker` is a stub on PATH, and Gitea is a stand-in HTTP
# server on a free local port that starts answering a few seconds after the stub's `up`, as the
# real container does. Needs bash, curl and python3. Run from anywhere:
#
#   scripts/tests/test_gitea_verify.sh
#
# Exit 0 when every case passes.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GITEA_SH="$REPO/d03/apps/gitea/gitea.sh"
T="$(mktemp -d)"
trap 'stop_standin; rm -rf "$T"' EXIT

# gitea.sh loads ~/scripts/docker/{common.env,backup_lib.sh}: give it a HOME whose scripts/ is
# this checkout.
mkdir -p "$T/home" "$T/bin"
ln -s "$REPO" "$T/home/scripts"

PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"

cat > "$T/standin.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok\n")
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

# The stub: `docker compose ... up -d` starts the stand-in STANDIN_DELAY seconds later (never,
# when STANDIN_DELAY is "never"); `down` stops it. Anything else is a no-op.
cat > "$T/bin/docker" <<STUB
#!/bin/bash
case " \$* " in
  *" down "*) [ -f "$T/standin.pid" ] && kill "\$(cat "$T/standin.pid")" 2>/dev/null; rm -f "$T/standin.pid" ;;
  *" up "*)
    [ "\${STANDIN_DELAY:-0}" = never ] && exit 0
    ( sleep "\${STANDIN_DELAY:-0}"; exec python3 "$T/standin.py" "$PORT" ) >/dev/null 2>&1 &
    echo \$! > "$T/standin.pid" ;;
esac
exit 0
STUB
chmod +x "$T/bin/docker"

stop_standin() {
  [ -f "$T/standin.pid" ] && kill "$(cat "$T/standin.pid")" 2>/dev/null
  rm -f "$T/standin.pid"
}

# run_gitea <wait seconds> <standin delay> <switch ...>: sets RC, OUT and TOOK.
run_gitea() {
  local wait_s="$1" delay="$2" t0=$SECONDS
  shift 2
  OUT="$(HOME="$T/home" PATH="$T/bin:$PATH" STANDIN_DELAY="$delay" \
    GITEA_VERIFY_WAIT_S="$wait_s" GITEA_LOCAL_URL="http://127.0.0.1:$PORT" \
    GITEA_PUBLIC_URL="http://127.0.0.1:$PORT" bash "$GITEA_SH" "$@" 2>&1)"
  RC=$?
  TOOK=$((SECONDS - t0))
}

fails=0
check() {  # check <name> <condition as a string>
  if eval "$2"; then
    echo "ok    $1 (exit $RC, ${TOOK}s)"
  else
    echo "FAIL  $1 (exit $RC, ${TOOK}s): expected $2"
    echo "$OUT" | sed 's/^/        /'
    fails=$((fails + 1))
  fi
}

# 1. Gitea already answering: verify passes at once and does not announce a wait.
run_gitea 30 0 up
sleep 1
run_gitea 30 0 verify
check "verify, Gitea already up" '[ "$RC" -eq 0 ] && [ "$TOOK" -le 3 ] && ! grep -q "Waiting" <<<"$OUT"'
stop_standin

# 2. The race: Gitea answers 5 s after `up`. `restart verify` in one call must pass.
run_gitea 30 5 restart verify
check "restart verify, Gitea answers after 5s" '[ "$RC" -eq 0 ] && grep -q "Waiting" <<<"$OUT" && grep -q "Local :3000 OK" <<<"$OUT"'
stop_standin

# 3. Negative control: the same restart with no wait fails, as the script did before the fix.
#    If this passes, case 2 proves nothing.
run_gitea 0 5 restart verify
check "restart verify with no wait fails (control)" '[ "$RC" -ne 0 ]'
stop_standin

# 4. Gitea never comes up: verify still fails, after the bounded wait and not before.
run_gitea 4 never restart verify
check "restart verify, Gitea never answers" '[ "$RC" -ne 0 ] && [ "$TOOK" -ge 4 ] && [ "$TOOK" -le 15 ] && grep -q "check failed" <<<"$OUT"'
stop_standin

if [ "$fails" -eq 0 ]; then
  echo "all cases passed"
else
  echo "$fails case(s) failed"
  exit 1
fi
