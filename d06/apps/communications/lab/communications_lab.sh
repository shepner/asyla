#!/bin/bash
# End-to-end lab of communications.sh on a workstation's Docker (Docker Desktop on ws01). Nothing on
# d06 is touched. Run from anywhere, with a fresh tree of theOrg communications at the commit the
# compose names:
#   mkdir <new empty dir> && git -C ~/local/theOrg/projects/communications archive beff7c55 | tar -x -C <that dir>
#   d06/apps/communications/lab/communications_lab.sh <that dir>
# Exit 0 when every proof passes. KEEP=1 leaves the containers, network, volume and images.
#
# This outer part runs under macOS bash 3.2. It builds theOrg's five images under the lab prefix
# (COMMS_REGISTRY_OVERRIDE), a Debian runner (bash 5, flock, GNU stat, rsync, sudo, the docker
# CLI and compose), and runs this file's `inner` part in the runner as uid 1003 with passwordless
# sudo, like d06's docker user. Lab data lives in a Docker volume, mounted in the runner at its
# path in the Docker VM, so compose's bind mounts resolve the same there and Linux permissions are
# enforced (a macOS bind mount keeps owners but does not enforce modes). theorg.asyla.org maps to
# the runner's own address (--add-host), so the backup's serving-host check passes for real.
# Lab values are generated in the runner and kept only in its process environment: never printed
# and never written by this lab. The external observability network is created here, with no Loki
# (vector-http.toml has its startup healthcheck off, so vector stays healthy without one).
# The checks' `bash -c '...'` bodies take $1, $2 from their own arguments, by design.
# shellcheck disable=SC2016
set -euo pipefail

LAB_PREFIX="comms-lab"
LAB_RUNNER="comms-lab-runner:local"
LAB_VOLUME="comms-lab-data"
OBS_NET="observability_observability-net"
DEFAULT_TAG="beff7c55c9880facd23a1c289f667de5c1692795"
SERVICES="nats chat-api webhook-to-mq vector backup"

if [ "${1:-}" != "inner" ] && [ "${1:-}" != "proofs" ]; then
  src="${1:?usage: communications_lab.sh <theOrg communications tree>}"
  here="$(cd "$(dirname "$0")" && pwd)"
  app="$(cd "$here/.." && pwd)"
  repo="$(cd "$app/../../.." && pwd)"
  tag="${COMMS_LAB_TAG:-$DEFAULT_TAG}"
  for s in $SERVICES; do
    [ -f "$src/Dockerfile.$s" ] || { echo "[ERROR] $src/Dockerfile.$s missing" >&2; exit 2; }
  done
  if docker ps -aq --filter label=com.docker.compose.project=communications | grep -q . \
      || docker ps -aq --filter label=com.docker.compose.project=observability | grep -q . \
      || docker ps -aq --filter name='^comms-lab-caddy$' | grep -q . \
      || docker network inspect communications_net >/dev/null 2>&1 \
      || docker network inspect "$OBS_NET" >/dev/null 2>&1 \
      || docker volume inspect "$LAB_VOLUME" >/dev/null 2>&1; then
    echo "[ERROR] a communications or observability project, comms-lab-caddy, communications_net, $OBS_NET or $LAB_VOLUME exists here already; not running over it" >&2
    exit 2
  fi

  LAB_PULLED=""
  # Run by the EXIT trap; $ids, $SERVICES and $LAB_PULLED are word lists.
  # shellcheck disable=SC2317,SC2086
  cleanup() {
    if [ "${KEEP:-0}" = 1 ]; then echo "[LAB] KEEP=1: left in place"; return; fi
    local ids
    ids="$(docker ps -aq --filter label=com.docker.compose.project=communications)"
    [ -z "$ids" ] || docker rm -f $ids >/dev/null
    # The stand-ins of proofs 12 and 13 (none existed before the run: checked above).
    docker rm -f comms-lab-caddy >/dev/null 2>&1 || true
    ids="$(docker ps -aq --filter label=com.docker.compose.project=observability)"
    [ -z "$ids" ] || docker rm -f $ids >/dev/null
    docker network rm communications_net >/dev/null 2>&1 || true
    docker network rm "$OBS_NET" >/dev/null 2>&1 || true
    docker volume rm "$LAB_VOLUME" >/dev/null 2>&1 || true
    for s in $SERVICES; do docker image rm "$LAB_PREFIX/communications-$s:$tag" >/dev/null 2>&1 || true; done
    docker image rm "$LAB_RUNNER" >/dev/null 2>&1 || true
    for i in $LAB_PULLED; do docker image rm "$i" >/dev/null 2>&1 || true; done
    echo "[LAB] cleanup: containers $(docker ps -aq --filter label=com.docker.compose.project=communications | wc -l | tr -d ' ')," \
      "stand-ins $( { docker ps -aq --filter label=com.docker.compose.project=observability; docker ps -aq --filter name='^comms-lab-caddy$'; } | wc -l | tr -d ' ')," \
      "lab images $(docker images -q "$LAB_PREFIX/*" | wc -l | tr -d ' ')," \
      "volume $(docker volume inspect "$LAB_VOLUME" >/dev/null 2>&1 && echo present || echo gone)," \
      "networks $(docker network ls -q --filter name='^communications_net$' --filter name="^$OBS_NET\$" | wc -l | tr -d ' ')"
  }
  trap cleanup EXIT

  # The public images (compose.yml's two, the runner's base): pulled here when missing, since the
  # deploy's pull needs the gitea token; the ones this run pulled are removed at the end.
  # compose.yml's third-party images as it names them (postgres by tag and digest).
  third="$(sed -n 's/^ *image: \([a-z][^$]*\)$/\1/p' "$app/compose.yml")"
  for i in $third docker:29-cli debian:bookworm-slim; do
    if ! docker image inspect "$i" >/dev/null 2>&1; then
      docker pull -q "$i" >/dev/null
      LAB_PULLED="$LAB_PULLED $i"
    fi
  done
  for s in $SERVICES; do
    echo "[LAB] building $LAB_PREFIX/communications-$s:$tag"
    docker build -q -f "$src/Dockerfile.$s" -t "$LAB_PREFIX/communications-$s:$tag" "$src" >/dev/null
  done
  echo "[LAB] building the runner"
  docker build -q -t "$LAB_RUNNER" - >/dev/null <<'EOF'
FROM docker:29-cli AS cli
FROM debian:bookworm-slim
COPY --from=cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=cli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose
RUN apt-get update && apt-get install -y --no-install-recommends bash rsync util-linux coreutils curl sudo procps ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1000 asyla && useradd -u 1003 -g 1000 -G root -m -s /bin/bash docker \
    && echo 'docker ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/docker && chmod 0440 /etc/sudoers.d/docker
EOF
  docker volume create "$LAB_VOLUME" >/dev/null
  data="$(docker volume inspect -f '{{.Mountpoint}}' "$LAB_VOLUME")"
  docker network create "$OBS_NET" >/dev/null
  addr="$(docker run --rm --network host "$LAB_RUNNER" hostname -I | awk '{print $1}')"
  echo "[LAB] runner address $addr; data $data"
  tag_env=""
  [ "$tag" = "$DEFAULT_TAG" ] || tag_env="$tag"
  rc=0
  docker run --rm --network host --add-host "theorg.asyla.org:$addr" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$data:$data" -v "$app:$app:ro" -v "$repo/docker/backup_lib.sh:/lab/backup_lib.sh:ro" \
    -e LAB_DATA="$data" -e LAB_APP="$app" -e LAB_REGISTRY="$LAB_PREFIX" -e LAB_TAG_OVERRIDE="$tag_env" \
    "$LAB_RUNNER" bash "$app/lab/communications_lab.sh" inner || rc=$?
  exit "$rc"
fi

# --- In the runner, as root: the scratch HOME (backup_lib.sh and a common.env), then as uid 1003.
if [ "$1" = "inner" ]; then
  h="$LAB_DATA/home"
  mkdir -p "$h/scripts/docker" "$LAB_DATA/dl" "$LAB_DATA/d1" "$LAB_DATA/logs"
  cp /lab/backup_lib.sh "$h/scripts/docker/backup_lib.sh"
  printf 'DOCKER_DL=%s\nDOCKER_D1=%s\n' "$LAB_DATA/dl" "$LAB_DATA/d1" > "$h/scripts/docker/common.env"
  chown -R 1003:1000 "$h" "$LAB_DATA/dl" "$LAB_DATA/d1" "$LAB_DATA/logs"
  exec runuser -u docker -- env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$h" LAB_DATA="$LAB_DATA" \
    LAB_APP="$LAB_APP" COMMS_REGISTRY_OVERRIDE="$LAB_REGISTRY" ${LAB_TAG_OVERRIDE:+COMMS_TAG_OVERRIDE="$LAB_TAG_OVERRIDE"} \
    bash "$0" proofs
fi

# --- In the runner, as uid 1003: the proofs.
set +x
CS="$LAB_APP/communications.sh"
ROOT="$LAB_DATA/dl/Communications"
MIRROR="$LAB_DATA/d1/Communications/mirror"
LOGS="$LAB_DATA/logs"
SVCS=(nats nats-exporter comms-postgres chat-api webhook-to-mq-vikunja vector)
PASS=0 FAIL=0

ok() { PASS=$((PASS + 1)); echo "  PASS $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
cname() { echo "communications-$1-1"; }
# A missing container still gets an empty line from docker inspect -f: keep its output only on success.
inspect_or_absent() { local o; if o="$(docker inspect -f "$1" "$(cname "$2")" 2>/dev/null)"; then echo "$o"; else echo absent; fi; }
state() { inspect_or_absent '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1"; }
cid() { inspect_or_absent '{{.Id}}' "$1"; }
started_ns() { date -d "$(docker inspect -f '{{.State.StartedAt}}' "$(cname "$1")")" +%s%N; }
# Healthy, or running for the one service with no healthcheck (the exporter).
wait_ready() {
  local s="$1" want=healthy deadline=$(( $(date +%s) + 150 ))
  [ "$s" = nats-exporter ] && want=running
  until [ "$(state "$s")" = "$want" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 3
  done
}
all_ready() { local s n=0; for s in "${SVCS[@]}"; do if wait_ready "$s"; then n=$((n + 1)); else echo "    $s: $(state "$s")"; fi; done; echo "    ready $n/${#SVCS[@]}"; [ "$n" -eq "${#SVCS[@]}" ]; }
# A command's output to $LOGS/<name>.log, not to the run's own output.
run_log() { local log="$LOGS/$1.log"; shift; "$@" > "$log" 2>&1; }
run_cs() { local n="$1"; shift; run_log "$n" "$CS" "$@"; }
ids_now() { local s; for s in "${SVCS[@]}"; do printf '%s=%s ' "$s" "$(cid "$s")"; done; }

# Lab values: random, in this process's environment only. The extra mq user's password carries
# `$`, `"` and `\`, so the NATS quoting and the $NATS_PW_<i> references are proven on it.
# webhook-mq's password is URL-safe: theOrg's chat-api percent-encodes it into its NATS URL and
# nats-py does not decode it, so a `$`, `{` or `\` there is an Authorization Violation (theOrg item
# 2026-11-09-communications-communications-chat-api-percent-encodes-the-nats-password-in, theOrg
# 1d961052). Production's vault value is token_urlsafe, which that encoding leaves unchanged.
gen() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24; }
COMMS_POSTGRES_PASSWORD="$(gen)"
COMMS_NATS_WEBHOOK_MQ_USERNAME="webhook-mq"
COMMS_NATS_WEBHOOK_MQ_PASSWORD="$(gen)"
COMMS_CHAT_API_TOKEN="$(gen)"
COMMS_VIKUNJA_WEBHOOK_SECRET="$(gen)"
COMMS_MQ_USER_LAB_USERNAME="lab-worker"
# The literal `"` and `\` are the point of this value.
# shellcheck disable=SC2089
COMMS_MQ_USER_LAB_PASSWORD="$(gen)\$\"\\$(gen)"
# shellcheck disable=SC2090
export COMMS_POSTGRES_PASSWORD COMMS_NATS_WEBHOOK_MQ_USERNAME COMMS_NATS_WEBHOOK_MQ_PASSWORD \
  COMMS_CHAT_API_TOKEN COMMS_VIKUNJA_WEBHOOK_SECRET COMMS_MQ_USER_LAB_USERNAME COMMS_MQ_USER_LAB_PASSWORD
VALUES=(COMMS_POSTGRES_PASSWORD COMMS_NATS_WEBHOOK_MQ_PASSWORD COMMS_CHAT_API_TOKEN
  COMMS_VIKUNJA_WEBHOOK_SECRET COMMS_MQ_USER_LAB_PASSWORD)
# The value as nats holds it (communications.sh's nats_quote), to grep for that form too.
quoted() { local v="${!1}"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '"%s"' "$v"; }
# grep -F for a value without it reaching argv or output: the pattern comes in on a pipe.
absent_in() { ! grep -r -F -q -f <(printf '%s\n' "${!1}") "$2"; }
absent_quoted_in() { ! grep -F -q -f <(quoted "$1"; echo) "$2"; }
# A credential on stdin to theOrg's probe, run in communications_net: 0 accepted, 1 refused.
probe_cred() {
  local rc=0
  printf '%s\n%s\n' "$1" "$2" | docker run --rm -i --network communications_net \
    -v "$LAB_APP/theorg/nats_auth_probe.py:/probe.py:ro" --entrypoint python3 \
    "$COMMS_REGISTRY_OVERRIDE/communications-chat-api:${COMMS_TAG_OVERRIDE:-beff7c55c9880facd23a1c289f667de5c1692795}" \
    /probe.py nats 4222 >/dev/null 2>&1 || rc=$?
  return "$rc"
}
probe_refused() { local rc=0; probe_cred "$1" "$2" || rc=$?; [ "$rc" -eq 1 ]; }
# theOrg's nats-entrypoint.sh (has_users) needs user and password on one line; a split entry
# would be replaced by its refuse-all placeholder. Two users here: webhook-mq and lab-worker.
one_line_entries() {
  local n m
  n="$(grep -c 'user:' "$1")"
  m="$(grep -Ec '^    \{ user: "[a-z-]+", password: \$NATS_PW_[0-9]+ \}$' "$1")"
  echo "    entries: $m of $n one-line"
  [ "$n" -eq 2 ] && [ "$m" -eq 2 ]
}

echo "[1] up starts every service healthy, in order"
check "up exits 0" run_cs 1-up up
check "all six services ready" all_ready
prev="" prev_t=0
for s in "${SVCS[@]}"; do
  t="$(started_ns "$s")"
  if [ -n "$prev" ]; then check "$prev started before $s" test "$prev_t" -lt "$t"; fi
  prev="$s" prev_t="$t"
done
if [ "$FAIL" -gt 0 ]; then echo "[LAB] up failed (log: $LOGS/1-up.log): stopping"; tail -20 "$LOGS/1-up.log"; exit 1; fi

echo "[3] users.conf holds names and references only"
U="$ROOT/nats-runtime/users.conf"
for v in "${VALUES[@]}"; do
  check "$v not in users.conf (raw)" absent_in "$v" "$U"
  check "$v not in users.conf (NATS-quoted)" absent_quoted_in "$v" "$U"
done
check "every user entry is one line: { user: \"<name>\", password: \$NATS_PW_<i> }" one_line_entries "$U"
check "nats log has no placeholder or refusal" bash -c '! docker logs "$1" 2>&1 | grep -E -q "placeholder|refusing"' _ "$(cname nats)"
check "users.conf mode 0644" test "$(stat -c %a "$U")" = 644
check "webhook-mq password (URL-safe) accepted by nats" probe_cred "$COMMS_NATS_WEBHOOK_MQ_USERNAME" "$COMMS_NATS_WEBHOOK_MQ_PASSWORD"
check "lab-worker password (with \$ \" \\) accepted by nats" probe_cred "$COMMS_MQ_USER_LAB_USERNAME" "$COMMS_MQ_USER_LAB_PASSWORD"
check "a wrong password refused" probe_refused "$COMMS_NATS_WEBHOOK_MQ_USERNAME" "x$(gen)"

echo "[8] a second up with users.conf unchanged recreates nothing"
before="$(ids_now)"; nats_t="$(started_ns nats)"
check "second up exits 0" run_cs 8-up-again up
check "second up says users.conf unchanged" grep -q 'users.conf unchanged' "$LOGS/8-up-again.log"
check "nats not recreated (same id)" test "$(cid nats)" = "$(echo "$before" | tr ' ' '\n' | sed -n 's/^nats=//p')"
check "nats not restarted (same start time)" test "$(started_ns nats)" = "$nats_t"
check "no service recreated" test "$(ids_now)" = "$before"

echo "[2] verify"
check "verify exits 0" run_cs 2-verify verify
for line in 'chat-api http://127.0.0.1:9098/health OK' 'chat_smoke.py inside chat-api OK' \
    'nats http://127.0.0.1:8222/healthz ok' 'nats refuses anonymous clients on 4222 and 8080' \
    'webhook-to-mq-vikunja /health OK'; do
  check "verify: $line" grep -F -q "[INFO] $line" "$LOGS/2-verify.log"
done
check "chat /health 200 from the host" test "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9098/health)" = 200
MARKER="$(sed -n 's/.*chat_smoke OK (channel=chat-smoke, marker=\(chat-smoke-[0-9a-f]*\)).*/\1/p' "$LOGS/2-verify.log" | head -1)"
check "smoke marker captured" test -n "$MARKER"

echo "[4] restart"
before="$(ids_now)"
check "restart exits 0" run_cs 4-restart restart
check "all six ready after restart" all_ready
check "every container is new" bash -c 'for a in $1; do case " $2 " in *" $a "*) exit 1 ;; esac; done' _ "$before" "$(ids_now)"
check "verify after restart" run_cs 4-verify verify

echo "[5] backup, then verify; the mirror"
check "backup exits 0" run_cs 5-backup backup
check "verify after backup" run_cs 5-verify verify
check "backup/STATUS OK" bash -c 'sudo -n head -1 "$1/backup/STATUS" | grep -q "^OK"' _ "$ROOT"
check "mirror STATUS OK" bash -c 'head -1 "$1/STATUS" | grep -q "^OK"' _ "$MIRROR"
check "mirror .backup-status OK" bash -c 'head -1 "$1/.backup-status" | grep -q "^OK"' _ "$MIRROR"
check "mirror has no .lock" test ! -e "$MIRROR/.lock"
check "mirror has no .work/" test ! -e "$MIRROR/.work"
check "mirror manifest checks" bash -c 'cd "$1" && sha256sum --quiet -c manifest.sha256' _ "$MIRROR"
check "mirror lists what backup/ lists, bar .lock and .work" bash -c \
  'diff <(sudo -n find "$1/backup" -mindepth 1 -printf "%P\n" | grep -Ev "^\.lock$|^\.work(/|$)" | sort) \
        <(find "$2" -mindepth 1 -printf "%P\n" | grep -Ev "^\.backup-(status|root)$" | sort) >/dev/null' _ "$ROOT" "$MIRROR"
check "backup/ is 999:999 0700" test "$(stat -c '%u %g %a' "$ROOT/backup")" = "999 999 700"

echo "[6] down, wipe pg-data, restore from the mirror, up"
check "restore refuses over a live pg-data" bash -c '! "$1" restore > "$2" 2>&1 && grep -q "is not empty" "$2"' _ "$CS" "$LOGS/6-restore-refused.log"
check "down exits 0" run_cs 6-down down
check "pg-data wiped" sudo -n rm -rf "$ROOT/pg-data"
check "restore exits 0" run_cs 6-restore restore
check "up after restore exits 0" run_cs 6-up up
check "all six ready after restore" all_ready
LIST_PY='
import json, os, sys, urllib.request
req = urllib.request.Request("http://127.0.0.1:9098/api/channels/chat-smoke/messages",
                             headers={"Authorization": "Bearer " + os.environ["CHAT_API_TOKEN"]})
msgs = json.load(urllib.request.urlopen(req, timeout=10))["messages"]
sys.exit(0 if any(sys.argv[1] in (m.get("content") or "") for m in msgs) else 1)
'
check "the smoke message posted before the backup is listed back ($MARKER)" \
  docker exec "$(cname chat-api)" python -c "$LIST_PY" "$MARKER"
check "verify after restore" run_cs 6-verify verify

echo "[7] up with $OBS_NET missing"
run_cs 7-down down || true
check "network removed" run_log 7-net-rm docker network rm "$OBS_NET"
rc=0; run_cs 7-up up || rc=$?
echo "    up exit $rc; running: $(docker ps --filter label=com.docker.compose.project=communications --format '{{.Names}}' | sort | tr '\n' ' ')"
check "up exits 0 without the network" test "$rc" -eq 0
check "up warns that vector is not started" grep -q 'vector not started: network' "$LOGS/7-up.log"
for s in nats nats-exporter comms-postgres chat-api webhook-to-mq-vikunja; do check "$s ready" wait_ready "$s"; done
check "vector absent" test "$(state vector)" = absent
run_cs 7-down-end down || true

echo "[9] backup and restore with COMMS_POSTGRES_PASSWORD unset: the value from the running comms-postgres"
# An empty value is what build_host.py's restore phase and host-maintenance's nightly backup give.
rc=0; COMMS_POSTGRES_PASSWORD='' run_cs 9-backup-absent backup || rc=$?
echo "    backup with comms-postgres absent: exit $rc"
check "backup refused while comms-postgres is absent" test "$rc" -ne 0
check "backup says comms-postgres is not running" grep -q 'comms-postgres is not running to take it from' "$LOGS/9-backup-absent.log"
rc=0; COMMS_POSTGRES_PASSWORD='' RESTORE_FORCE=1 run_cs 9-restore-absent restore || rc=$?
echo "    RESTORE_FORCE=1 restore with comms-postgres absent: exit $rc"
check "restore refused while comms-postgres is absent" test "$rc" -ne 0
check "restore says comms-postgres is not running" grep -q 'comms-postgres is not running to take it from' "$LOGS/9-restore-absent.log"
# observability's network, now from a stand-in observability project (proof 13 downs it).
OBS_STANDIN="$LAB_DATA/home/obs-standin.yml"
printf 'name: observability\nservices:\n  standin:\n    image: %s\n    command: ["sleep", "infinity"]\n    networks: [observability-net]\nnetworks:\n  observability-net: {}\n' "$LAB_RUNNER" > "$OBS_STANDIN"
check "stand-in observability project up" run_log 9-obs-up docker compose -f "$OBS_STANDIN" up -d --quiet-pull
check "up exits 0" run_cs 9-up up
check "all six ready" all_ready
mirror_t="$(stat -c %Y "$MIRROR/.backup-status")"
# The value taken from comms-postgres is the one it runs with, so restore's `up -d comms-postgres`
# finds its configuration unchanged and recreates nothing: the same container id, start time.
pg_id="$(cid comms-postgres)"; pg_t="$(started_ns comms-postgres)"
sleep 1
check "backup without the value exits 0" bash -c 'env -u COMMS_POSTGRES_PASSWORD "$1" backup > "$2" 2>&1' _ "$CS" "$LOGS/9-backup.log"
check "backup says the value came from comms-postgres" grep -q 'taken from the running comms-postgres container' "$LOGS/9-backup.log"
check "the mirror was rewritten" test "$(stat -c %Y "$MIRROR/.backup-status")" -gt "$mirror_t"
check "mirror STATUS OK" bash -c 'head -1 "$1/STATUS" | grep -q "^OK"' _ "$MIRROR"
check "verify (posts a message after the backup)" run_cs 9-verify verify
AFTER="$(sed -n 's/.*chat_smoke OK (channel=chat-smoke, marker=\(chat-smoke-[0-9a-f]*\)).*/\1/p' "$LOGS/9-verify.log" | head -1)"
check "post-backup marker captured" test -n "$AFTER"
rc=0; COMMS_POSTGRES_PASSWORD='' run_cs 9-restore-refused restore || rc=$?
check "restore without RESTORE_FORCE refused over the live pg-data" bash -c '[ "$1" -ne 0 ] && grep -q "is not empty; refusing to restore over it" "$2"' _ "$rc" "$LOGS/9-restore-refused.log"
check "RESTORE_FORCE=1 restore without the value exits 0" bash -c 'env -u COMMS_POSTGRES_PASSWORD RESTORE_FORCE=1 "$1" restore > "$2" 2>&1' _ "$CS" "$LOGS/9-restore.log"
check "restore says the value came from comms-postgres" grep -q 'taken from the running comms-postgres container' "$LOGS/9-restore.log"
check "restore started chat-api again" grep -q 'chat-api started again' "$LOGS/9-restore.log"
check "restore's up found comms-postgres running (compose: Running)" grep -q 'Container communications-comms-postgres-1 Running' "$LOGS/9-restore.log"
check "comms-postgres not recreated by backup or restore (same id)" test "$(cid comms-postgres)" = "$pg_id"
check "comms-postgres not restarted by backup or restore (same start time)" test "$(started_ns comms-postgres)" = "$pg_t"
check "chat-api ready after the restore" wait_ready chat-api
check "the pre-backup message is listed ($MARKER)" docker exec "$(cname chat-api)" python -c "$LIST_PY" "$MARKER"
check "the post-backup message is gone ($AFTER)" bash -c '! docker exec "$1" python -c "$2" "$3"' _ "$(cname chat-api)" "$LIST_PY" "$AFTER"
check "theOrg kept the replaced database in backup/.pre-restore-*" bash -c 'sudo -n find "$1/backup" -maxdepth 1 -name ".pre-restore-*" | grep -q .' _ "$ROOT"
check "verify after the restore" run_cs 9-verify2 verify
check "a second backup without the value exits 0" bash -c 'env -u COMMS_POSTGRES_PASSWORD "$1" backup > "$2" 2>&1' _ "$CS" "$LOGS/9-backup2.log"
check "the safety copy stays in backup/" bash -c 'sudo -n find "$1/backup" -maxdepth 1 -name ".pre-restore-*" | grep -q .' _ "$ROOT"
check "the safety copy is not in the mirror" bash -c '! find "$1" -maxdepth 1 -name ".pre-restore-*" | grep -q .' _ "$MIRROR"

echo "[10] a webhook-mq password that is not URL-safe is refused before anything is recreated"
before="$(ids_now)"; nats_t="$(started_ns nats)"; users_sum="$(sha256sum < "$ROOT/nats-runtime/users.conf")"
rc=0; COMMS_NATS_WEBHOOK_MQ_PASSWORD="$(gen)%" run_cs 10-up up || rc=$?
check "up refused" bash -c '[ "$1" -ne 0 ] && grep -q "outside A-Z a-z 0-9 _ -" "$2"' _ "$rc" "$LOGS/10-up.log"
rc=0; COMMS_NATS_WEBHOOK_MQ_PASSWORD="$(gen)%" run_cs 10-restart restart || rc=$?
check "restart refused" bash -c '[ "$1" -ne 0 ] && grep -q "outside A-Z a-z 0-9 _ -" "$2"' _ "$rc" "$LOGS/10-restart.log"
check "no container recreated or stopped" test "$(ids_now)" = "$before"
check "nats not restarted" test "$(started_ns nats)" = "$nats_t"
check "users.conf unchanged" test "$(sha256sum < "$ROOT/nats-runtime/users.conf")" = "$users_sum"

echo "[11] a # or / in a NATS user name is refused"
for bad_name in 'lab#worker' 'lab/worker'; do
  rc=0; COMMS_MQ_USER_LAB_USERNAME="$bad_name" run_cs 11-name up || rc=$?
  check "$bad_name refused" bash -c '[ "$1" -ne 0 ] && grep -q "holds a # or a /" "$2"' _ "$rc" "$LOGS/11-name.log"
done
check "no container recreated" test "$(ids_now)" = "$before"
check "users.conf unchanged" test "$(sha256sum < "$ROOT/nats-runtime/users.conf")" = "$users_sum"

echo "[12] down and restart with a stand-in Caddy attached to communications_net"
check "stand-in Caddy on communications_net" run_log 12-caddy-up docker run -d --name comms-lab-caddy --network communications_net "$LAB_RUNNER" sleep infinity
rc=0; run_cs 12-down down || rc=$?
DOWN_RC="$rc"
echo "    communications.sh down exit $rc; compose said: $(grep -h 'communications_net' "$LOGS/12-down.log" | tr -s ' ' | tr '\n' ';')"
check "down exits 0" test "$rc" -eq 0
check "every communications container removed" test "$(docker ps -aq --filter label=com.docker.compose.project=communications | wc -l)" -eq 0
echo "    communications_net after down: $(docker network inspect communications_net >/dev/null 2>&1 && echo kept || echo removed)"
check "up exits 0 on the kept network" run_cs 12-up up
check "all six ready" all_ready
rc=0; run_cs 12-restart restart || rc=$?
RESTART_RC="$rc"
echo "    communications.sh restart exit $rc"
check "restart exits 0" test "$rc" -eq 0
check "all six ready after restart" all_ready
check "the stand-in Caddy is still attached" bash -c 'docker network inspect -f "{{range .Containers}}{{.Name}} {{end}}" communications_net | grep -q comms-lab-caddy'
check "stand-in Caddy removed" run_log 12-caddy-rm docker rm -f comms-lab-caddy

echo "[13] observability down while communications-vector-1 is on its network"
rc=0; docker compose -f "$OBS_STANDIN" down > "$LOGS/13-obs-down.log" 2>&1 || rc=$?
OBS_RC="$rc"
echo "    observability down exit $rc; compose said: $(grep -h "$OBS_NET" "$LOGS/13-obs-down.log" | tr -s ' ' | tr '\n' ';')"
echo "    $OBS_NET after: $(docker network inspect "$OBS_NET" >/dev/null 2>&1 && echo kept || echo removed); vector: $(state vector)"
check "observability down exits 0" test "$rc" -eq 0
check "vector still ready" wait_ready vector
check "communications down exits 0" run_cs 13-down down
check "$OBS_NET removed once vector left" run_log 13-net-rm docker network rm "$OBS_NET"
echo "    item 7: communications down with Caddy attached exit $DOWN_RC; restart exit $RESTART_RC; observability down with vector attached exit $OBS_RC"

echo "[S] no lab value in any lab log"
for v in "${VALUES[@]}"; do
  check "$v in no log" absent_in "$v" "$LOGS"
done

echo "[LAB] PASS $PASS FAIL $FAIL (logs: $LOGS, removed with the volume)"
[ "$FAIL" -eq 0 ]
