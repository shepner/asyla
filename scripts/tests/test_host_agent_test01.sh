#!/bin/bash
# Proof of theOrg's host-agent bundle on test01 (asyla ticket #640; theOrg observability DEPLOY.md
# "Host agent", "Proving it"): with the bundle's host-vector, docker-state-exporter and node-exporter
# running from theOrg's published images, three lines each read back from Loki by `host`:
#   - journald:  logger on test01            -> {host="test01", source="journald"}
#   - container: a container on test01      -> {host="test01", source="docker"}
#   - UDP relay: logger --udp from SENDER    -> {host="<SENDER>", source="syslog_relay", relay="test01"}
# The third is the measurement theOrg could not make: on Linux, does a datagram sent to the
# relay's *published* UDP port reach Vector with the sender's own address? The relay keeps only
# listed addresses, so the line reads back under the sender's listed name only if it does. The
# relay's discarded count (vector_component_discarded_events_total, labelled_udp_relay) is printed
# before and after: a rise with the line missing means the port path rewrote the address.
#
# Which Loki. A throwaway one on test01: theOrg's observability-loki image (Loki 2.9.4), serving
# HTTPS itself with a one-day throwaway root and leaf, on the host network, listening on the address
# `host.docker.internal` resolves to in containers (docker0's) and nowhere else, its data on tmpfs.
# Not theOrg's loki-gateway: since theOrg f757911 the gateway reads its accounts and its TLS leaf
# from an OpenBao and a step-ca, which test01 does not have; its account enforcement is proved by
# theOrg's own `loki_clients.py verify`. Not d06's Loki: d06 runs without the gateway (theOrg's
# option A) and Loki is not reachable from off d06 (d06/apps/observability/README.md, "Off here").
# Loki here is single-tenant with no authentication; the agent still sends basic auth as its
# push account, with a random throwaway value made per run (the bundle requires the file).
# Checked on the workstation 2026-11-20 with upstream grafana/loki:2.9.4 and theOrg's
# loki-config-http.yaml (origin/main 97c16d1): these -server.* flags serve /ready over HTTPS with the
# leaf verified, a push carrying basic auth gets 204, and query_range reads the line back with gRPC
# on loopback only. Not yet run on test01.
#
# Usage, from the workstation, with the theorg-registry pull token in the environment (it goes to
# test01 on SSH stdin only, to a credential helper under a throwaway DOCKER_CONFIG; never argv,
# never a file):
#   cd ~/local/asyla && python3 core/tools/credentials.py exec THEORG_REGISTRY_PULL_TOKEN -- \
#     projects/asyla-hosts/scripts/tests/test_host_agent_test01.sh [--tag SHA] [--sender d03]
#
#   --tag SHA        theOrg observability commit whose images and compose files are used.
#                    Default: theOrg origin/main's head, read from the local clone after a fetch.
#                    Gitea keeps theOrg's images 7 days, so an older commit may be gone.
#   --sender HOST    the LAN host that sends the UDP line over SSH (default d03). A production host;
#                    it runs one `logger --udp` and nothing else.
#   --observability DIR   the local theOrg observability clone (default ~/local/theOrg/projects/observability).
#                    The two compose files are read from it at --tag (`git show`), not copied here.
#   --deadline S     seconds to wait for each read-back (default 180).
#
# Idempotent: it removes what an earlier run left before it starts, and tears down on exit, pass or
# fail (and on INT/TERM): the compose project `host-agent` with its volume, the Loki and echo
# containers, ~/host-agent-proof, and the images it pulled. It refuses to run anywhere but test01,
# and refuses to touch a `host-agent` project it did not make. test01's own node exporter (9100)
# is untouched: the bundle's node-exporter runs on 9101 for the proof. Exit 0 when all three
# lines read back, 1 otherwise; the summary at the end is what goes on the ticket and to theOrg.

set -uo pipefail

PROOF_DIR_NAME=host-agent-proof
LOKI_CTR=host-agent-proof-loki
ECHO_CTR=host-agent-proof-echo
LABEL=asyla.host-agent-proof
REG_HOST=gitea.asyla.org
REG="$REG_HOST/theorg"
ALPINE=alpine:3.20
FILES=(-f compose.host-agent.yml -f compose.host-agent.udp-relay.yml)

# ---------------------------------------------------------------------------------------------
# On test01
# ---------------------------------------------------------------------------------------------
if [ "${1:-}" = "--on-host" ]; then
  shift
  PROOF="$HOME/$PROOF_DIR_NAME"
  say() { echo "[test01] $*"; }
  die() { echo "[test01] ERROR: $*" >&2; exit 1; }
  [ "$(hostname -s)" = test01 ] || die "not test01: refusing"

  compose() { (cd "$PROOF" && docker compose --env-file host-agent.env "${FILES[@]}" "$@"); }

  # The compose project is ours only if this proof wrote its env file.
  project_containers() { docker ps -aq --filter label=com.docker.compose.project=host-agent; }

  teardown() {
    if [ -n "$(project_containers)" ] && [ ! -f "$PROOF/host-agent.env" ]; then
      die "a compose project 'host-agent' exists that this proof did not make: left as it is"
    fi
    [ -f "$PROOF/host-agent.env" ] && compose down -v --remove-orphans >/dev/null 2>&1
    docker rm -f "$LOKI_CTR" "$ECHO_CTR" >/dev/null 2>&1
    if [ -f "$PROOF/pulled-images" ]; then
      while read -r img; do
        [ -n "$img" ] && docker image rm "$img" >/dev/null 2>&1
      done < "$PROOF/pulled-images"
    fi
    rm -rf "$PROOF"
    left=$(docker ps -a --format '{{.Names}}' | grep -E '^(host-agent|host-agent-proof)' || true)
    vols=$(docker volume ls --format '{{.Name}}' | grep -E '^host-agent' || true)
    [ -z "$left$vols" ] || die "teardown left: $left $vols"
    say "teardown: nothing named host-agent* left; ~/$PROOF_DIR_NAME removed"
  }

  # The address containers reach as host.docker.internal (host-gateway): Loki listens there only.
  gateway_ip() { docker run --rm --add-host hg:host-gateway "$ALPINE" awk '$2 == "hg" { print $1; exit }' /etc/hosts; }

  # One LogQL query_range against the throwaway Loki, over HTTPS with its root.
  query() {
    curl -sS -m 10 -G --cacert "$PROOF/tls/root_ca.crt" --resolve "host.docker.internal:3100:$(cat "$PROOF/gateway-ip")" \
      --data-urlencode "query=$1" --data-urlencode since=30m --data-urlencode limit=50 \
      https://host.docker.internal:3100/loki/api/v1/query_range
  }
  # The log lines of a query_range answer, one per line.
  lines_of() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for s in d.get("data",{}).get("result",[]):
    for _,line in s.get("values",[]): print(line)' 2>/dev/null; }

  discarded() {
    curl -sS -m 5 http://127.0.0.1:9598/metrics 2>/dev/null \
      | awk '/^vector_component_discarded_events_total/ && /labelled_udp_relay/ { s += $NF } END { print s + 0 }'
  }

  wait_for() {   # wait_for SECONDS DESCRIPTION COMMAND...
    local until=$((SECONDS + $1)) what=$2; shift 2
    until "$@"; do
      [ "$SECONDS" -lt "$until" ] || { echo "[test01] timed out: $what" >&2; return 1; }
      sleep 3
    done
  }

  case "${1:-}" in
    setup)
      stage=$2 sender_name=$3 sender_ip=$4 tag=$5
      IFS= read -r PULL_TOKEN || true
      [[ "$PULL_TOKEN" =~ ^[A-Za-z0-9_.-]+$ ]] || die "no usable pull token on stdin"
      teardown

      busy=$(ss -Hltun | awk '{ print $1, $5 }' | grep -E '^(tcp .*:(3100|9096|9598|9099|9101)|udp .*:514)$' || true)
      [ -z "$busy" ] || die "port in use, stopping: $busy"

      if ls /var/log/journal/*/*.journal >/dev/null 2>&1; then jdir=/var/log/journal; else jdir=/run/log/journal; fi
      install -d -m 0700 "$PROOF" "$PROOF/tls"
      cp "$stage/compose.host-agent.yml" "$stage/compose.host-agent.udp-relay.yml" "$PROOF/"
      : > "$PROOF/pulled-images"

      docker image inspect "$ALPINE" >/dev/null 2>&1 || echo "$ALPINE" >> "$PROOF/pulled-images"
      docker pull -q "$ALPINE" >/dev/null || die "pull $ALPINE"
      gw=$(gateway_ip); [[ "$gw" =~ ^[0-9.]+$ ]] || die "host-gateway address not found"
      echo "$gw" > "$PROOF/gateway-ip"
      say "host.docker.internal is $gw in containers: Loki listens there only"

      # Throwaway root and leaf, one day; the root's key is deleted once the leaf is signed.
      k=$(mktemp -d)
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
        -keyout "$k/ca.key" -out "$PROOF/tls/root_ca.crt" -subj /CN=test01-host-agent-proof-root \
        -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null \
        && openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
          -keyout "$PROOF/tls/key.pem" -out "$k/leaf.csr" -subj /CN=host.docker.internal 2>/dev/null \
        && printf '%s\n' "subjectAltName=DNS:host.docker.internal,DNS:localhost,IP:$gw" 'basicConstraints=CA:FALSE' \
          'keyUsage=critical,digitalSignature' 'extendedKeyUsage=serverAuth' > "$k/leaf.ext" \
        && openssl x509 -req -in "$k/leaf.csr" -CA "$PROOF/tls/root_ca.crt" -CAkey "$k/ca.key" -CAcreateserial \
          -days 1 -extfile "$k/leaf.ext" -out "$PROOF/tls/cert.pem" 2>/dev/null
      rc=$?; rm -rf "$k"; [ "$rc" -eq 0 ] || die "certificate"
      chmod 0600 "$PROOF/tls/key.pem"; chmod 0644 "$PROOF/tls/cert.pem" "$PROOF/tls/root_ca.crt"

      # The agent's push password: random, made per run, guarding nothing (this Loki has no
      # authentication); the bundle requires the file. Never printed.
      (umask 077; openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 43 > "$PROOF/push-password")
      printf '%s\n' 'name,address' "$sender_name,$sender_ip" > "$PROOF/syslog-devices.csv"
      printf '%s\n' "REGISTRY=$REG" "TAG=$tag" HOST_NAME=test01 LOKI_ADDRESS=host.docker.internal:3100 \
        LOKI_PUSH_USER=host-agent-test01 "LOKI_PUSH_PASSWORD_FILE=$PROOF/push-password" \
        "LOKI_CA_FILE_HOST=$PROOF/tls/root_ca.crt" "SYSLOG_DEVICES_FILE_HOST=$PROOF/syslog-devices.csv" \
        "HOST_JOURNAL_DIR=$jdir" NODE_EXPORTER_PORT=9101 \
        HOST_VECTOR_METRICS_PORT=127.0.0.1:9598 DOCKER_STATE_EXPORTER_PORT=127.0.0.1:9099 > "$PROOF/host-agent.env"
      say "journal: $jdir; device list: $sender_name,$sender_ip"

      # Pulls under a throwaway DOCKER_CONFIG whose only entry is a credential helper answering
      # gitea.asyla.org from this process's environment: no login, nothing stored.
      cfg=$(mktemp -d)
      printf '%s\n' '#!/bin/bash' '[ "${1:-}" = get ] || exit 1' 'cat >/dev/null' \
        '[[ "${PROOF_PULL_TOKEN:-}" =~ ^[A-Za-z0-9_.-]+$ ]] || exit 1' \
        'printf "{\"ServerURL\":\"%s\",\"Username\":\"theorg-registry\",\"Secret\":\"%s\"}\n" gitea.asyla.org "$PROOF_PULL_TOKEN"' \
        > "$cfg/docker-credential-proof-env"
      chmod 0700 "$cfg/docker-credential-proof-env"
      printf '{"credHelpers":{"%s":"proof-env"}}\n' "$REG_HOST" > "$cfg/config.json"
      for img in "$REG/observability-loki:$tag" "$REG/observability-host-vector:$tag" \
                 "$REG/observability-docker-state-exporter:$tag" prom/node-exporter:v1.8.2; do
        docker image inspect "$img" >/dev/null 2>&1 || echo "$img" >> "$PROOF/pulled-images"
      done
      ( export DOCKER_CONFIG="$cfg" PATH="$cfg:$PATH" PROOF_PULL_TOKEN="$PULL_TOKEN"
        docker pull -q "$REG/observability-loki:$tag" >/dev/null && compose pull -q )
      rc=$?; rm -rf "$cfg"; unset PULL_TOKEN
      [ "$rc" -eq 0 ] || die "pull of theOrg's images at $tag failed (not published, pruned after 7 days, or no read access)"
      for img in "$REG/observability-loki:$tag" "$REG/observability-host-vector:$tag" \
                 "$REG/observability-docker-state-exporter:$tag" prom/node-exporter:v1.8.2; do
        say "image $(docker image inspect -f '{{index .RepoDigests 0}}' "$img")"
      done

      docker run -d --name "$LOKI_CTR" --label "$LABEL=1" --network host --cpus 1 --memory 512m \
        --tmpfs /loki:rw,size=512m,mode=1777 -v "$PROOF/tls:/etc/loki/proof-tls:ro" "$REG/observability-loki:$tag" \
        "-server.http-listen-address=$gw" -server.grpc-listen-address=127.0.0.1 \
        -server.http-tls-cert-path=/etc/loki/proof-tls/cert.pem \
        -server.http-tls-key-path=/etc/loki/proof-tls/key.pem >/dev/null || die "Loki did not start"
      loki_ready() { [ "$(curl -sS -m 5 --cacert "$PROOF/tls/root_ca.crt" --resolve "host.docker.internal:3100:$gw" \
        https://host.docker.internal:3100/ready 2>/dev/null)" = ready ]; }
      wait_for 120 "Loki /ready over HTTPS" loki_ready || { docker logs --tail 20 "$LOKI_CTR" >&2; exit 1; }
      say "Loki ready over HTTPS at host.docker.internal:3100 ($gw), leaf verified"

      compose up -d --no-build || die "compose up"
      healthy() { [ "$(docker inspect -f '{{.State.Health.Status}}' host-agent-host-vector-1 2>/dev/null)" = healthy ]; }
      wait_for 120 "host-vector healthy" healthy || { docker logs --tail 30 host-agent-host-vector-1 >&2; exit 1; }
      compose ps --format '{{.Service}} {{.State}} {{.Status}}' | sed 's/^/[test01] service /'

      # The journal source starts at the journal's end on its first start: wait until a warm-up
      # line reads back, so the proof's own line is planted after the source is live.
      i=0
      journal_live() { i=$((i + 1)); logger -t host-agent-proof "host-agent-proof warm-up $i"
        query '{host="test01",source="journald"} |= "host-agent-proof warm-up"' | lines_of | grep -q .; }
      wait_for 150 "journald source live" journal_live || exit 1
      say "journald source live after $i warm-up lines"
      discarded > "$PROOF/discarded-before"
      say "labelled_udp_relay discarded before: $(cat "$PROOF/discarded-before")"
      ;;

    plant)
      nonce=$2
      logger -t host-agent-proof "host-agent-proof journald $nonce"
      docker run -d --name "$ECHO_CTR" --label "$LABEL=1" "$ALPINE" \
        sh -c "sleep 5; echo 'host-agent-proof container $nonce'; sleep 600" >/dev/null || die "echo container"
      say "planted the journald and container lines ($nonce)"
      ;;

    readback)
      nonce=$2 sender_name=$3 deadline=$4
      # Loki's own container logs every query with its text, nonce included, and the docker source
      # ships that too: the container selector leaves Loki's lines (caller=...) out, or its query
      # log reads back as the echo line (seen in the first run, 2026-11-20T17:44Z).
      declare -A sel=(
        [journald]="{host=\"test01\",source=\"journald\"} |= \"host-agent-proof journald $nonce\""
        [container]="{host=\"test01\",source=\"docker\"} |= \"host-agent-proof container $nonce\" != \"caller=\""
        [udp]="{host=\"$sender_name\",source=\"syslog_relay\",relay=\"test01\"} |= \"host-agent-proof udp $nonce\""
      )
      declare -A got=()
      until=$((SECONDS + deadline))
      while :; do
        for k in journald container udp; do
          [ -n "${got[$k]:-}" ] && continue
          line=$(query "${sel[$k]}" | lines_of | head -1)
          [ -n "$line" ] && got[$k]=$line
        done
        [ "${#got[@]}" -eq 3 ] || [ "$SECONDS" -ge "$until" ] && break
        sleep 5
      done
      fails=0
      for k in journald container udp; do
        if [ -n "${got[$k]:-}" ]; then echo "[PASS] $k: ${sel[$k]%% |=*} read back: ${got[$k]}"
        else echo "[FAIL] $k: ${sel[$k]%% |=*} not read back within ${deadline}s"; fails=$((fails + 1)); fi
      done
      before=$(cat "$PROOF/discarded-before" 2>/dev/null || echo 0) after=$(discarded)
      say "labelled_udp_relay discarded after: $after (before: $before)"
      if [ -n "${got[udp]:-}" ]; then
        say "source address: KEPT (the datagram to the published UDP port read back under the sender's listed name)"
      elif [ "${after%.*}" -gt "${before%.*}" ]; then
        say "source address: REWRITTEN (line missing, discarded count rose): DEPLOY.md's fallback is host networking for host-vector"
      else
        say "source address: NOT MEASURED (line missing and nothing discarded: the datagram did not reach Vector)"
      fi
      errs=$(docker logs host-agent-host-vector-1 2>&1 | grep -c ERROR || true)
      say "host-vector ERROR lines: $errs"
      [ "$errs" -eq 0 ] || docker logs host-agent-host-vector-1 2>&1 | grep ERROR | tail -10 | sed 's/^/[test01]   /'
      [ "$fails" -eq 0 ]
      ;;

    teardown)
      stage=${2:-}
      teardown
      [ -n "$stage" ] && [[ "$stage" == /tmp/host-agent-proof-stage.* ]] && rm -rf "$stage"
      ;;
    *) die "unknown step ${1:-}" ;;
  esac
  exit
fi

# ---------------------------------------------------------------------------------------------
# On the workstation
# ---------------------------------------------------------------------------------------------
OBS="$HOME/local/theOrg/projects/observability"
TAG="" SENDER=d03 DEADLINE=180
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG=$2; shift 2 ;;
    --sender) SENDER=$2; shift 2 ;;
    --observability) OBS=$2; shift 2 ;;
    --deadline) DEADLINE=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$SENDER" =~ ^[a-z0-9-]+$ ]] && [ "$SENDER" != test01 ] || { echo "--sender must be another LAN host" >&2; exit 2; }
[[ "$DEADLINE" =~ ^[0-9]+$ ]] || { echo "--deadline takes seconds" >&2; exit 2; }
[[ "${THEORG_REGISTRY_PULL_TOKEN:-}" =~ ^[A-Za-z0-9_.-]+$ ]] || {
  echo "THEORG_REGISTRY_PULL_TOKEN is not in the environment: run under credentials.py exec (see the header)" >&2; exit 2; }

ssh_to() { local h=$1; shift; ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$HOME/.ssh/docker_rsa" "docker@$h" "$@"; }
T01() { ssh_to test01 "$@"; }

git -C "$OBS" fetch -q origin || { echo "fetch of theOrg observability failed ($OBS)" >&2; exit 1; }
[ -n "$TAG" ] || TAG=$(git -C "$OBS" rev-parse origin/main)
[[ "$TAG" =~ ^[0-9a-f]{40}$ ]] || { echo "--tag must be a full commit sha" >&2; exit 2; }
echo "== theOrg observability $TAG ($(git -C "$OBS" log -1 --format=%cI "$TAG"))"

STAGE_LOCAL=$(mktemp -d)
for f in compose.host-agent.yml compose.host-agent.udp-relay.yml; do
  git -C "$OBS" show "$TAG:$f" > "$STAGE_LOCAL/$f" || { echo "$f not at $TAG" >&2; exit 1; }
done
cp "${BASH_SOURCE[0]}" "$STAGE_LOCAL/proof.sh"

T01_IP=$(T01 'hostname -I | cut -d" " -f1') || { echo "test01 not reached" >&2; exit 1; }
SENDER_IP=$(ssh_to "$SENDER" "ip -4 route get $T01_IP" | sed -n 's/.* src \([0-9.]*\).*/\1/p')
[[ "$SENDER_IP" =~ ^[0-9.]+$ ]] || { echo "$SENDER's source address towards $T01_IP not found" >&2; exit 1; }
echo "== test01 $T01_IP; UDP sender $SENDER $SENDER_IP"

STAGE=$(tar -czf - -C "$STAGE_LOCAL" . | T01 '[ "$(hostname -s)" = test01 ] || exit 2
  d=$(mktemp -d /tmp/host-agent-proof-stage.XXXXXX) && tar -xzf - -C "$d" && echo "$d"') \
  || { echo "staging on test01 failed" >&2; exit 1; }
rm -rf "$STAGE_LOCAL"

done_teardown=""
finish() {
  [ -n "$done_teardown" ] && return; done_teardown=1
  echo "== teardown"
  T01 "bash $STAGE/proof.sh --on-host teardown $STAGE"
}
trap finish EXIT
trap 'exit 130' INT TERM

echo "== setup"
printf '%s\n' "$THEORG_REGISTRY_PULL_TOKEN" | T01 "bash $STAGE/proof.sh --on-host setup $STAGE $SENDER $SENDER_IP $TAG" || exit 1

NONCE="$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM$RANDOM"
echo "== plant ($NONCE)"
T01 "bash $STAGE/proof.sh --on-host plant $NONCE" || exit 1
ssh_to "$SENDER" "logger --udp --rfc5424 -n $T01_IP -P 514 -t host-agent-proof 'host-agent-proof udp $NONCE'" || exit 1
echo "[$SENDER] sent one UDP syslog line to $T01_IP:514"

echo "== read back (up to ${DEADLINE}s)"
T01 "bash $STAGE/proof.sh --on-host readback $NONCE $SENDER $DEADLINE"
rc=$?
echo "== result: $([ $rc -eq 0 ] && echo PASS || echo FAIL), theOrg observability $TAG, $(date -u +%FT%TZ)"
exit $rc
