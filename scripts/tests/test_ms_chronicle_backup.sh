#!/bin/bash
# Offline test of d03/apps/ms-chronicle-backup/ms-chronicle-backup.sh (`backup` and `verify`).
# Touches no host, no NAS and no real ms-chronicle: the route is chronicle_backup_stub.py on a free
# loopback port, and the mirror is a directory in a temp dir. The script under test runs from a
# copy of this checkout's files whose common.env points DATA1 into that temp dir, so nothing here
# can reach /mnt/nas. Needs bash, curl and python3; runs on macOS and Linux. Run from anywhere:
#
#   scripts/tests/test_ms_chronicle_backup.sh
#
# test_ms_chronicle_backup_test01.sh runs this same file on test01. Exit 0 when every case passes.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/ms-chronicle-test.XXXXXX")"
STUB_PID=""
trap '[ -n "$STUB_PID" ] && { kill "$STUB_PID"; wait "$STUB_PID"; } 2>/dev/null; rm -rf "$T"' EXIT

# A stand-in bearer made for this run: no token is written in this file, and a value that exists
# nowhere else makes "the token appears in no output" a real check.
TOKEN="$(python3 -c 'import secrets; print("stub-" + secrets.token_hex(16))')"
APP_DIR="$T/home/scripts/d03/apps/ms-chronicle-backup"
APP="$APP_DIR/ms-chronicle-backup.sh"
MIRROR="$T/nas/data1/docker/ms-chronicle/mirror"
OUTSIDE="$T/outside"          # where a path in a snapshot name would land if it were used

mkdir -p "$T/home/scripts/docker" "$T/home/scripts/d03/apps" "$T/bin" "$T/tmp" "$T/nas/data1/docker"
cp -R "$REPO/d03/apps/ms-chronicle-backup" "$APP_DIR"
rm -f "$APP_DIR/.env"
cp "$REPO/docker/backup_lib.sh" "$T/home/scripts/docker/"
sed "s|^DATA1=.*|DATA1=$T/nas/data1|" "$REPO/docker/common.env" > "$T/home/scripts/docker/common.env"
grep -q "^DATA1=$T/nas/data1\$" "$T/home/scripts/docker/common.env" || { echo "could not repoint DATA1" >&2; exit 2; }

PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
URL="http://127.0.0.1:$PORT"

# curl, recorded: every argv the script gives curl goes to a file, so a case can show the token
# was never in it. Then the real curl runs.
REAL_CURL="$(command -v curl)"
cat > "$T/bin/curl" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >> "$T/curl.argv"
exec "$REAL_CURL" "\$@"
SHIM
chmod +x "$T/bin/curl"

stamp() {  # stamp <hours ago> -> a snapshot stamp, UTC
  python3 -c 'import datetime as d, sys; print((d.datetime.now(d.timezone.utc) - d.timedelta(hours=float(sys.argv[1]))).strftime("%Y%m%dT%H%M%SZ"))' "$1"
}
scenario() {  # scenario <stamp> <episodes> <observations|null> [fault]
  printf '{"stamp": "%s", "episodes": %s, "observations": %s, "fault": "%s"}\n' "$1" "$2" "$3" "${4:-}" > "$T/scenario.json"
}
write_env() {  # write_env <url> [token]
  printf 'MS_CHRONICLE_BACKUP_URL=%s\nMS_CHRONICLE_BACKUP_TOKEN=%s\n' "$1" "${2-$TOKEN}" > "$APP_DIR/.env"
}
run_app() {  # run_app <switch ...>: sets RC and OUT. Called as host-maintenance calls an app script.
  OUT="$(HOME="$T/home" PATH="$T/bin:$PATH" TMPDIR="$T/tmp" MAINT_FOREGROUND=1 bash "$APP" "$@" </dev/null 2>&1)"
  RC=$?
}
mirror_state() {  # every entry in the mirror with its checksum, dot files included
  ( cd "$MIRROR" 2>/dev/null && for f in $(ls -A | sort); do echo "$f $(cksum < "$f")"; done )
}
outside_state() {  # everything this test could see written outside the mirror
  ( cd "$T" && find home tmp nas outside -not -path "nas/data1/docker/ms-chronicle/mirror/*" 2>/dev/null | sort
    ls -A "$T" | sort )
}
partials() { ls -A "$MIRROR" 2>/dev/null | grep -c '\.partial$'; }
pairs() { ls -A "$MIRROR" | grep -E '^chronicle-[0-9]{8}T[0-9]{6}Z\.(tar\.gz|manifest\.json)$' | sort | tr '\n' ' '; }

fails=0
check() {  # check <name> <condition as a string>
  if eval "$2"; then
    echo "ok    $1 (exit $RC)"
  else
    echo "FAIL  $1 (exit $RC): expected $2"
    echo "$OUT" | sed 's/^/        /'
    fails=$((fails + 1))
  fi
}
# A pull that must fail: non-zero exit, the mirror byte for byte as before, no partials left.
check_refused() {  # check_refused <name> <text the output must hold>
  check "$1" '[ "$RC" -ne 0 ] && [ "$(mirror_state)" = "$BEFORE" ] && [ "$(partials)" -eq 0 ] && grep -q "'"$2"'" <<<"$OUT"'
}

STUB_TOKEN="$TOKEN" python3 "$REPO/scripts/tests/chronicle_backup_stub.py" "$PORT" "$T/scenario.json" "$T/requests.log" &
STUB_PID=$!
S1="$(stamp 30)"; S2="$(stamp 3)"; S3="$(stamp 1)"
scenario "$S1" 5 2
for _ in 1 2 3 4 5 6 7 8 9 10; do "$REAL_CURL" -s -o /dev/null "$URL/" && break; sleep 0.5; done
: > "$T/requests.log"     # the line above is this test's own request

# ---- before anything is set up -------------------------------------------------------------
run_app verify
check "verify with no .env: names the missing token" '[ "$RC" -ne 0 ] && grep -q "MS_CHRONICLE_BACKUP_TOKEN is not set" <<<"$OUT"'
run_app backup
check "backup with no .env: refused, no request made" '[ "$RC" -ne 0 ] && [ ! -s "$T/requests.log" ] && [ ! -e "$T/nas/data1/docker/ms-chronicle" ]'

write_env "$URL"
run_app backup
check "backup with no mirror directory: refused, directory not created, no request made" \
  '[ "$RC" -ne 0 ] && grep -q "does not exist" <<<"$OUT" && [ ! -e "$T/nas/data1/docker/ms-chronicle" ] && [ ! -s "$T/requests.log" ]'
run_app verify
check "verify with no mirror directory: fails, directory not created" '[ "$RC" -ne 0 ] && [ ! -e "$T/nas/data1/docker/ms-chronicle" ]'

write_env "http://192.0.2.1:9"
run_app backup
check "a URL that is not https: refused before the token is sent" '[ "$RC" -ne 0 ] && grep -q "must be https" <<<"$OUT"'
write_env "$URL" "'bad\"token'"
run_app backup
check "a token with a quote in it: refused" '[ "$RC" -ne 0 ] && grep -q "no bearer token has" <<<"$OUT"'
write_env "$URL"

# ---- the first pull ------------------------------------------------------------------------
mkdir -p "$MIRROR"       # on d03 this is the operator-approved one-time step; the script never does it
: > "$T/curl.argv"
BEFORE_OUTSIDE="$(outside_state)"
run_app backup
check "first pull: one verified pair, no partials" \
  '[ "$RC" -eq 0 ] && [ "$(pairs)" = "chronicle-$S1.manifest.json chronicle-$S1.tar.gz " ] && [ "$(partials)" -eq 0 ] && grep -q "ok chronicle-$S1 files=8 episodes=5 observations=2" <<<"$OUT"'
check "first pull: nothing created outside the mirror" '[ "$(outside_state)" = "$BEFORE_OUTSIDE" ]'
check "first pull: the token was never in curl's argv (and curl was called)" '[ -s "$T/curl.argv" ] && ! grep -q "$TOKEN" "$T/curl.argv"'
check "first pull: the manifest was asked for by the tarball's name" 'grep -q "GET /api/v1/backup/manifest?snapshot=chronicle-$S1 bearer=ok" "$T/requests.log"'
RC=0; OUT="$(python3 "$APP_DIR/verify-pull.py" "$MIRROR/chronicle-$S1.tar.gz" "$MIRROR/chronicle-$S1.manifest.json" /dev/null 2>&1)" || RC=$?
check "control: the contract's check does fail without the sender's headers" '[ "$RC" -ne 0 ] && grep -q "FAILED" <<<"$OUT"'

: > "$T/requests.log"
STATE="$(mirror_state)"
run_app verify
check "verify after a pull: passes, asks for no tarball with the token, writes nothing" \
  '[ "$RC" -eq 0 ] && grep -q "refuses no token (401)" <<<"$OUT" && grep -q "takes this token" <<<"$OUT" && grep -q "newest copy: chronicle-$S1 episodes=5 observations=2" <<<"$OUT" && ! grep -q "GET /api/v1/backup bearer=ok" "$T/requests.log" && [ "$(mirror_state)" = "$STATE" ]'

run_app backup
check "the same snapshot again: still one pair, exit 0" '[ "$RC" -eq 0 ] && [ "$(pairs)" = "chronicle-$S1.manifest.json chronicle-$S1.tar.gz " ] && grep -q "(same," <<<"$OUT"'

# ---- a newer snapshot: published, the older pair pruned, nothing else touched -----------------
echo "not ours" > "$MIRROR/notes.txt"
echo "not ours" > "$MIRROR/chronicle-old.tar.gz"
echo "not ours" > "$MIRROR/other-20200101T000000Z.tar.gz"
echo "not ours" > "$MIRROR/chronicle-20200101T000000Z.tar.gz.bak"
echo "OK earlier" > "$MIRROR/.backup-status"
scenario "$S2" 7 3
run_app backup
check "a newer snapshot: its pair replaces the older one" '[ "$RC" -eq 0 ] && [ "$(pairs)" = "chronicle-$S2.manifest.json chronicle-$S2.tar.gz " ] && grep -q "pruned 2 file" <<<"$OUT"'
check "pruning left every other file alone" \
  '[ "$(ls -A "$MIRROR" | grep -v "^chronicle-$S2\\." | LC_ALL=C sort | tr "\n" " ")" = ".backup-status chronicle-20200101T000000Z.tar.gz.bak chronicle-old.tar.gz notes.txt other-20200101T000000Z.tar.gz " ] && [ "$(cat "$MIRROR/notes.txt" "$MIRROR/chronicle-old.tar.gz")" = "not ours
not ours" ]'

# ---- pulls that must fail and leave the mirror as it was ---------------------------------------
BEFORE="$(mirror_state)"
scenario "$S3" 9 4 corrupt_body;        run_app backup; check_refused "a tarball that is not what the sender said" "sha256"
scenario "$S3" 9 4 truncated;           run_app backup; check_refused "a download cut short" "download from"
scenario "$S3" 9 4 wrong_manifest;      run_app backup; check_refused "another snapshot's manifest" "snapshot name"
scenario "$S3" 9 4 manifest_error;      run_app backup; check_refused "the manifest request answers 500" "HTTP 500"
scenario "$S3" 9 4 created_header;      run_app backup; check_refused "a created header that is not the manifest's" "created"
scenario "$S3" 9 4 volume_unavailable;  run_app backup; check_refused "503 volume_unavailable" "HTTP 503"
scenario "$S3" 9 4 no_snapshot;         run_app backup; check_refused "404 no_snapshot" "HTTP 404"
scenario "$S3" 9 4 misconfigured;       run_app backup; check_refused "503 misconfigured" "HTTP 503"
scenario "$S3" 9 4 bad_name;            run_app backup; check_refused "a snapshot name that is a path" "not a snapshot name"
check "the path in that name was not used" '[ ! -e "$OUTSIDE" ] && [ ! -e "$T/nas/data1/docker/outside" ] && [ ! -e "$T/nas/data1/outside.tar.gz" ]'
scenario "$S3" 6 4;                     run_app backup; check_refused "fewer episodes than the held copy" "episodes"
scenario "$S3" 9 1;                     run_app backup; check_refused "fewer observations than the held copy" "observations"
scenario "$S3" 9 null;                  run_app backup; check_refused "a schema 1 snapshot after one that covers observations" "does not cover observations"
scenario "$(stamp 10)" 9 4;             run_app backup; check_refused "a snapshot older than the held copy" "older than the held copy"
write_env "$URL" "wrong-token-not-a-secret"
scenario "$S3" 9 4;                     run_app backup; check_refused "401 with a wrong token" "HTTP 401"
run_app verify
check "verify with a wrong token fails" '[ "$RC" -ne 0 ] && grep -q "answered 401" <<<"$OUT"'
write_env "$URL"

# A snapshot older than two days, into an empty mirror: the Mini's backup has stopped.
mv "$MIRROR" "$MIRROR.kept"; mkdir "$MIRROR"; BEFORE=""
scenario "$(stamp 72)" 9 4;             run_app backup; check_refused "a newest snapshot three days old" "backup has stopped"
scenario "$S3" 4 null;                  run_app backup
check "a schema 1 snapshot into an empty mirror: accepted, observations not covered" '[ "$RC" -eq 0 ] && grep -q "observations=not-covered" <<<"$OUT"'
rm -rf "$MIRROR"; mv "$MIRROR.kept" "$MIRROR"; BEFORE="$(mirror_state)"

# ---- a pull in flight, and one that died -----------------------------------------------------
: > "$MIRROR/.download.partial"
: > "$T/requests.log"
scenario "$S3" 9 4
run_app backup
check "fresh partials: another pull is in flight, refused, its partial left alone, no request" \
  '[ "$RC" -ne 0 ] && grep -q "in flight" <<<"$OUT" && [ -e "$MIRROR/.download.partial" ] && [ ! -s "$T/requests.log" ]'
python3 -c 'import os, sys, time; os.utime(sys.argv[1], (time.time() - 8000,) * 2)' "$MIRROR/.download.partial"
echo "left behind" > "$MIRROR/.headers.partial"
python3 -c 'import os, sys, time; os.utime(sys.argv[1], (time.time() - 8000,) * 2)' "$MIRROR/.headers.partial"
run_app backup
check "partials two hours old: removed, and the pull goes ahead" \
  '[ "$RC" -eq 0 ] && grep -q "left by a pull that died" <<<"$OUT" && [ "$(partials)" -eq 0 ] && [ "$(pairs)" = "chronicle-$S3.manifest.json chronicle-$S3.tar.gz " ]'

# ---- the mirror afterwards is a backup the contract's own check accepts ----------------------
run_app verify
check "verify at the end" '[ "$RC" -eq 0 ] && grep -q "newest copy: chronicle-$S3 episodes=9 observations=4" <<<"$OUT"'
printf 'x' >> "$MIRROR/chronicle-$S3.tar.gz"
run_app verify
check "control: verify fails once the held tarball is not what its manifest recorded" '[ "$RC" -ne 0 ] && grep -q "does not check out" <<<"$OUT"'
check "the token is in no output and no file but .env" '! grep -rq "$TOKEN" "$T/requests.log" "$T/curl.argv" "$MIRROR" "$T/tmp"'

if [ "$fails" -eq 0 ]; then
  echo "all cases passed"
else
  echo "$fails case(s) failed"
  exit 1
fi
