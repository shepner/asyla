#!/bin/bash
# Offline test of `gitea.sh verify` and `gitea.sh restart verify` (d04/apps/gitea/gitea.sh, the one
# copy since Gitea left d03 on 2026-10-16), where a local :3000 failure fails verify (case 5), and
# verify's read-only print of the package cleanup rules, which warns on drift (cases 7-10), and its
# read-only check of app.ini's [cron.cleanup_packages] (cases 11-15).
# Touches no host and no real Gitea: `docker` is a stub on PATH, Gitea is a stand-in HTTP
# server on a free local port that starts answering a few seconds after the stub's `up`, as the
# real container does, its DB is a fixture with d04's rules, and its app.ini (GITEA_APP_INI) a
# fixture with the cron section as the README has it. Needs bash, curl and python3.
# Run from anywhere:
#
#   scripts/tests/test_gitea_verify.sh
#
# Exit 0 when every case passes.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GITEA_SH="$REPO/d04/apps/gitea/gitea.sh"
GITEA_SH_D04="$GITEA_SH"
T="$(mktemp -d)"
trap 'stop_standin; rm -rf "$T"' EXIT

# gitea.sh loads ~/scripts/docker/{common.env,backup_lib.sh}: give it a HOME whose scripts/ is
# this checkout.
mkdir -p "$T/home" "$T/bin"
ln -s "$REPO" "$T/home/scripts"

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
PORT="$(free_port)"
DEAD_PORT="$(free_port)"   # nothing listens here: a Gitea whose local :3000 does not answer

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

# Gitea's DB for verify's cleanup-rule read: the tables and columns it reads, as d04's gitea.db
# has them (1.27.3, read 2026-11-04), with d04's three rules. User ids differ from rule ids so a
# wrong join shows. `sqlite_stub.py DB QUERY` prints rows as sqlite3's default list mode does.
cat > "$T/sqlite_stub.py" <<'PY'
import sqlite3, sys
try:
    con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    for row in con.execute(sys.argv[2]):
        print("|".join("" if v is None else str(v) for v in row))
except sqlite3.Error as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PY
make_db() {  # make_db [extra SQL]: d04's rules, then the extra SQL
  rm -f "$T/gitea.db"
  python3 - "$T/gitea.db" "${1:-}" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.executescript("""
create table user (id integer primary key, name text not null);
create table package_cleanup_rule (id integer primary key, enabled integer not null default 0,
  owner_id integer not null default 0, type text not null, keep_count integer not null default 0,
  keep_pattern text not null default '', remove_days integer not null default 0,
  remove_pattern text not null default '', match_full_name integer not null default 0,
  created_unix integer not null default 0, updated_unix integer not null default 0);
insert into user values (5, 'theOrg'), (7, 'asyla'), (9, 'personal'), (11, 'shepner');
insert into package_cleanup_rule (id, enabled, owner_id, type, keep_count, keep_pattern, remove_days, remove_pattern)
  values (1, 1, 5, 'container', 0, '', 7, ''), (2, 1, 7, 'container', 0, '', 7, ''), (3, 1, 9, 'container', 0, '', 7, '');
""" + sys.argv[2])
con.commit()
PY
}
make_db

# Gitea's app.ini for verify's cron check: [cron.cleanup_packages] as the README has it, after
# d04's one other cron section. make_ini [lines for the section] replaces the section's keys.
make_ini() {
  printf '[server]\nHTTP_PORT = 3000\n\n[cron.update_checker]\nENABLED = false\n\n[cron.cleanup_packages]\n%s\n' \
    "${1:-RUN_AT_START = false
SCHEDULE = 30 1 * * *}" > "$T/app.ini"
}
make_ini

# The stub: `docker compose ... up -d` starts the stand-in STANDIN_DELAY seconds later (never,
# when STANDIN_DELAY is "never"); `down` stops it. `docker exec -u git gitea sqlite3 ... QUERY`
# runs QUERY on the fixture DB, and refuses unless sqlite3 was given -readonly. Anything else is a
# no-op, except `inspect`, which prints STANDIN_STARTED (Gitea's start time) when it is set.
cat > "$T/bin/docker" <<STUB
#!/bin/bash
case " \$* " in
  *" inspect "*) [ -n "\${STANDIN_STARTED:-}" ] && echo "\$STANDIN_STARTED" ;;
  *" exec "*)
    case " \$* " in *" sqlite3 -readonly "*) ;; *) echo "stub: sqlite3 without -readonly" >&2; exit 1 ;; esac
    exec python3 "$T/sqlite_stub.py" "$T/gitea.db" "\${@: -1}" ;;
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

# run_gitea <wait seconds> <standin delay> <switch ...>: sets RC, OUT and TOOK. SH and LOCAL_PORT
# pick the copy under test and its local port (default: d04's, the stand-in's port).
run_gitea() {
  local wait_s="$1" delay="$2" t0=$SECONDS
  shift 2
  OUT="$(HOME="$T/home" PATH="$T/bin:$PATH" STANDIN_DELAY="$delay" \
    GITEA_VERIFY_WAIT_S="$wait_s" GITEA_LOCAL_URL="http://127.0.0.1:${LOCAL_PORT:-$PORT}" \
    GITEA_PUBLIC_URL="http://127.0.0.1:$PORT" GITEA_APP_INI="$T/app.ini" bash "${SH:-$GITEA_SH}" "$@" 2>&1)"
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

# 5. The public URL answers (as another host's Gitea could) but local :3000 does not. verify must
#    fail. (Its control, d03's copy passing in this state, left with that copy.)
run_gitea 0 0 up
sleep 1
SH="$GITEA_SH_D04" LOCAL_PORT="$DEAD_PORT" run_gitea 1 0 verify
check "d04 verify, local :3000 down, public up: fails" '[ "$RC" -eq 1 ] && grep -q "Local :3000 check failed" <<<"$OUT"'

# 6. d04's copy with both answering passes.
SH="$GITEA_SH_D04" run_gitea 1 0 verify
check "d04 verify, local and public up: passes" '[ "$RC" -eq 0 ] && grep -q "Local :3000 OK" <<<"$OUT"'

# 7. Cleanup rules and the cron section as on d04: verify prints each rule and the cron keys, and
#    does not warn.
run_gitea 1 0 verify
check "verify prints the three cleanup rules and the cron keys, no warning" \
  '[ "$RC" -eq 0 ] && grep -qF "1|theOrg|1|container|0|7|'"''|''"'" <<<"$OUT" && grep -qF "2|asyla|1|container|0|7|" <<<"$OUT" && grep -qF "3|personal|1|container|0|7|" <<<"$OUT" && grep -qF "Cleanup rules for theOrg, asyla, personal as in the README" <<<"$OUT" && grep -qF "[INFO] app.ini [cron.cleanup_packages]: RUN_AT_START = false, SCHEDULE = 30 1 * * * as in the README" <<<"$OUT" && ! grep -q "WARN" <<<"$OUT"'

# 8. Drift (control for 7): personal's rule off, asyla's at 30 days, theOrg's with a keep pattern,
#    and shepner's extra rule. verify warns naming the three owners, and still exits 0.
make_db "update package_cleanup_rule set enabled = 0 where id = 3;
  update package_cleanup_rule set remove_days = 30 where id = 2;
  update package_cleanup_rule set keep_pattern = '^v' where id = 1;
  insert into package_cleanup_rule (id, enabled, owner_id, type, keep_count, remove_days) values (4, 1, 11, 'container', 0, 7);"
run_gitea 1 0 verify
check "verify warns on cleanup-rule drift, exit 0" \
  '[ "$RC" -eq 0 ] && grep -qF "[WARN] No enabled container cleanup rule" <<<"$OUT" && grep -qE "for: theOrg asyla personal " <<<"$OUT" && grep -qF "4|shepner|1|container|0|7|" <<<"$OUT" && ! grep -q "Cleanup rules for .* as in the README" <<<"$OUT"'

# 9. One owner's rule missing: the warning names only that owner.
make_db "delete from package_cleanup_rule where id = 2;"
run_gitea 1 0 verify
check "verify warns for the owner with no rule only" \
  '[ "$RC" -eq 0 ] && grep -qE "for: asyla \(README" <<<"$OUT"'

# 10. The DB cannot be read (no Gitea DB yet, or the container is down): a warning, exit 0.
rm -f "$T/gitea.db"
run_gitea 1 0 verify
check "verify warns when the rules cannot be read, exit 0" \
  '[ "$RC" -eq 0 ] && grep -qF "[WARN] Could not read the package cleanup rules" <<<"$OUT"'
make_db

# 11. Cron drift (control for 7): SCHEDULE at Gitea's default and RUN_AT_START unset. verify warns
#     naming both keys and the fix, and still exits 0.
make_ini "SCHEDULE = @midnight"
run_gitea 1 0 verify
check "verify warns on cron drift, exit 0" \
  '[ "$RC" -eq 0 ] && grep -qF "[WARN] app.ini [cron.cleanup_packages] differs from the README" <<<"$OUT" && grep -qF "RUN_AT_START is unset (Gitea'"'"'s default true)" <<<"$OUT" && grep -qF "SCHEDULE is '"'"'@midnight'"'"'" <<<"$OUT" && grep -qF "gitea.sh cron-config sets it" <<<"$OUT" && grep -qF "Cleanup rules for theOrg, asyla, personal as in the README" <<<"$OUT"'

# 12. No app.ini (a host before Gitea's first start): a warning, exit 0.
rm -f "$T/app.ini"
run_gitea 1 0 verify
check "verify warns when app.ini cannot be read, exit 0" \
  '[ "$RC" -eq 0 ] && grep -qF "[WARN] Could not read $T/app.ini" <<<"$OUT"'

# 13. ENABLED = false with the two keys right: a warning that the job does not run, exit 0.
make_ini "ENABLED = false
RUN_AT_START = false
SCHEDULE = 30 1 * * *"
run_gitea 1 0 verify
check "verify warns when the cleanup job is off, exit 0" \
  '[ "$RC" -eq 0 ] && grep -qF "[WARN] app.ini [cron.cleanup_packages] ENABLED is '"'"'false'"'"'" <<<"$OUT"'

# 14. app.ini written after Gitea started: verify notes the running Gitea has the old schedule.
make_ini
STANDIN_STARTED="2026-01-01T00:00:00.123456789Z" run_gitea 1 0 verify
check "verify notes app.ini changed after Gitea started" \
  '[ "$RC" -eq 0 ] && grep -qF "[INFO] app.ini changed after Gitea started (2026-01-01T00:00:00Z)" <<<"$OUT" && ! grep -q "WARN" <<<"$OUT"'

# 15. Control for 14: Gitea started after app.ini was written, so no note.
STANDIN_STARTED="2099-01-01T00:00:00.000000000Z" run_gitea 1 0 verify
check "verify has no note when Gitea started after app.ini changed" \
  '[ "$RC" -eq 0 ] && grep -qF "SCHEDULE = 30 1 * * * as in the README" <<<"$OUT" && ! grep -q "changed after Gitea started" <<<"$OUT"'
stop_standin

if [ "$fails" -eq 0 ]; then
  echo "all cases passed"
else
  echo "$fails case(s) failed"
  exit 1
fi
