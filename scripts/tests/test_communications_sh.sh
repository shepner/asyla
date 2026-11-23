#!/bin/bash
# d06/apps/communications/communications.sh `up` against stubs (docker, stat): the refusal without
# the start values, the NATS users.conf (names and $NATS_PW_<i> references only), each password
# pre-quoted as a NATS string in nats's environment and named (not valued) in the generated
# override, the mq-user pairs and their refusals (a `#` or `/` in a name; a webhook-mq value that
# is not URL-safe, refused by `up` and by `restart` before its down), nats recreated only when
# users.conf changed while it ran, the start order, vector left out when observability's
# network is missing, and webhook-to-mq-vikunja kept off ticketing's network (with a warning) when
# that is missing. Then `import PATH` (C4 P2) against a real rsync: a good backup, as a directory
# and as a tar, mirrored owner-only and never restored; a bad STATUS, a bad sha256, no
# public.messages and a symlink member refused; an existing mirror refused unless IMPORT_FORCE=1.
# Then import_from_host.sh's argument handling and its ssh calls, against an ssh stub. Last, the
# mail relay (asyla #657): started last with no --wait, its compose service (no token, no TLS or
# key mount, 2587 on 10.0.0.65 only, 9117 never published), the root pin agreeing three ways,
# relay-status's word for stubbed docker output, relay-arm's stdin reaching arm.py as uid 10002,
# verify's relay check, and a bad root stopping up and restart before compose.
# Nothing here reaches a registry, the vault or a host; every value is a random stand-in made at run time.
# Run: bash scripts/tests/test_communications_sh.sh
# COMMUNICATIONS_SH=PATH tests another copy of communications.sh (a mutated one, to see cases fail).
# The $NATS_PW_<i> and $ in single quotes below are literal on purpose (what users.conf and nats hold).
# shellcheck disable=SC2016
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }

mkdir -p "$T/home/scripts/docker" "$T/bin" "$T/app" "$T/dl" "$T/d1"
cp "$REPO/docker/backup_lib.sh" "$T/home/scripts/docker/"
printf 'DOCKER_DL=%s\nDOCKER_D1=%s\n' "$T/dl" "$T/d1" > "$T/home/scripts/docker/common.env"
cp "$REPO"/d06/apps/communications/{compose.yml,compose.no-ticketing.yml,docker-credential-communications-env,theorg-v2-root.crt} "$T/app/"
cp "${COMMUNICATIONS_SH:-$REPO/d06/apps/communications/communications.sh}" "$T/app/communications.sh"
USERS="$T/dl/Communications/nats-runtime/users.conf"

# The bash the cases run (env -i PATH below has none in $T/bin). backup_lib's _backup_lock needs
# bash 4.1 (exec {fd}>) and flock; macOS has bash 3.2 and no flock, so there it is a no-op.
TBASH="$(PATH=/usr/bin:/bin command -v bash)"
bv="$("$TBASH" -c 'echo $((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1]))')"
if [ "$bv" -lt 401 ] || ! PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v flock >/dev/null; then
  printf '\n# test only: no flock or bash < 4.1 here\n_backup_lock() { :; }\n' >> "$T/home/scripts/docker/backup_lib.sh"
fi

# docker: logs each call (paths shortened). A compose call given a second -f logs that file's
# lines (the generated override) and the NATS_PW_<i> it would hand nats. `ps -q ... nats` prints
# an id when STUB_RUNNING; `network inspect` fails for ticketing_net when STUB_NO_TICKETING and
# for any other network when STUB_NO_OBS; images are all present.
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" | sed -E "s#-f [^ ]*/compose.yml#-f compose.yml#; s#-f [^ ]*/nats-users.override.yml#-f OVERRIDE#; s#-f [^ ]*/compose.no-ticketing.yml#-f NO_TICKETING#; s# --project-directory [^ ]*##" >> "$STUB_LOG"
if [ "$1" = compose ]; then
  prev=""
  for a in "$@"; do
    case "$prev:$a" in -f:*override.yml) sed 's/^/OVR /' "$a" >> "$STUB_LOG"
      for n in $(compgen -e | grep '^NATS_PW_' | sort); do echo "ENV $n=${!n}" >> "$STUB_LOG"; done ;; esac
    prev="$a"
  done
fi
case "$*" in
  *"config --images"*) echo "img:1" ;;
  "image inspect"*) exit 0 ;;
  "network inspect ticketing_net"*) [ -z "${STUB_NO_TICKETING:-}" ] ;;
  "network inspect"*) [ -z "${STUB_NO_OBS:-}" ] ;;
  *"ps -q --status running nats"*) if [ -n "${STUB_RUNNING:-}" ]; then echo abc; fi ;;
  # The mail relay: STUB_RELAY_IDS (space-separated) are its containers, STUB_RELAY_STATE and
  # STUB_RELAY_HEALTH its State, STUB_RELAY_LOGS a file of its log (on stderr, as python logs).
  # arm.py keeps its stdin in STUB_ARM_STDIN, says STUB_ARM_SAYS and exits STUB_ARM_RC.
  "ps -aq --filter label=com.docker.compose.project=communications --filter label=com.docker.compose.service=mail-relay")
    for i in ${STUB_RELAY_IDS:-}; do echo "$i"; done ;;
  "inspect -f {{.State.Status}} {{.State.StartedAt}} "*) echo "${STUB_RELAY_STATE:-running} 2026-01-01T00:00:00.000000000Z" ;;
  "inspect -f {{if .State.Health}}{{.State.Health.Status}}{{end}} "*) echo "${STUB_RELAY_HEALTH:-}" ;;
  "logs --since 2026-01-01T00:00:00.000000000Z "*) if [ -n "${STUB_RELAY_LOGS:-}" ]; then cat "$STUB_RELAY_LOGS" >&2; fi ;;
  "exec -i -u 10002 "*" python3 /app/arm.py") cat > "$STUB_ARM_STDIN"; echo "${STUB_ARM_SAYS:-ok}"; exit "${STUB_ARM_RC:-0}" ;;
  "exec "*" python3 /app/smoke.py probe --tls-name mail-relay.asyla.org") exit "${STUB_PROBE_RC:-0}" ;;
esac
EOF
# stat: backup/ already has the image's owner and mode, so ensure_dirs needs no sudo.
cat > "$T/bin/stat" <<'EOF'
#!/bin/bash
echo "999 999 700"
EOF
# sudo: logged, then run as this user (-n dropped). date: -Is (backup_lib's status lines) is
# GNU only, so a fixed stand-in; anything else goes to the real date.
cat > "$T/bin/sudo" <<'EOF'
#!/bin/bash
echo "sudo $*" >> "${STUB_LOG:-/dev/null}"
if [ "${1:-}" = -n ]; then shift; fi
exec "$@"
EOF
cat > "$T/bin/date" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -Is ]; then echo "2026-01-01T00:00:00+00:00"; exit 0; fi
exec env PATH=/usr/bin:/bin date "$@"
EOF
# ssh (import_from_host.sh only): logs its arguments; the source host's tar prints stand-in bytes,
# d06's `cat >` keeps its stdin in $T/received, d06's import exits STUB_IMPORT_RC.
cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
echo "ssh $*" >> "$STUB_LOG"
case "$*" in
  *"tar --no-xattrs -cf -"*|*"tar -C /b -cf -"*) echo "$STUB_TAR_BYTES" ;;
  *"cat > "*) cat > "$STUB_RECEIVED" ;;
  *" import "*) exit "${STUB_IMPORT_RC:-0}" ;;
esac
EOF
chmod +x "$T/bin/docker" "$T/bin/stat" "$T/bin/sudo" "$T/bin/date" "$T/bin/ssh"

# Runs `communications.sh ${CS_CMD:-up}` in a clean environment plus the NAME=value words given;
# sets OUT and LOG, returns its exit code.
# Stand-in values, fresh each run: hex, so URL-safe as the vault's generated values are.
fresh() { python3 -c 'import secrets; print(secrets.token_hex(10))'; }
V_PG="$(fresh)"; V_MQ="$(fresh)"; V_CHAT="$(fresh)"; V_HOOK="$(fresh)"; V_QA="$(fresh)"
V_PERCENT="$(fresh)%$(fresh)"; V_DOLLAR="$(fresh)\$$(fresh)"
START5=(COMMS_POSTGRES_PASSWORD="$V_PG" COMMS_NATS_WEBHOOK_MQ_USERNAME=webhook-mq
  COMMS_NATS_WEBHOOK_MQ_PASSWORD="$V_MQ" COMMS_CHAT_API_TOKEN="$V_CHAT" COMMS_VIKUNJA_WEBHOOK_SECRET="$V_HOOK")
run_up() {
  local rc
  : > "$T/log"
  OUT="$(env -i PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T/home" STUB_LOG="$T/log" "$@" \
    bash "$T/app/communications.sh" "${CS_CMD:-up}" 2>&1)"
  rc=$?
  LOG="$(cat "$T/log")"
  return "$rc"
}
has() { grep -qF -- "$2" <<< "$1"; }

# 1. No start values: refused before any compose call.
if run_up; then bad "up without the start values is refused"; else
  if has "$OUT" "COMMS_POSTGRES_PASSWORD" && ! has "$LOG" "compose"; then ok "up without the start values is refused before compose"
  else bad "up without the start values is refused before compose" "$OUT"; fi
fi

# 2. The five values: users.conf holds a reference only; nats gets the quoted value by name.
if run_up "${START5[@]}"; then
  if grep -qF '{ user: "webhook-mq", password: $NATS_PW_0 }' "$USERS" && ! grep -qF "$V_MQ" "$USERS"; then
    ok "users.conf names webhook-mq with \$NATS_PW_0 and holds no password"
  else bad "users.conf names webhook-mq with \$NATS_PW_0 and holds no password" "$(cat "$USERS")"; fi
  if has "$LOG" "ENV NATS_PW_0=\"$V_MQ\"" && has "$LOG" "OVR       - NATS_PW_0" && ! grep -q "^OVR .*$V_MQ" <<< "$LOG"; then
    ok "the override names NATS_PW_0 only; nats gets the value pre-quoted"
  else bad "the override names NATS_PW_0 only; nats gets the value pre-quoted" "$LOG"; fi
  order="$(grep -oE 'up -d (--wait --wait-timeout [0-9]+ )?(--force-recreate )?[a-z-]+$' <<< "$LOG" | awk '{print $NF}' | tr '\n' ' ')"
  if [ "$order" = "nats nats-exporter comms-postgres chat-api webhook-to-mq-vikunja vector mail-relay " ]; then
    ok "start order: nats, exporter, postgres, chat-api, webhook-to-mq, vector, mail-relay"
  else bad "start order" "$order"; fi
  if has "$OUT" "users.conf changed"; then ok "first up writes users.conf"; else bad "first up writes users.conf" "$OUT"; fi
else bad "up with the five values starts" "$OUT"; fi

# 3. Same values again while nats runs: users.conf unchanged, nats not recreated.
if run_up "${START5[@]}" STUB_RUNNING=1 && has "$OUT" "users.conf unchanged" && ! has "$LOG" "--force-recreate"; then
  ok "unchanged users.conf: nats is not recreated"
else bad "unchanged users.conf: nats is not recreated" "$OUT"; fi

# 4. An mq-user password with \ " $ in it: quoted as a NATS string (\ doubled, " escaped), $ kept.
if run_up "${START5[@]}" COMMS_MQ_USER_QA_USERNAME=staff-qa 'COMMS_MQ_USER_QA_PASSWORD=a$b\c"d' \
    && has "$LOG" 'ENV NATS_PW_1="a$b\\c\"d"'; then
  ok "a value with \\, \" and \$ is pre-quoted for nats"
else bad "a value with \\, \" and \$ is pre-quoted for nats" "$(grep '^ENV' <<< "$LOG")"; fi
run_up "${START5[@]}" >/dev/null || bad "back to webhook-mq alone" "$OUT"

# 5. An mq-user pair added while nats runs: two users, sorted after webhook-mq; nats recreated.
if run_up "${START5[@]}" STUB_RUNNING=1 COMMS_MQ_USER_QA_USERNAME=staff-qa COMMS_MQ_USER_QA_PASSWORD="$V_QA"; then
  if grep -qF '{ user: "staff-qa", password: $NATS_PW_1 }' "$USERS" && has "$LOG" "ENV NATS_PW_1=\"$V_QA\"" \
      && has "$LOG" "--force-recreate nats"; then
    ok "an mq-user pair becomes NATS_PW_1; nats is recreated because users.conf changed while it ran"
  else bad "an mq-user pair becomes NATS_PW_1; nats is recreated" "$OUT"; fi
else bad "up with an mq-user pair starts" "$OUT"; fi

# 6. Refusals: a half pair, a repeated name, an empty mq password. users.conf is left as it was.
before="$(cat "$USERS")"
for c in "COMMS_MQ_USER_QA_USERNAME=staff-qa|a half pair" \
         "COMMS_MQ_USER_QA_USERNAME=webhook-mq COMMS_MQ_USER_QA_PASSWORD=$V_QA|a repeated user name" \
         "COMMS_MQ_USER_QA_USERNAME=staff-qa COMMS_MQ_USER_QA_PASSWORD=|an empty password" \
         "COMMS_MQ_USER_QA_USERNAME=staff#qa COMMS_MQ_USER_QA_PASSWORD=$V_QA|a # in a user name" \
         "COMMS_MQ_USER_QA_USERNAME=staff/qa COMMS_MQ_USER_QA_PASSWORD=$V_QA|a / in a user name" \
         "COMMS_NATS_WEBHOOK_MQ_PASSWORD=$V_PERCENT|a webhook-mq password that is not URL-safe" \
         "COMMS_NATS_WEBHOOK_MQ_USERNAME=webhook.mq|a webhook-mq user name that is not URL-safe"; do
  # shellcheck disable=SC2086  # the case's NAME=value words, split on purpose
  if run_up "${START5[@]}" ${c%%|*}; then bad "${c##*|} is refused"
  elif has "$LOG" "up -d"; then bad "${c##*|} is refused before any start" "$LOG"
  elif [ "$(cat "$USERS")" != "$before" ]; then bad "${c##*|} leaves users.conf as it was"
  else ok "${c##*|} is refused before any start; users.conf unchanged"; fi
done

# 6b. restart with a webhook-mq password that is not URL-safe: refused before its down.
if CS_CMD=restart run_up "${START5[@]}" "COMMS_NATS_WEBHOOK_MQ_PASSWORD=$V_DOLLAR"; then bad "restart with a non-URL-safe webhook-mq password is refused"
elif has "$LOG" "compose" || ! has "$OUT" "outside A-Z a-z 0-9 _ -"; then
  bad "restart with a non-URL-safe webhook-mq password is refused before any compose call" "$LOG"
else ok "restart with a non-URL-safe webhook-mq password is refused before its down"; fi

# 7. No observability network: vector is not started, the rest is, and up says so.
if run_up "${START5[@]}" STUB_NO_OBS=1 && ! has "$LOG" "up -d vector" && has "$LOG" "webhook-to-mq-vikunja" \
    && has "$OUT" "vector not started"; then
  ok "no observability network: vector is left out with a warning"
else bad "no observability network: vector is left out with a warning" "$OUT"; fi

# 8. ticketing's network present: webhook-to-mq-vikunja starts from compose.yml alone (both networks).
if run_up "${START5[@]}" && ! has "$OUT" "does not exist" && ! has "$LOG" "NO_TICKETING" \
    && grep -qE 'up -d --wait --wait-timeout [0-9]+ webhook-to-mq-vikunja$' <<< "$LOG"; then
  ok "ticketing network present: webhook-to-mq-vikunja starts with no override and no warning"
else bad "ticketing network present: webhook-to-mq-vikunja starts with no override and no warning" "$OUT"; fi

# 9. No ticketing network: a warning, the override on webhook-to-mq-vikunja's start (not before),
# vector still started; the override puts it on communications_net alone.
if run_up "${START5[@]}" STUB_NO_TICKETING=1; then
  hook="$(grep -E 'webhook-to-mq-vikunja$' <<< "$LOG")"
  chat="$(grep -E ' chat-api$' <<< "$LOG")"
  if has "$OUT" "[WARN] network ticketing_net does not exist" && has "$hook" "-f NO_TICKETING" \
      && ! has "$chat" "NO_TICKETING" && has "$LOG" "up -d vector" \
      && grep -qF 'networks: !override [communications_net]' "$T/app/compose.no-ticketing.yml"; then
    ok "no ticketing network: webhook-to-mq-vikunja starts on communications_net only, with a warning"
  else bad "no ticketing network: webhook-to-mq-vikunja starts on communications_net only, with a warning" "$OUT
$LOG"; fi
else bad "up without the ticketing network still starts" "$OUT"; fi

# --- import (C4 P2) ---------------------------------------------------------------------------
# communications.sh with NAME=value words up to --, then its arguments; sets OUT and LOG.
run_cs() {
  local envs=() rc
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$T/log"
  OUT="$(env -i PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T/home" STUB_LOG="$T/log" \
    ${envs[@]+"${envs[@]}"} bash "$T/app/communications.sh" "$@" 2>&1)"
  rc=$?
  LOG="$(cat "$T/log")"
  return "$rc"
}
sha() { if command -v sha256sum >/dev/null; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi | cut -d' ' -f1; }
write_manifest() { printf '%s  comms.dump\n%s  tables.tsv\n' "$(sha "$1/comms.dump")" "$(sha "$1/tables.tsv")" > "$1/manifest.sha256"; }
# A backup as theOrg's writes it: STATUS "OK <time>", tables.tsv, manifest.sha256 (sha256sum -c).
make_backup() {
  rm -rf "$1"; mkdir -p "$1"
  printf 'OK %s\n' "$2" > "$1/STATUS"
  fresh > "$1/comms.dump"
  printf 'public\tmessages\t%s\n' "$3" > "$1/tables.tsv"
  write_manifest "$1"
}
to_tar() { (cd "$1" && COPYFILE_DISABLE=1 tar -cf "$2" STATUS comms.dump tables.tsv manifest.sha256); }
mode() { ls -ld "$1" | cut -c1-10; }
SRC="$T/src"
MIRROR="$T/d1/Communications/mirror"
IMPDIR="$T/dl/Communications/import"
rows=$((RANDOM % 900 + 1))

# 10. A good backup, as a directory: mirrored as is, owner-only, OK; no container; work dir gone.
make_backup "$SRC" "2026-01-02T00:00:00Z" "$rows"
if run_cs -- import "$SRC"; then
  if cmp -s "$SRC/comms.dump" "$MIRROR/comms.dump" && cmp -s "$SRC/STATUS" "$MIRROR/STATUS" \
      && cmp -s "$SRC/manifest.sha256" "$MIRROR/manifest.sha256" && grep -q '^OK ' "$MIRROR/.backup-status" \
      && [ "$(mode "$MIRROR/comms.dump")" = "-rw-------" ] && [ "$(mode "$IMPDIR")" = "drwx------" ] \
      && has "$OUT" "public.messages $rows rows" && ! has "$LOG" "docker" && [ -z "$(ls -A "$IMPDIR")" ]; then
    ok "import: a good backup directory is mirrored owner-only, OK, with no container and no work dir left"
  else bad "import: a good backup directory is mirrored owner-only, OK" "$OUT
$LOG"; fi
else bad "import: a good backup directory is accepted" "$OUT"; fi

# 11. A mirror already there: refused without IMPORT_FORCE=1, mirror untouched (a tar this time).
make_backup "$SRC" "2026-01-03T00:00:00Z" "$rows"
# Same sizes as case 10's, made in the same second: another mtime, or rsync's quick check skips them.
touch -t 202601030000 "$SRC"/*
to_tar "$SRC" "$T/b.tar"
before="$(cat "$MIRROR/STATUS")"
if run_cs -- import "$T/b.tar"; then bad "import over an existing mirror is refused without IMPORT_FORCE=1"
elif has "$OUT" "already holds a backup" && [ "$(cat "$MIRROR/STATUS")" = "$before" ]; then
  ok "import over an existing mirror is refused without IMPORT_FORCE=1; the mirror is untouched"
else bad "import over an existing mirror is refused; the mirror is untouched" "$OUT"; fi

# 12. IMPORT_FORCE=1: the tar replaces it, with a warning; still no restore (no docker call at all).
if run_cs IMPORT_FORCE=1 -- import "$T/b.tar" && cmp -s "$SRC/STATUS" "$MIRROR/STATUS" \
    && cmp -s "$SRC/comms.dump" "$MIRROR/comms.dump" && has "$OUT" "IMPORT_FORCE=1: replacing" \
    && has "$OUT" "not restored" && ! has "$LOG" "docker" && [ -z "$(ls -A "$IMPDIR")" ]; then
  ok "import IMPORT_FORCE=1: a good tar replaces the mirror; nothing is restored"
else bad "import IMPORT_FORCE=1: a good tar replaces the mirror; nothing is restored" "$OUT
$LOG"; fi

# 13. Refused copies, into no mirror: the mirror is never created and no work dir is left.
rm -rf "$MIRROR"
for c in status sha tables symlink; do
  make_backup "$SRC" "2026-01-04T00:00:00Z" "$rows"
  arg="$SRC"
  case "$c" in
    status) printf 'FAILED %s\n' "2026-01-04T00:00:00Z" > "$SRC/STATUS"; want="STATUS does not start"; what="a STATUS that is not OK" ;;
    sha) fresh >> "$SRC/comms.dump"; want="sha256 mismatch: comms.dump"; what="a sha256 mismatch" ;;
    tables) printf 'public\tother\t%s\n' "$rows" > "$SRC/tables.tsv"; write_manifest "$SRC"
      want="does not name public.messages"; what="a tables.tsv without public.messages" ;;
    symlink) cp "$SRC/STATUS" "$T/outside"; chmod 0644 "$T/outside"; rm "$SRC/STATUS"; ln -s "$T/outside" "$SRC/STATUS"
      to_tar "$SRC" "$T/sym.tar"; arg="$T/sym.tar"; want="STATUS in $T/sym.tar is not a regular file"; what="a tar whose STATUS is a symlink" ;;
  esac
  if run_cs -- import "$arg"; then bad "import refuses $what"
  elif has "$OUT" "$want" && [ ! -e "$MIRROR" ] && [ -z "$(ls -A "$IMPDIR")" ] && ! has "$LOG" "docker"; then
    ok "import refuses $what; no mirror written"
  else bad "import refuses $what; no mirror written" "$OUT"; fi
done
if [ "$(mode "$T/outside")" = "-rw-r--r--" ]; then ok "import's chmod never follows a symlink member"
else bad "import's chmod never follows a symlink member" "$(mode "$T/outside")"; fi

# 14. import stands alone: no path, or another switch after it, is usage.
if run_cs -- import; then bad "import without a path is refused"
elif run_cs -- import "$SRC" up; then bad "import with another switch is refused"
elif ! has "$OUT" "import PATH" || has "$LOG" "docker"; then bad "import with a wrong argument count prints usage only" "$OUT"
else ok "import without a path, or with another switch, prints usage and does nothing"; fi

# --- import_from_host.sh ----------------------------------------------------------------------
HELPER="$REPO/d06/apps/communications/import_from_host.sh"
TAR_BYTES="$(fresh)"
run_helper() {
  local envs=() rc
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$T/log"; rm -f "$T/received"
  OUT="$(env -i PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T/home" STUB_LOG="$T/log" \
    STUB_RECEIVED="$T/received" STUB_TAR_BYTES="$TAR_BYTES" ${envs[@]+"${envs[@]}"} bash "$HELPER" "$@" 2>&1)"
  rc=$?
  LOG="$(cat "$T/log")"
  return "$rc"
}

# 15. Arguments: none, two, relative, '..', a space, a quote, a ;, and IMPORT_FORCE not 0 or 1:
# each refused before any ssh.
refused=0
run_helper -- && refused=1; has "$LOG" "ssh" && refused=1
run_helper -- /a /b && refused=1; has "$LOG" "ssh" && refused=1
for a in "rel/path" "/x/../y" "/x y" "/x'y" "/x;y"; do
  run_helper -- "$a" && refused=1; has "$LOG" "ssh" && refused=1
done
run_helper IMPORT_FORCE=2 -- /x/backup && refused=1; has "$LOG" "ssh" && refused=1
if [ "$refused" = 0 ]; then ok "import_from_host.sh refuses a wrong argument count, an unsafe MINI_PATH and a bad IMPORT_FORCE before any ssh"
else bad "import_from_host.sh refuses bad arguments before any ssh" "$OUT"; fi

# 16. A good path: the Mini's tar, streamed into d06's import dir, imported, then removed.
if run_helper -- /Users/x/comms-backup; then
  # The pipe's two ssh calls start together, so lines 1 and 2 come in either order.
  l12="$(sed -n 1,2p <<< "$LOG")"; l3="$(sed -n 3p <<< "$LOG")"; l4="$(sed -n 4p <<< "$LOG")"
  l1="$(grep -F 10.0.0.150 <<< "$l12")"; l2="$(grep -F docker@d06 <<< "$l12")"
  if has "$l1" "ssh -o BatchMode=yes 10.0.0.150 cd '/Users/x/comms-backup' && COPYFILE_DISABLE=1 tar --no-xattrs -cf - STATUS comms.dump tables.tsv manifest.sha256" \
      && has "$l2" "ssh -o BatchMode=yes docker@d06 umask 077 && mkdir -p '/mnt/docker/Communications/import' && cat > '/mnt/docker/Communications/import/mini-" \
      && has "$l3" "IMPORT_FORCE=0 ~/scripts/d06/apps/communications/communications.sh import '/mnt/docker/Communications/import/mini-" \
      && has "$l4" "docker@d06 rm -f '/mnt/docker/Communications/import/mini-" \
      && [ "$(cat "$T/received")" = "$TAR_BYTES" ]; then
    ok "import_from_host.sh streams the tar to d06, imports it and removes it"
  else bad "import_from_host.sh streams the tar to d06, imports it and removes it" "$LOG"; fi
else bad "import_from_host.sh with a good path succeeds" "$OUT"; fi

# 17. IMPORT_FORCE=1 is passed on; a failed import keeps the tar (no rm) and exits 1.
if run_helper IMPORT_FORCE=1 STUB_IMPORT_RC=1 --  /Users/x/comms-backup; then bad "import_from_host.sh fails when import fails"
elif has "$LOG" "IMPORT_FORCE=1 ~/scripts/" && ! has "$LOG" "rm -f" && has "$OUT" "kept for a retry"; then
  ok "import_from_host.sh passes IMPORT_FORCE=1 on and keeps the tar when import fails"
else bad "import_from_host.sh passes IMPORT_FORCE=1 on and keeps the tar when import fails" "$LOG
$OUT"; fi

# 18. --volume NAME: the Mini reads the volume through a throwaway read-only container; the rest
# (d06's import dir, import, removal) is as for a path.
if run_helper -- --volume communications-final-backup; then
  l12="$(sed -n 1,2p <<< "$LOG")"; l1="$(grep -F 10.0.0.150 <<< "$l12")"
  if has "$l1" "ssh -o BatchMode=yes 10.0.0.150 PATH=/usr/local/bin:\$PATH docker run --rm -v communications-final-backup:/b:ro alpine:3.20 tar -C /b -cf - STATUS comms.dump tables.tsv manifest.sha256" \
      && has "$LOG" "communications.sh import '/mnt/docker/Communications/import/mini-" \
      && has "$LOG" "docker@d06 rm -f '/mnt/docker/Communications/import/mini-" \
      && [ "$(cat "$T/received")" = "$TAR_BYTES" ]; then
    ok "import_from_host.sh --volume reads the volume read-only through docker run, then imports as for a path"
  else bad "import_from_host.sh --volume reads the volume read-only through docker run" "$LOG"; fi
else bad "import_from_host.sh --volume with a good name succeeds" "$OUT"; fi
if run_helper IMPORT_TAR_IMAGE=busybox:1.36 -- --volume v1 && has "$LOG" "-v v1:/b:ro busybox:1.36 tar -C /b"; then
  ok "import_from_host.sh --volume takes IMPORT_TAR_IMAGE"
else bad "import_from_host.sh --volume takes IMPORT_TAR_IMAGE" "$LOG"; fi

# 19. --volume refusals, each before any ssh: a bad name (leading dot or dash, a space, a quote, a
# ;, a /, a $), a bad IMPORT_TAR_IMAGE, both modes, --volume without a name, and neither mode.
refused=0
for n in ".v" "-v" "a b" "a'b" "a;b" "a/b" 'a$b' ""; do
  run_helper -- --volume "$n" && refused=1; has "$LOG" "ssh" && refused=1
done
run_helper "IMPORT_TAR_IMAGE=alpine;id" -- --volume v1 && refused=1; has "$LOG" "ssh" && refused=1
run_helper -- --volume v1 /Users/x/comms-backup && refused=1; has "$LOG" "ssh" && refused=1
run_helper -- /Users/x/comms-backup --volume v1 && refused=1; has "$LOG" "ssh" && refused=1
run_helper -- --volume && refused=1; has "$LOG" "ssh" && refused=1
run_helper -- && refused=1; has "$LOG" "ssh" && refused=1
if [ "$refused" = 0 ] && has "$OUT" "exactly one"; then
  ok "import_from_host.sh refuses a bad volume name or image, both modes, and neither, before any ssh"
else bad "import_from_host.sh refuses a bad volume name or image, both modes, and neither" "$OUT"; fi

# --- the mail relay (asyla #657) ---------------------------------------------------------------
CS_SRC="$REPO/d06/apps/communications/communications.sh"
[ -n "${COMMUNICATIONS_SH:-}" ] && CS_SRC="$COMMUNICATIONS_SH"
APP_SRC="$REPO/d06/apps/communications"
# The mail-relay service's block of compose.yml, comments dropped.
RELAY_BLOCK="$(awk '/^  mail-relay:$/{f=1;print;next} f && /^  [a-z]|^[a-z]/{f=0} f' "$APP_SRC/compose.yml" | grep -vE '^ *#')"

# R1. up starts the relay last, once, with no --wait; the script names no --wait for it either.
if run_up "${START5[@]}"; then
  relay_up="$(grep -E ' mail-relay$' <<< "$LOG")"
  if [ "$(grep -c . <<< "$relay_up")" = 1 ] && grep -qE '^docker compose (-f [^ ]+ )+up -d mail-relay$' <<< "$relay_up" \
      && [ "$(tail -n 1 <<< "$(grep -E '^docker compose ' <<< "$LOG")")" = "$relay_up" ] \
      && ! grep -E -- '--wait' "$CS_SRC" | grep -qE 'RELAY_SERVICE|mail-relay'; then
    ok "up starts mail-relay once, last, with no --wait"
  else bad "up starts mail-relay once, last, with no --wait" "$relay_up"; fi
  placed="$T/dl/Communications/mail-relay-ca/root_ca.crt"
  if cmp -s "$placed" "$APP_SRC/theorg-v2-root.crt" && [ "$(mode "$placed")" = "-rw-r--r--" ]; then
    ok "up places the committed root at mail-relay-ca/root_ca.crt, 0644"
  else bad "up places the committed root at mail-relay-ca/root_ca.crt, 0644" "$(mode "$placed" 2>&1)"; fi
else bad "up with the five values starts the relay" "$OUT"; fi

# R2. The compose service: no token variable or value, no TLS or key mount, the root file only,
# restart unless-stopped, 2587 on 10.0.0.65 only, 9116 on loopback only, 9117 never published.
tok="$(grep -iE 'token' <<< "$RELAY_BLOCK" | grep -vF 'MAIL_RELAY_TOKEN_ROLE=communications-d06')"
vars="$(grep -oE '\$\{[A-Z_]+' <<< "$RELAY_BLOCK" | sort -u | tr '\n' ' ')"
vols="$(awk '/^    volumes:/{f=1;next} f && /^    [a-z]/{f=0} f' <<< "$RELAY_BLOCK")"
ports="$(awk '/^    ports:/{f=1;next} f && /^    [a-z]/{f=0} f' <<< "$RELAY_BLOCK" | tr -d ' ')"
if [ -z "$tok" ] && [ "$vars" = '${COMMS_REGISTRY ${COMMS_RELAY_TAG ${COMMS_ROOT ' ]; then
  ok "mail-relay: no token in its environment (MAIL_RELAY_TOKEN_ROLE only), no secret variable"
else bad "mail-relay: no token in its environment, no secret variable" "$tok / $vars"; fi
if [ "$vols" = '      - ${COMMS_ROOT:?}/mail-relay-ca/root_ca.crt:/etc/mail-relay/ca/root_ca.crt:ro' ] \
    && ! grep -qE 'tls|key' <<< "$vols" && grep -qx '    restart: unless-stopped' <<< "$RELAY_BLOCK"; then
  ok "mail-relay: the root file read-only is its only mount (no TLS or key); restart unless-stopped"
else bad "mail-relay: the root file is its only mount; restart unless-stopped" "$vols"; fi
if [ "$ports" = $'-"10.0.0.65:2587:2587"\n-"127.0.0.1:9116:9116"' ] \
    && ! grep -vE '^ *#' "$APP_SRC/compose.yml" | grep -qE '9117:|:9117"' \
    && [ "$(grep -vE '^ *#' "$APP_SRC/compose.yml" | grep -cE '2587')" = 1 ]; then
  ok "mail-relay: 2587 on 10.0.0.65 only, 9116 on 127.0.0.1 only, 9117 never published"
else bad "mail-relay: 2587 on 10.0.0.65 only, 9116 on 127.0.0.1 only, 9117 never published" "$ports"; fi

# R3. The pin: the script's colon form, compose's lower-case hex, the committed root's SHA-256, and
# the committed root is d05's copy.
colon="$(sed -n 's/^CA_FINGERPRINT="\([0-9A-F:]*\)"$/\1/p' "$CS_SRC")"
hex="$(sed -n 's/^ *- MAIL_RELAY_STEPCA_ROOT_SHA256=\([0-9a-f]*\)$/\1/p' "$APP_SRC/compose.yml")"
real="$(openssl x509 -in "$APP_SRC/theorg-v2-root.crt" -noout -fingerprint -sha256 | sed 's/^.*=//')"
if [ -n "$colon" ] && [ "${#hex}" = 64 ] && [ "$colon" = "$real" ] \
    && [ "$(tr -d ':' <<< "$colon" | tr '[:upper:]' '[:lower:]')" = "$hex" ] \
    && cmp -s "$APP_SRC/theorg-v2-root.crt" "$REPO/d05/apps/identity-platform/theorg-v2-root.crt"; then
  ok "the root pin: CA_FINGERPRINT = compose's MAIL_RELAY_STEPCA_ROOT_SHA256 = the committed root (= d05's)"
else bad "the root pin agrees across the script, compose and the committed root" "$colon / $hex / $real"; fi

# R4. relay-status: one word from the State and the log since this start; never Config.
LOGF="$T/relay.log"
W='2026-01-01 00:00:01 WARNING wrapped token spent: waiting for the token broker'
L='2026-01-01 00:00:09 WARNING listening on 2587 (STARTTLS and AUTH required)'
status_case() {  # expected-word label logs-lines... (env words in SC_ENV)
  local want="$1" label="$2"; shift 2
  printf '%s\n' "$@" > "$LOGF"
  # shellcheck disable=SC2086  # the case's NAME=value words
  if run_cs ${SC_ENV:-} STUB_RELAY_LOGS="$LOGF" -- relay-status && [ "$OUT" = "$want" ] && ! has "$LOG" "Config"; then
    ok "relay-status: $label -> $want"
  else bad "relay-status: $label -> $want" "$OUT"; fi
}
SC_ENV="" status_case absent "no container"
SC_ENV="STUB_RELAY_IDS=r1" status_case waiting "running, the wait logged" "$W"
SC_ENV="STUB_RELAY_IDS=r1" status_case running "running, listening after the wait" "$W" "$L"
SC_ENV="STUB_RELAY_IDS=r1" status_case running "running, no wait logged" "$L"
SC_ENV="STUB_RELAY_IDS=r1 STUB_RELAY_STATE=restarting" status_case restarting "restarting" "$W"
SC_ENV="STUB_RELAY_IDS=r1 STUB_RELAY_STATE=exited" status_case stopped "exited" "$W"
if run_cs STUB_RELAY_IDS="r1 r2" -- relay-status; then bad "relay-status refuses two relay containers" "$OUT"
elif has "$OUT" "expected one"; then ok "relay-status refuses two relay containers"
else bad "relay-status refuses two relay containers" "$OUT"; fi

# R5. relay-arm: alone, with no start values; its stdin reaches arm.py as uid 10002 unchanged and
# is in no argv; arm.py's word and exit code are passed back. The line is a plain stand-in.
ARM_IN="$T/arm.stdin"
ARM_LINE="stand-in-wrapping-line"
run_arm() {
  local rc
  : > "$T/log"; : > "$ARM_IN"
  OUT="$(printf '%s\n' "$ARM_LINE" | env -i PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T/home" \
    STUB_LOG="$T/log" STUB_ARM_STDIN="$ARM_IN" "$@" bash "$T/app/communications.sh" relay-arm 2>&1)"
  rc=$?
  LOG="$(cat "$T/log")"
  return "$rc"
}
if run_arm STUB_RELAY_IDS=r1 && [ "$OUT" = ok ] && [ "$(cat "$ARM_IN")" = "$ARM_LINE" ] \
    && has "$LOG" "docker exec -i -u 10002 r1 python3 /app/arm.py" && ! has "$LOG" "$ARM_LINE"; then
  ok "relay-arm without start values: stdin to arm.py as uid 10002, in no argv; ok passed back"
else bad "relay-arm: stdin to arm.py as uid 10002" "$OUT / $LOG"; fi
run_arm STUB_RELAY_IDS=r1 STUB_ARM_SAYS=fail STUB_ARM_RC=1; rc=$?
if [ "$rc" = 1 ] && [ "$OUT" = fail ]; then ok "relay-arm passes arm.py's fail and exit 1 back"
else bad "relay-arm passes arm.py's fail and exit 1 back" "$rc $OUT"; fi
if run_arm || has "$LOG" "exec"; then bad "relay-arm with no relay container fails before any exec" "$OUT"
else ok "relay-arm with no relay container fails before any exec"; fi
: > "$T/log"
if printf '%s\n' "$ARM_LINE" | env -i PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T/home" STUB_LOG="$T/log" \
    STUB_RELAY_IDS=r1 STUB_ARM_STDIN="$ARM_IN" bash "$T/app/communications.sh" relay-arm verify >/dev/null 2>&1 \
    || grep -qF "exec" "$T/log"; then
  bad "relay-arm combined with another switch is refused before any exec"
else ok "relay-arm combined with another switch is refused before any exec"; fi
if grep -qE '^[^#]*set -[a-z]*x' "$CS_SRC"; then bad "communications.sh never traces (set -x)"
else ok "communications.sh never traces (set -x)"; fi

# R6. verify's relay check (the other checks fail here, with nothing listening; only the relay's
# lines are read).
verify_case() {  # label want-in-OUT log-file-lines... (env words in VC_ENV)
  local label="$1" want="$2"; shift 2
  printf '%s\n' "$@" > "$LOGF"
  # shellcheck disable=SC2086
  run_cs COMMS_WAIT_S=0 COMMS_RELAY_WAIT_S=0 ${VC_ENV:-} STUB_RELAY_LOGS="$LOGF" -- verify
  if has "$OUT" "$want"; then ok "verify: $label"; else bad "verify: $label" "$(grep -i relay <<< "$OUT")"; fi
}
VC_ENV="" verify_case "no relay warns" "[WARN] mail-relay is not deployed"
VC_ENV="STUB_RELAY_IDS=r1 STUB_RELAY_HEALTH=unhealthy" verify_case "a waiting relay warns, not fatal" "[WARN] mail-relay is running unarmed" "$W"
has "$LOG" "/app/smoke.py" && bad "verify: no probe of a waiting relay" "$LOG"
VC_ENV="STUB_RELAY_IDS=r1 STUB_RELAY_HEALTH=healthy" verify_case "a healthy relay gets smoke.py probe" "smoke.py probe (STARTTLS, verified for mail-relay.asyla.org) OK" "$W" "$L"
has "$LOG" "docker exec r1 python3 /app/smoke.py probe --tls-name mail-relay.asyla.org" || bad "verify: the probe names mail-relay.asyla.org" "$LOG"
VC_ENV="STUB_RELAY_IDS=r1 STUB_RELAY_HEALTH=healthy STUB_PROBE_RC=1" verify_case "a failed probe is fatal" "[ERROR] mail-relay smoke.py probe" "$W" "$L"
VC_ENV="STUB_RELAY_IDS=r1 STUB_RELAY_HEALTH=unhealthy" verify_case "running, unhealthy, not waiting is fatal" "[ERROR] mail-relay is running (unhealthy)" "$W" "$L"

# R7. A bad root: up and restart stop before any compose call.
cp "$T/app/theorg-v2-root.crt" "$T/root.good"
printf 'not a certificate\n' > "$T/app/theorg-v2-root.crt"
if run_up "${START5[@]}"; then bad "up with a bad root is refused"
elif has "$LOG" "compose" || ! has "$OUT" "not placing it"; then bad "up with a bad root stops before compose" "$OUT"
else ok "up with a bad root stops before compose"; fi
if CS_CMD=restart run_up "${START5[@]}"; then bad "restart with a bad root is refused"
elif has "$LOG" "compose"; then bad "restart with a bad root stops before its down" "$LOG"
else ok "restart with a bad root stops before its down"; fi
cp "$T/root.good" "$T/app/theorg-v2-root.crt"

exit "$fail"
