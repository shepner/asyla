#!/bin/bash
# d06/apps/communications/communications.sh `up` against stubs (docker, stat): the refusal without
# the start values, the NATS users.conf (names and $NATS_PW_<i> references only), each password
# pre-quoted as a NATS string in nats's environment and named (not valued) in the generated
# override, the mq-user pairs and their refusals (a `#` or `/` in a name; a webhook-mq value that
# is not URL-safe, refused by `up` and by `restart` before its down), nats recreated only when
# users.conf changed while it ran, the start order, and vector left out when observability's
# network is missing.
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
cp "$REPO"/d06/apps/communications/{compose.yml,docker-credential-communications-env} "$T/app/"
cp "${COMMUNICATIONS_SH:-$REPO/d06/apps/communications/communications.sh}" "$T/app/communications.sh"
USERS="$T/dl/Communications/nats-runtime/users.conf"

# docker: logs each call (paths shortened). A compose call given a second -f logs that file's
# lines (the generated override) and the NATS_PW_<i> it would hand nats. `ps -q ... nats` prints
# an id when STUB_RUNNING; `network inspect` fails when STUB_NO_OBS; images are all present.
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" | sed -E "s#-f [^ ]*/compose.yml#-f compose.yml#; s#-f [^ ]*/nats-users.override.yml#-f OVERRIDE#; s# --project-directory [^ ]*##" >> "$STUB_LOG"
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
  "network inspect"*) [ -z "${STUB_NO_OBS:-}" ] ;;
  *"ps -q --status running nats"*) if [ -n "${STUB_RUNNING:-}" ]; then echo abc; fi ;;
esac
EOF
# stat: backup/ already has the image's owner and mode, so ensure_dirs needs no sudo.
cat > "$T/bin/stat" <<'EOF'
#!/bin/bash
echo "999 999 700"
EOF
chmod +x "$T/bin/docker" "$T/bin/stat"

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
  if [ "$order" = "nats nats-exporter comms-postgres chat-api webhook-to-mq-vikunja vector " ]; then
    ok "start order: nats, exporter, postgres, chat-api, webhook-to-mq, vector"
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

exit "$fail"
