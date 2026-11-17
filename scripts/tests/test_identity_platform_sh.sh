#!/bin/bash
# d05/apps/identity-platform/identity-platform.sh against stubs (docker, hostname): M1 only. up creates
# the two networks once (edge with --internal) and refuses one whose IPAM differs at all; up starts keycloak-db
# alone, never openldap, keycloak or an ops one-shot, and never creates openldap's data dirs;
# start-openldap, start-keycloak and restore refuse; a root CA copy with another fingerprint is
# refused; a missing openldap-tls leaf is reported, not fatal; the replica mode (a host not named
# d05: a throwaway keycloak-db password) and images (build_host.py's replica guard); usage only for
# an unknown switch. Plus compose.yml's rules (networks external, secrets by name only, the restored
# profile, keycloak's address, no ports, its proxy, theOrg's digests; the default services from a
# real `docker compose config` when docker is here) and the pull through the credential helper.
# The openldap leaf: leaf-issue reads the provisioner password as one line on its stdin and writes
# it to openldap-leaf.sh issue's stdin alone (never in an environment, an argv, the output or a
# file; the real copy hands it to docker run -i on stdin, no -e); it refuses (exit 3, no docker call,
# no status write) with LDAP_PROVISIONER_PASSWORD set in its environment, a terminal on stdin, an
# empty read, or another switch beside it, and on a replica. up never issues, leaf-renew takes no
# secret, and the renew schedule is installed only by leaf-schedule-install (never by up).
# openldap-leaf.sh is the README's provenance blob.
# fetch-bundle (the M5 cutover bundle) reads the theorg-registry pull token as one line on stdin: it
# reaches curl on its config stdin (-K -) alone, and the cutover image's docker pull (only when the
# image is missing) through the credential helper; refused (exit 3, no call, nothing written) with
# either pull-token name in its environment, a terminal, an empty read or a value outside
# [A-Za-z0-9_.-], over an existing bundle or unpacked marker, or beside another switch; exit 2 for
# a bad VERSION; also under xtrace (SHELLOPTS and bash -x). curl is a stub.
# Nothing here reaches a registry, the vault or a host; every value is a plain stand-in word made
# at run time. Run: bash scripts/tests/test_identity_platform_sh.sh
set -uo pipefail
unset IDP_KEYCLOAK_DB_PASSWORD IDP_LDAP_ADMIN_PASSWORD IDP_DEPLOY_DEX_CLIENT_SECRET \
  IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN IDENTITY_PLATFORM_TAG_OVERRIDE STUB_MISSING STUB_DB_RUNNING \
  STUB_HOST STUB_PW_FILE LDAP_PROVISIONER_PASSWORD STUB_LEAF_RC STUB_LEAF_PW_FILE STUB_RUN_PW_FILE \
  IDENTITY_PLATFORM_SYSTEMD_DIR

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO/d05/apps/identity-platform"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }

mkdir -p "$T/home/scripts/docker" "$T/bin" "$T/app" "$T/dl" "$T/net" "$T/systemd"
printf 'DOCKER_DL=%s\n' "$T/dl" > "$T/home/scripts/docker/common.env"
cp "$SRC"/{compose.yml,identity-platform.sh,docker-credential-identity-platform-env,theorg-v2-root.crt} "$T/app/"
cp "$SRC"/identity-platform-leaf-renew.{service,timer} "$T/app/"
# openldap-leaf.sh in the app copy is a stub that logs its argv and whether LDAP_PROVISIONER_PASSWORD
# is in its environment (never a value); for issue it reads one line on stdin, as the real one does,
# and with STUB_LEAF_PW_FILE keeps that line there (a temp file read only by the checks); exit
# STUB_LEAF_RC. The real copy is swapped in for its own checks below.
cat > "$T/leaf-stub.sh" <<'EOF'
#!/bin/bash
echo "LEAF $* pw=${LDAP_PROVISIONER_PASSWORD+set}" >> "$STUB_LOG"
if [ "$1" = issue ]; then
  line=""
  IFS= read -r line || true
  [ -z "${STUB_LEAF_PW_FILE:-}" ] || printf '%s' "$line" > "$STUB_LEAF_PW_FILE"
fi
exit "${STUB_LEAF_RC:-0}"
EOF
chmod +x "$T/leaf-stub.sh"
cp "$T/leaf-stub.sh" "$T/app/openldap-leaf.sh"
ROOT="$T/dl/IdentityPlatform"
DB_NAME="IDP_KEYCLOAK_DB_PASSWORD"
PULL_NAME="IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN"

# docker: logs every call (paths shortened). Networks live as files in $STUB_NET: `network create`
# writes "DRIVER INTERNAL SUBNET GATEWAY IPRANGE" from its arguments, as Docker's inspect format
# prints it ("invalid Prefix" for no ip-range, as Docker 29 does; a gateway left to Docker reads auto-gateway, so the script must
# name its own); `network inspect` of a missing one fails. `config --images` lists both stand-in
# images with a --profile, keycloak-db's alone without. Like compose, a compose call fails when a
# `${...:?}` compose.yml uses is empty. `image inspect` says present unless STUB_MISSING; a pull
# logs its DOCKER_CONFIG and asks the credential helper there, as Docker would. `compose ... up`
# logs whether POSTGRES_PASSWORD and the LDAP names are set (never a value); with STUB_PW_FILE it
# also keeps POSTGRES_PASSWORD there (a temp file, read only by the replica checks, never printed).
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" | sed -E "s#-f [^ ]*/compose.yml#-f compose.yml#; s# --project-directory [^ ]*##" >> "$STUB_LOG"
[ -z "${LDAP_PROVISIONER_PASSWORD+x}" ] || echo "ENVPW $1 $2" >> "$STUB_LOG"
if [ "$1" = compose ]; then
  for v in IDENTITY_PLATFORM_ROOT IDENTITY_PLATFORM_TAG; do
    [ -n "${!v:-}" ] || { echo "required variable $v is missing a value" >&2; echo "INTERPOLATION $v" >> "$STUB_LOG"; exit 1; }
  done
  echo "TAG $IDENTITY_PLATFORM_TAG" >> "$STUB_LOG"
fi
if [ "$1 $2" = "network inspect" ]; then
  name="${!#}"
  [ -f "$STUB_NET/$name" ] || { echo "Error: network $name not found" >&2; exit 1; }
  cat "$STUB_NET/$name"; exit 0
fi
if [ "$1 $2" = "network create" ]; then
  shift 2
  drv=bridge internal=false subnet="" gw="" range=""
  while [ $# -gt 1 ]; do
    case "$1" in
      --driver) drv="$2"; shift 2 ;;
      --internal) internal=true; shift ;;
      --subnet) subnet="$2"; shift 2 ;;
      --gateway) gw="$2"; shift 2 ;;
      --ip-range) range="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$gw" ] || gw="auto-gateway"
  [ -n "$range" ] || range="invalid Prefix"   # what Docker 29 prints for no ip-range (d05, ws01)
  echo "$drv $internal $subnet $gw $range" > "$STUB_NET/$1"; echo "netid-$1"; exit 0
fi
case "$*" in
  # openldap-leaf.sh's one-offs (the real copy): no swap marker, no valid leaf, the issue succeeds.
  "run "*"test -e"*) exit 1 ;;
  "run "*"certificate verify"*) exit 1 ;;
  "run "*"bash -c"*)
    echo "RUNENV ${LDAP_PROVISIONER_PASSWORD+set}" >> "$STUB_LOG"
    if [ -n "${STUB_RUN_PW_FILE:-}" ]; then cat > "$STUB_RUN_PW_FILE"; else cat > /dev/null; fi ;;
  "ps -q --filter"*) ;;
  *"--profile"*"config --images"*) printf 'postgres:16@sha256:aa\ngitea.asyla.org/theorg/identity-platform-openldap:%s\n' "$IDENTITY_PLATFORM_TAG" ;;
  *"config --images"*) echo 'postgres:16@sha256:aa' ;;
  "image inspect "*cutover-bundle*)
    echo "INSPECTENV ${IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN+set}" >> "$STUB_LOG"
    [ -z "${STUB_CUT_MISSING:-}" ]; exit ;;
  "image inspect"*) [ -z "${STUB_MISSING:-}" ]; exit ;;
  # The cutover image's pull (fetch-bundle), through the credential helper as compose's pulls.
  "pull "*)
    echo "PULLCFG $(cat "$DOCKER_CONFIG/config.json" 2>/dev/null)" >> "$STUB_LOG"
    printf 'gitea.asyla.org' | docker-credential-identity-platform-env get | grep -q '"Username":"theorg-registry"' \
      && echo "HELPER_OK" >> "$STUB_LOG"
    exit "${STUB_PULL_RC:-0}" ;;
  # unpack (unpack-bundle): the identity line from stdin into STUB_ID_FILE (a temp file read only by
  # the checks); STUB_UNPACK_RC 0 writes both STATUS files and prints the four lines (from its own
  # ARGs, or STUB_UNPACK_OUT), 1 or 4 leaves a file without STATUS, 2 or 3 writes nothing.
  "run "*cutover-bundle*" unpack "*)
    echo "UNPACKENV ${IDP_CUTOVER_BUNDLE_IDENTITY+set}" >> "$STUB_LOG"
    if [ -n "${STUB_ID_FILE:-}" ]; then cat > "$STUB_ID_FILE"; else cat > /dev/null; fi
    m="" k="" o=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --expect-manifests-sha256) m="$2" ;; --expect-keycloak-summary) k="$2" ;; --expect-openldap-summary) o="$2" ;;
      esac
      shift
    done
    case "${STUB_UNPACK_RC:-0}" in
      0) echo OK > "$IDENTITY_PLATFORM_ROOT/backup/STATUS"; echo OK > "$IDENTITY_PLATFORM_ROOT/openldap-backup/STATUS"
         if [ -n "${STUB_UNPACK_OUT:-}" ]; then printf '%s\n' "$STUB_UNPACK_OUT"
         else printf 'version m5-%s\nmanifests-sha256 %s\nkeycloak-summary-sha256 %s\nopenldap-summary-sha256 %s\n' "${m:0:12}" "$m" "$k" "$o"; fi ;;
      1|4) echo partial > "$IDENTITY_PLATFORM_ROOT/backup/summary.txt" ;;
    esac
    exit "${STUB_UNPACK_RC:-0}" ;;
  # reset-cutover's find in the image: run here on the mounted dir.
  "run "*"--entrypoint find"*)
    d=""; for a in "$@"; do case "$a" in *:/t) d="${a%:/t}" ;; esac; done
    find "$d" -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf -- {} + ;;
  *"ps -a -q openldap keycloak"*)
    [ -z "${STUB_PS_FAIL:-}" ] || exit 1
    [ -z "${STUB_RESTORED_CT:-}" ] || echo ctid ;;
  *" pull"*)
    echo "PULLCFG $(cat "$DOCKER_CONFIG/config.json" 2>/dev/null)" >> "$STUB_LOG"
    printf 'gitea.asyla.org' | docker-credential-identity-platform-env get | grep -q '"Username":"theorg-registry"' \
      && echo "HELPER_OK" >> "$STUB_LOG" ;;
  *" up "*)
    for v in POSTGRES_PASSWORD KC_DB_PASSWORD LDAP_ADMIN_PASSWORD VAULT_DEX_CLIENT_SECRET; do
      [ -n "${!v:-}" ] && echo "SET $v" >> "$STUB_LOG"
    done
    [ -z "${STUB_PW_FILE:-}" ] || printf '%s' "${POSTGRES_PASSWORD:-}" > "$STUB_PW_FILE" ;;
  *"ps -q keycloak-db"*) if [ -n "${STUB_DB_RUNNING:-}" ]; then echo dbid; fi ;;
  "inspect "*) echo "${STUB_DB_HEALTH:-healthy}" ;;
esac
exit 0
EOF
cat > "$T/bin/hostname" <<'EOF'
#!/bin/bash
[ "$1" = -s ] && echo "$STUB_HOST"
EOF
# sudo runs its command (install writes under $IDENTITY_PLATFORM_SYSTEMD_DIR, a temp dir) after
# logging it; systemctl only logs; flock (util-linux, not on macOS) takes any lock.
cat > "$T/bin/sudo" <<'EOF'
#!/bin/bash
echo "sudo $*" >> "$STUB_LOG"
exec "$@"
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$STUB_LOG"
case "$1" in is-enabled|is-active) exit 1 ;; esac
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/bin/flock"
# curl (fetch-bundle's download): logs its argv and which pull-token names are in its environment
# (never a value), dumps its environment to STUB_CURL_ENV, keeps its `-K -` config (its stdin) in
# STUB_CURL_CFG (a temp file read only by the checks), writes a fixed stand-in body to its -o path
# and exits STUB_CURL_RC (the body written even then: a partial download).
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$STUB_LOG"
echo "CURLENV ${IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN+set}${THEORG_REGISTRY_PULL_TOKEN+set}" >> "$STUB_LOG"
[ -z "${STUB_CURL_ENV:-}" ] || env >> "$STUB_CURL_ENV"
if [ -n "${STUB_CURL_CFG:-}" ]; then cat > "$STUB_CURL_CFG"; else cat > /dev/null; fi
o=""
while [ $# -gt 0 ]; do [ "$1" != -o ] || o="${2:-}"; shift; done
[ -z "$o" ] || printf 'stand-in bundle body\n' > "$o"
exit "${STUB_CURL_RC:-0}"
EOF
chmod +x "$T/bin/docker" "$T/bin/hostname" "$T/bin/sudo" "$T/bin/systemctl" "$T/bin/flock" "$T/bin/curl"
# bash skips a file on PATH it cannot run (a noexec temp dir) and takes the next one: the real
# docker would then act on this machine. Refuse to run then.
for s in docker hostname sudo systemctl flock curl; do
  [ "$(PATH="$T/bin:$PATH" command -v "$s")" = "$T/bin/$s" ] || { echo "stub $s not runnable in $T/bin" >&2; exit 2; }
done

run() {   # run SWITCH...: output in $OUT, docker calls in $T/log, status returned; on d05 unless STUB_HOST
  : > "$T/log"
  local set=() n rc
  for n in ${STUB_SET:-}; do set+=("$n=stand-in"); done
  OUT="$(env ${set[@]+"${set[@]}"} HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_NET="$T/net" STUB_HOST="${STUB_HOST:-d05}" \
    IDENTITY_PLATFORM_DB_WAIT_S=120 IDENTITY_PLATFORM_SYSTEMD_DIR="$T/systemd" bash "$T/app/identity-platform.sh" "$@" 2>&1)"
  rc=$?
  return "$rc"
}
reset_host() { rm -rf "$T/net"/* "$T/dl"/* "$T/systemd"/*; }
NET_OK="bridge false 10.213.5.64/26 10.213.5.65 -"
NET_RAW="bridge false 10.213.5.64/26 10.213.5.65 invalid Prefix"   # as Docker 29 stores it
EDGE_OK="bridge true 10.213.5.0/29 10.213.5.1 10.213.5.4/30"

# --- compose.yml's rules (static) ---
C="$T/compose.nocomments.yml"   # compose.yml without its comment lines (its header quotes the example)
grep -vE '^[[:space:]]*#' "$SRC/compose.yml" > "$C"
for n in identity-platform-net identity-platform-edge; do
  awk -v n="$n" '/^networks:/ {s=1} s && $0 ~ "^  "n":" {f=1; next} f && /^  [^ ]/ {f=0} f && /external: true/ {e=1} END {exit !e}' "$C" \
    && ok "compose.yml: $n is external" || bad "compose.yml: $n external"
done
! grep -qE '\$\{[A-Z_]*(PASSWORD|SECRET|TOKEN)[A-Z_]*' "$C" \
  && ok "compose.yml: no secret is interpolated (an M1 compose call needs none)" || bad "compose.yml interpolates a secret" "$(grep -nE '\$\{[A-Z_]*(PASSWORD|SECRET|TOKEN)' "$C")"
for n in LDAP_ADMIN_PASSWORD LDAP_CONFIG_PASSWORD POSTGRES_PASSWORD KC_DB_PASSWORD PGPASSWORD VAULT_DEX_CLIENT_SECRET; do
  grep -qE "^      - $n\$" "$C" && ok "compose.yml: $n by name only" || bad "compose.yml: $n not by name"
done
! grep -q 'KC_BOOTSTRAP_ADMIN' "$C" && ok "compose.yml: no KC_BOOTSTRAP_ADMIN_*" || bad "KC_BOOTSTRAP_ADMIN present"
for s in keycloak openldap; do
  awk -v s="$s" '$0 ~ "^  "s":$" {f=1; next} f && /^  [^ ]/ {f=0} f && /profiles: \[restored\]/ {p=1} END {exit !p}' "$C" \
    && ok "compose.yml: $s is in the restored profile (theOrg's name since 47f65add)" || bad "compose.yml: $s profile"
done
! grep -q 'cutover' "$C" && ! grep -qE -- '--profile cutover' "$SRC/identity-platform.sh" \
  && ok "no profile named cutover is left in compose.yml or identity-platform.sh" || bad "a cutover profile is left"
! grep -qE '^[^#]*COMPOSE_PROFILES=' "$SRC/identity-platform.sh" \
  && ok "identity-platform.sh never sets COMPOSE_PROFILES (M1 starts neither restored service)" || bad "COMPOSE_PROFILES set"

fp_compose="$(sed -nE 's/^ *- KEYCLOAK_CA_FINGERPRINT=//p' "$C")"
fp_script="$(sed -nE 's/^CA_FINGERPRINT="(.*)"$/\1/p' "$SRC/identity-platform.sh")"
[ -n "$fp_compose" ] && [ "$fp_compose" = "$fp_script" ] \
  && ok "KEYCLOAK_CA_FINGERPRINT in compose.yml equals the script's check" || bad "fingerprints differ" "[$fp_compose] [$fp_script]"
svc() { awk -v s="$1" '$0 ~ "^  "s":$" {f=1; next} f && /^  [^ ]/ {f=0} f' "$C"; }   # one service's lines
KC="$(svc keycloak)" DB="$(svc keycloak-db)"
[ -n "$KC" ] && [ -n "$DB" ] || bad "compose.yml: keycloak or keycloak-db not found"
awk '/^      identity-platform-edge:$/ {getline; if ($0 ~ /^        ipv4_address: 10\.213\.5\.3$/) e=1} END {exit !e}' <<< "$KC" \
  && ok "compose.yml: keycloak at 10.213.5.3 on identity-platform-edge" || bad "compose.yml: keycloak edge address" "$KC"
! grep -qE '^    ports:' <<< "$KC" && ok "compose.yml: keycloak publishes no port" || bad "compose.yml: keycloak has ports"
grep -qxF '      - KC_PROXY_TRUSTED_ADDRESSES=10.213.5.2' <<< "$KC" \
  && ok "compose.yml: KC_PROXY_TRUSTED_ADDRESSES=10.213.5.2 (Caddy alone)" || bad "compose.yml: KC_PROXY_TRUSTED_ADDRESSES"
# theOrg identity-platform deploy/d05/compose.example.yml, read 2026-11-14 (git show): the same at
# 701e893, 47f65add and fcbed3fe.
KC_IMAGE="quay.io/keycloak/keycloak:26.8.2@sha256:3879c623248408de29a5303178b5816c77e8dfef3890c361f8c0bbeaa979ba3b"
DB_IMAGE="postgres:16.14-bookworm@sha256:64154d0babcb1741988719e703419af0382b19953706149f9872fbd0f438efa8"
[ "$(grep -E '^    image:' <<< "$KC")" = "    image: $KC_IMAGE" ] \
  && ok "compose.yml: keycloak's image is fcbed3fe's digest" || bad "compose.yml: keycloak image" "$(grep -E '^    image:' <<< "$KC")"
[ "$(grep -E '^    image:' <<< "$DB")" = "    image: $DB_IMAGE" ] \
  && ok "compose.yml: keycloak-db's image is fcbed3fe's digest" || bad "compose.yml: keycloak-db image" "$(grep -E '^    image:' <<< "$DB")"
! grep -q 'profiles:' <<< "$DB" && ok "compose.yml: keycloak-db has no profile (the one M1 service)" || bad "compose.yml: keycloak-db has a profile"
# The real compose, when docker is here: no daemon is asked (config only), every value a stand-in.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  cfg() { env -u DOCKER_HOST -u DOCKER_CONTEXT -u COMPOSE_PROFILES -u COMPOSE_FILE -u LDAP_ADMIN_PASSWORD \
    IDENTITY_PLATFORM_ROOT="$T/cfg-root" IDENTITY_PLATFORM_TAG=standin-tag \
    docker compose -f "$T/app/compose.yml" --project-directory "$T/app" "$@" config --services 2>&1 | sort | tr '\n' ' '; }
  got="$(cfg)"
  [ "$got" = "keycloak-db " ] && ok "docker compose config: keycloak-db is the only service without a profile" || bad "compose config default services" "[$got]"
  got="$(cfg --profile restored)"
  [ "$got" = "keycloak keycloak-db openldap " ] && ok "docker compose config: restored adds keycloak and openldap only" || bad "compose config restored" "[$got]"
else
  echo "skip docker compose config (no docker compose here)"
fi

# --- up: networks, idempotent, edge internal ---
reset_host
STUB_SET="$DB_NAME" run up; rc=$?
creates="$(grep -c '^docker network create' "$T/log")"
grep -qE '^docker network create .*--internal .*identity-platform-edge$' "$T/log"; edge_int=$?
grep -E '^docker network create .*identity-platform-net$' "$T/log" | grep -q -- '--internal'; net_int=$?
[ "$rc" -eq 0 ] && [ "$creates" -eq 2 ] && [ "$edge_int" -eq 0 ] && [ "$net_int" -ne 0 ] \
  && [ "$(cat "$T/net/identity-platform-edge")" = "$EDGE_OK" ] \
  && [ "$(cat "$T/net/identity-platform-net")" = "$NET_RAW" ] \
  && ok "up on a fresh host: creates both networks, edge with --internal, net without" \
  || bad "up creates networks" "rc=$rc creates=$creates; $OUT; $(cat "$T/log")"
STUB_SET="$DB_NAME" run up; rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^docker network create' "$T/log" \
  && ok "up again: both networks exist, nothing created (idempotent)" || bad "up idempotent" "rc=$rc; $(cat "$T/log")"
echo "bridge false 10.213.5.0/29 10.213.5.1 10.213.5.4/30" > "$T/net/identity-platform-edge"
STUB_SET="$DB_NAME" run up; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'identity-platform-edge is "bridge false' && ! grep -qE ' up |network (create|rm)' "$T/log" \
  && ok "up with an edge network that is not internal: refused, nothing changed or started" || bad "edge not internal" "rc=$rc; $OUT; $(cat "$T/log")"
echo "$EDGE_OK fd00:5::/64 fd00:5::1 -" > "$T/net/identity-platform-edge"
STUB_SET="$DB_NAME" run up; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'identity-platform-edge is ' && ! grep -qE ' up |network (create|rm)' "$T/log" \
  && ok "up with an extra IPAM entry on edge: refused" || bad "edge extra IPAM" "rc=$rc; $OUT"
# identity-platform-net drift: each refused, nothing changed or started, and verify fails too.
while IFS='|' read -r label state; do
  reset_host
  echo "$EDGE_OK" > "$T/net/identity-platform-edge"
  echo "$state" > "$T/net/identity-platform-net"
  STUB_SET="$DB_NAME" run up; rc=$?
  [ "$rc" -ne 0 ] && echo "$OUT" | grep -q "identity-platform-net is \"$state\"" && ! grep -qE ' up |network (create|rm)' "$T/log" \
    && ok "up with identity-platform-net $label: refused, nothing changed or started" || bad "net $label" "rc=$rc; $OUT; $(cat "$T/log")"
  STUB_DB_RUNNING=1 run verify; rc=$?
  [ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'ERROR\] network identity-platform-net is' \
    && ok "verify with identity-platform-net $label: fails" || bad "verify net $label" "rc=$rc; $OUT"
done <<EOF
with another gateway|bridge false 10.213.5.64/26 10.213.5.66 -
with an extra IPAM entry|$NET_OK fd00:5::/64 fd00:5::1 -
with an ip-range|bridge false 10.213.5.64/26 10.213.5.65 10.213.5.96/27
with another subnet|bridge false 10.213.6.64/26 10.213.6.65 -
internal|bridge true 10.213.5.64/26 10.213.5.65 -
EOF

# --- up: keycloak-db alone ---
reset_host
STUB_SET="$DB_NAME" run up; rc=$?
starts="$(grep -E '^docker compose .* (up|run|start|create)( |$)' "$T/log" | sed -E 's/^docker compose -f compose.yml //')"
[ "$rc" -eq 0 ] && [ "$starts" = "up -d --no-deps --wait --wait-timeout 120 keycloak-db" ] \
  && ok "up starts keycloak-db alone (--no-deps), waiting until healthy" || bad "up start calls" "rc=$rc; [$starts]"
! grep -E '^docker compose .* (up|run|start)( |$)' "$T/log" | grep -qE 'openldap|keycloak( |$)|keycloak-(backup|configure)|--profile' \
  && ok "up never starts openldap, keycloak or an ops one-shot" || bad "up started more" "$(cat "$T/log")"
grep -q '^SET POSTGRES_PASSWORD' "$T/log" && grep -q '^SET KC_DB_PASSWORD' "$T/log" \
  && ! grep -qE '^SET (LDAP_ADMIN_PASSWORD|VAULT_DEX_CLIENT_SECRET)' "$T/log" \
  && ok "up maps IDP_KEYCLOAK_DB_PASSWORD onto the compose names; unset optional names stay unset" || bad "secret mapping" "$(grep '^SET' "$T/log")"
STUB_SET="$DB_NAME IDP_LDAP_ADMIN_PASSWORD IDP_DEPLOY_DEX_CLIENT_SECRET" run up; rc=$?
[ "$rc" -eq 0 ] && grep -q '^SET LDAP_ADMIN_PASSWORD' "$T/log" && grep -q '^SET VAULT_DEX_CLIENT_SECRET' "$T/log" \
  && ok "up maps the optional LDAP and Dex values when they are sent" || bad "optional mapping" "rc=$rc; $(grep '^SET' "$T/log")"
[ ! -e "$ROOT/openldap-data" ] && [ ! -e "$ROOT/openldap-config" ] && [ -d "$ROOT/keycloak-db" ] \
  && ok "up creates keycloak-db's dir, never openldap-data or openldap-config" || bad "up dirs" "$(ls "$ROOT")"
cmp -s "$SRC/theorg-v2-root.crt" "$ROOT/ca/root_ca.crt" && echo "$OUT" | grep -q 'theOrg-v2 Root CA, SHA-256 CD:39' \
  && ok "up places theOrg's root CA at ca/root_ca.crt, fingerprint checked" || bad "CA placed" "$OUT"
echo "$OUT" | grep -q "^\[ERROR\]\|password\|stand-in" && bad "up output names a value or an error" "$OUT" || ok "up output names no value"

# --- up without keycloak-db's value: refused before any docker call ---
reset_host
run up; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'IDP_KEYCLOAK_DB_PASSWORD is not in' && [ ! -s "$T/log" ] \
  && ok "up without IDP_KEYCLOAK_DB_PASSWORD: refused before any docker call" || bad "up without db value" "rc=$rc; $OUT; $(cat "$T/log")"
run no-such-switch; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'unknown switch: no-such-switch' && echo "$OUT" | grep -q 'Usage:' && [ ! -s "$T/log" ] \
  && ok "an unknown switch: usage, exit $rc, no docker call" || bad "unknown switch" "rc=$rc; $OUT"
run; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'Usage:' && ok "no switch: usage" || bad "no switch" "rc=$rc; $OUT"

# --- replica (a host not named d05): a throwaway keycloak-db password, keycloak-db alone ---
reset_host
STUB_HOST=test01 STUB_PW_FILE="$T/pw1" run up; rc=$?
starts="$(grep -E '^docker compose .* (up|run|start|create)( |$)' "$T/log" | sed -E 's/^docker compose -f compose.yml //')"
[ "$rc" -eq 0 ] && [ "$starts" = "up -d --no-deps --wait --wait-timeout 120 keycloak-db" ] \
  && echo "$OUT" | grep -q 'Replica of d05 (test01): keycloak-db with a throwaway password' \
  && ok "up on a replica with no start_env: keycloak-db alone, a throwaway password" || bad "replica up" "rc=$rc; $OUT; $(cat "$T/log")"
[ "$(cat "$T/net/identity-platform-net")" = "$NET_RAW" ] && [ "$(cat "$T/net/identity-platform-edge")" = "$EDGE_OK" ] \
  && cmp -s "$SRC/theorg-v2-root.crt" "$ROOT/ca/root_ca.crt" \
  && ok "up on a replica: both networks made, the root CA placed" || bad "replica networks and CA" "$(ls "$T/net")"
grep -q '^SET POSTGRES_PASSWORD' "$T/log" && ! grep -qE '^SET (LDAP_ADMIN_PASSWORD|VAULT_DEX_CLIENT_SECRET)' "$T/log" \
  && ok "up on a replica: POSTGRES_PASSWORD set, no LDAP or Dex name" || bad "replica secret names" "$(grep '^SET' "$T/log")"
pw1="$(cat "$T/pw1" 2>/dev/null)"
STUB_HOST=test01 STUB_PW_FILE="$T/pw2" STUB_SET="$DB_NAME IDP_LDAP_ADMIN_PASSWORD" run up; rc=$?
pw2="$(cat "$T/pw2" 2>/dev/null)"
[ "$rc" -eq 0 ] && [ "${#pw1}" -eq 48 ] && [ "${#pw2}" -eq 48 ] && [ "$pw1" != "$pw2" ] && [ "$pw2" != stand-in ] \
  && ! grep -qE '^SET LDAP_ADMIN_PASSWORD' "$T/log" \
  && ok "replica password: 48 hex characters, new each run, never the IDP_* value even when one is set" \
  || bad "replica password" "rc=$rc; lengths ${#pw1} ${#pw2}; same=$([ "$pw1" = "$pw2" ] && echo yes || echo no)"
leak=no
for pw in "$pw1" "$pw2"; do
  { [ -z "$pw" ] || grep -rqF -- "$pw" "$T/dl" "$T/app" "$T/home" || grep -qF -- "$pw" <<< "$OUT"; } && leak=yes
done
[ "$leak" = no ] && ok "the replica passwords are in no file and not in the output" || bad "the replica password is in a file or the output"
rm -f "$T/pw1" "$T/pw2"; unset pw pw1 pw2 leak
STUB_HOST=test01 run start-keycloak; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'M5 cutover, not yet written' && [ ! -s "$T/log" ] \
  && ok "start-keycloak on a replica: refused" || bad "replica start-keycloak" "rc=$rc; $OUT"

# --- images (build_host.py's replica guard): pull missing through the helper, names alone on stdout ---
: > "$T/log"
IMGS="$(env "$PULL_NAME=stand-in" HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_NET="$T/net" STUB_HOST=test01 \
  STUB_MISSING=1 bash "$T/app/identity-platform.sh" images 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ "$IMGS" = "postgres:16@sha256:aa" ] && grep -q HELPER_OK "$T/log" \
  && grep -q '^docker compose -f compose.yml --profile ops --profile restored pull$' "$T/log" \
  && ok "images: pulls the missing ones through the helper, prints keycloak-db's image alone" || bad "images" "rc=$rc; [$IMGS]; $(cat "$T/log")"
STUB_HOST=test01 STUB_MISSING=1 run images; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q "$PULL_NAME is not in" && ! grep -q ' pull' "$T/log" \
  && ok "images with an image missing and no pull token: fails" || bad "images no token" "rc=$rc; $OUT"
grep -qE '^[[:space:]]+([a-z_|-]+\|)?images(\|[a-z_|-]+)?\)' "$SRC/identity-platform.sh" \
  && ok "build_host.py's app_has finds the images switch" || bad "images switch not found by app_has's pattern"

# --- the M5 switches refuse ---
for sw in start-openldap start-keycloak restore; do
  STUB_SET="$DB_NAME IDP_LDAP_ADMIN_PASSWORD" run "$sw"; rc=$?
  [ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'M5 cutover, not yet written' && [ ! -s "$T/log" ] \
    && ok "$sw: refused (exit $rc), no docker call" || bad "$sw refusal" "rc=$rc; $OUT; $(cat "$T/log")"
done
# build_host.py reads exit 3 from a restore as "skipped, data present": the refusal must not be 3.
run restore; rc=$?
[ "$rc" -ne 3 ] && ok "restore's refusal is not build_host.py's skip status (3)" || bad "restore exit 3"

# --- a CA copy with another fingerprint is refused ---
reset_host
cp "$T/app/theorg-v2-root.crt" "$T/root.keep"
{ echo "-----BEGIN CERTIFICATE-----"; printf 'not theOrg root, a stand-in' | base64; echo "-----END CERTIFICATE-----"; } > "$T/app/theorg-v2-root.crt"
STUB_SET="$DB_NAME" run up; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'does not hold one certificate with SHA-256' && [ ! -e "$ROOT/ca/root_ca.crt" ] \
  && ! grep -q ' up ' "$T/log" \
  && ok "up with a root CA copy of another fingerprint: refused, nothing placed, keycloak-db not started" || bad "CA mismatch" "rc=$rc; $OUT"
cat "$T/root.keep" "$T/root.keep" > "$T/app/theorg-v2-root.crt"
STUB_SET="$DB_NAME" run up; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'does not hold one certificate' \
  && ok "up with two certificates in the root CA copy: refused" || bad "CA two certs" "rc=$rc; $OUT"
cp "$T/root.keep" "$T/app/theorg-v2-root.crt"
# A placed copy that someone changed is replaced by the checked one.
STUB_SET="$DB_NAME" run up >/dev/null; echo "changed" > "$ROOT/ca/root_ca.crt"
STUB_SET="$DB_NAME" run up; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$SRC/theorg-v2-root.crt" "$ROOT/ca/root_ca.crt" \
  && ok "up replaces a changed ca/root_ca.crt with the checked copy" || bad "CA replaced" "rc=$rc; $OUT"

# --- the openldap leaf: reported, not fatal ---
reset_host
STUB_SET="$DB_NAME" run up; rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -q 'WARN\] openldap leaf: .*openldap-tls is missing' && [ ! -e "$ROOT/openldap-tls" ] \
  && ok "up with no openldap-tls: the missing leaf is reported, up passes, the dir is not created" || bad "leaf missing" "rc=$rc; $OUT"
mkdir -p "$ROOT/openldap-tls"
{ echo "-----BEGIN CERTIFICATE-----"; printf 'stand-in leaf' | base64; echo "-----END CERTIFICATE-----"; } > "$ROOT/openldap-tls/ldap.crt"
cp "$SRC/theorg-v2-root.crt" "$ROOT/openldap-tls/ca.crt"
STUB_SET="$DB_NAME" run up; rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -q 'ldap.key is missing' && echo "$OUT" | grep -q 'ldap.crt holds 1 certificate' \
  && echo "$OUT" | grep -q 'ca.crt present' \
  && ok "up with a partial leaf: no key and no intermediate reported, up passes" || bad "leaf partial" "rc=$rc; $OUT"

# --- verify ---
reset_host
STUB_SET="$DB_NAME" run up >/dev/null
STUB_DB_RUNNING=1 run verify; rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -q 'keycloak-db healthy' && echo "$OUT" | grep -q 'identity-platform-edge OK (internal)' \
  && echo "$OUT" | grep -q 'WARN\] openldap leaf' \
  && ok "verify after up: networks, CA, keycloak-db healthy pass; the leaf is reported only" || bad "verify" "rc=$rc; $OUT"
run verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'keycloak-db: not running' && ok "verify with keycloak-db not running: fails" || bad "verify db down" "rc=$rc; $OUT"
! echo "$OUT" | grep -q 'Usage:' && ok "a switch that fails (verify) prints no usage" || bad "usage after a failed switch" "$OUT"
STUB_DB_RUNNING=1 STUB_DB_HEALTH=starting run verify; rc=$?
[ "$rc" -ne 0 ] && ok "verify with keycloak-db not yet healthy: fails" || bad "verify db starting" "rc=$rc"

# --- down: keycloak-db only, nothing removed ---
run down; rc=$?
calls="$(grep -v '^TAG ' "$T/log" | sed -E 's/^docker compose -f compose.yml //')"
[ "$rc" -eq 0 ] && [ "$calls" = "stop keycloak-db" ] && [ -d "$ROOT/keycloak-db" ] \
  && ok "down: stops keycloak-db alone; no down, rm, volume or network call" || bad "down" "rc=$rc; [$calls]"

# --- pulls ---
STUB_SET="$PULL_NAME" run pull; rc=$?
[ "$rc" -eq 0 ] && grep -q '^docker compose -f compose.yml --profile ops --profile restored pull$' "$T/log" \
  && grep -q 'PULLCFG {"credHelpers":{"gitea.asyla.org":"identity-platform-env"}}' "$T/log" && grep -q HELPER_OK "$T/log" \
  && ok "pull: all six images, through the credential helper under a throwaway DOCKER_CONFIG" || bad "pull" "rc=$rc; $(cat "$T/log")"
run pull; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q "$PULL_NAME is not in" && ! grep -q ' pull' "$T/log" \
  && ok "pull without the pull token: refused" || bad "pull no token" "rc=$rc; $OUT"
reset_host
STUB_MISSING=1 STUB_SET="$DB_NAME" run up; rc=$?
[ "$rc" -ne 0 ] && ! grep -q ' up ' "$T/log" && ok "up with an image missing and no pull token: fails before keycloak-db" || bad "up missing image" "rc=$rc"
STUB_MISSING=1 STUB_SET="$DB_NAME $PULL_NAME" run up; rc=$?
[ "$rc" -eq 0 ] && grep -q HELPER_OK "$T/log" && ok "up with an image missing: pulls it through the helper, then starts" || bad "up pulls missing" "rc=$rc; $OUT"
tags="$(awk '/^TAG / {print $2}' "$T/log" | sort -u)"
[ "$tags" = "fcbed3febc7e65bc7afbab980d6b3868a0b3fe53" ] \
  && ok "theOrg's images are pinned to fcbed3fe's full sha in every compose call" || bad "tag pin" "[$tags]"

# The credential helper: read-only, and it never takes a value with unexpected characters.
H="$SRC/docker-credential-identity-platform-env"
for v in store erase list; do
  "$H" "$v" </dev/null >/dev/null 2>&1 && bad "helper $v accepted" || ok "helper refuses $v"
done
printf 'gitea.asyla.org' | env -u "$PULL_NAME" "$H" get >/dev/null 2>&1 && bad "helper get with no token passed" || ok "helper get with no token: refused"
out="$(printf 'gitea.asyla.org' | env "$PULL_NAME=stand-in" "$H" get 2>/dev/null)"
grep -q '"Username":"theorg-registry"' <<< "$out" && ok "helper get hands Docker the token from its environment" || bad "helper get" "[$out]"

# --- the openldap leaf ---
# A plain stand-in word made at run time, unlike any real value.
LEAF_VAL="stand-in-value-$$"
# leaf_run SWITCH...: as run, with $LEAF_VAL as one line on the script's stdin (LEAF_BASH_X=1 runs it
# under bash -x; LEAF_STDIN, when set,
# is written instead, as is: LEAF_STDIN= gives an empty stdin). LEAF_IN_ENV=1 also puts
# LDAP_PROVISIONER_PASSWORD=$LEAF_VAL in its environment, LEAF_IN_ENV=empty puts it there empty.
leaf_run() {
  local rc envset=()
  case "${LEAF_IN_ENV:-}" in
    1) envset=("LDAP_PROVISIONER_PASSWORD=$LEAF_VAL") ;;
    empty) envset=("LDAP_PROVISIONER_PASSWORD=") ;;
  esac
  : > "$T/log"
  # shellcheck disable=SC2086  # LEAF_EXTRA is NAME=value words
  OUT="$(leaf_stdin | env ${envset[@]+"${envset[@]}"} ${LEAF_EXTRA:-} HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" \
    STUB_NET="$T/net" STUB_HOST="${STUB_HOST:-d05}" IDENTITY_PLATFORM_DB_WAIT_S=120 \
    IDENTITY_PLATFORM_SYSTEMD_DIR="$T/systemd" bash ${LEAF_BASH_X:+-x} "$T/app/identity-platform.sh" "$@" 2>&1)"
  rc=$?
  return "$rc"
}
leaf_stdin() { if [ -n "${LEAF_STDIN+x}" ]; then printf '%s' "$LEAF_STDIN"; else printf '%s\n' "$LEAF_VAL"; fi; }
# tty_run SWITCH...: as leaf_run with no value anywhere, stdin a terminal (a pty python3 opens).
tty_run() {
  local rc
  : > "$T/log"
  OUT="$(python3 -c 'import os, subprocess, sys; m, s = os.openpty(); sys.exit(subprocess.call(sys.argv[1:], stdin=s))' \
    env HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_NET="$T/net" STUB_HOST=d05 \
    IDENTITY_PLATFORM_SYSTEMD_DIR="$T/systemd" bash "$T/app/identity-platform.sh" "$@" 2>&1)"
  rc=$?
  return "$rc"
}
no_value() {   # the value in no output, docker argv, leaf argv or file under the host's dirs
  ! grep -qF -- "$LEAF_VAL" <<< "$OUT" && ! grep -qF -- "$LEAF_VAL" "$T/log" \
    && ! grep -rqF -- "$LEAF_VAL" "$T/dl" "$T/systemd" "$T/home"
}
refused3() {   # refused3 WHAT PATTERN: exit 3, PATTERN in the output, no docker or openldap-leaf.sh call, no status file
  [ "$rc" -eq 3 ] && echo "$OUT" | grep -q -- "$2" && [ ! -s "$T/log" ] && [ ! -e "$ROOT/leaf-status.json" ] \
    && [ ! -e "$ROOT/openldap-tls" ] && no_value \
    && ok "leaf-issue $1: refused (3), no docker or openldap-leaf.sh call, no status file" \
    || bad "leaf-issue $1" "rc=$rc; $OUT; $(cat "$T/log")"
}

# leaf-issue's refusals, each before any docker or openldap-leaf.sh call and without a status write.
reset_host
LEAF_IN_ENV=1 leaf_run leaf-issue; rc=$?
refused3 "with LDAP_PROVISIONER_PASSWORD in its environment" 'LDAP_PROVISIONER_PASSWORD is set in the environment'
reset_host
LEAF_IN_ENV=empty leaf_run leaf-issue; rc=$?
refused3 "with LDAP_PROVISIONER_PASSWORD set but empty" 'LDAP_PROVISIONER_PASSWORD is set in the environment'
reset_host
tty_run leaf-issue; rc=$?
refused3 "with a terminal on stdin" 'stdin is a terminal'
reset_host
LEAF_STDIN= leaf_run leaf-issue; rc=$?
refused3 "with an empty stdin" 'no provisioner password read on stdin'
reset_host
LEAF_STDIN=$'\n' leaf_run leaf-issue; rc=$?
refused3 "with an empty line on stdin" 'no provisioner password read on stdin'
for order in "up leaf-issue" "leaf-issue up" "leaf-issue leaf-schedule-install" "leaf-renew leaf-issue" "leaf-issue leaf-issue"; do
  reset_host
  # shellcheck disable=SC2086
  LEAF_EXTRA="$DB_NAME=stand-in" leaf_run $order; rc=$?
  refused3 "combined ($order)" 'leaf-issue: refused: run it alone'
done

# leaf-issue: networks, CA and openldap-tls, then openldap-leaf.sh issue, which alone gets the line
# on its stdin (never in its environment).
reset_host
LEAF_EXTRA="STUB_LEAF_PW_FILE=$T/leafpw" leaf_run leaf-issue; rc=$?
got="$(cat "$T/leafpw" 2>/dev/null)"; rm -f "$T/leafpw"
[ "$rc" -eq 0 ] && grep -qx 'LEAF issue pw=' "$T/log" && [ "$got" = "$LEAF_VAL" ] && [ -d "$ROOT/openldap-tls" ] \
  && cmp -s "$SRC/theorg-v2-root.crt" "$ROOT/ca/root_ca.crt" && [ -f "$T/net/identity-platform-net" ] \
  && ok "leaf-issue: networks, root CA and openldap-tls in place, then openldap-leaf.sh issue reads the value on stdin, not in its environment" \
  || bad "leaf-issue" "rc=$rc; same=$([ "$got" = "$LEAF_VAL" ] && echo yes || echo no); $OUT; $(cat "$T/log")"
! grep -q '^ENVPW' "$T/log" && ok "leaf-issue: no docker call of identity-platform.sh's own has the name in its environment" \
  || bad "leaf-issue docker env" "$(grep '^ENVPW' "$T/log")"
no_value && ok "leaf-issue: the value is in no output, argv or file" || bad "leaf-issue leaks the value"
[ ! -e "$ROOT/openldap-data" ] && [ ! -e "$ROOT/openldap-config" ] \
  && ok "leaf-issue never creates openldap-data or openldap-config" || bad "leaf-issue dirs" "$(ls "$ROOT")"
# openldap-leaf.sh's exit is kept (3: refused, e.g. a valid leaf on disk).
LEAF_EXTRA="STUB_LEAF_RC=3" leaf_run leaf-issue; rc=$?
[ "$rc" -eq 3 ] && ok "leaf-issue keeps openldap-leaf.sh's exit status (3)" || bad "leaf-issue exit" "rc=$rc; $OUT"
# On a replica: refused, nothing called.
reset_host
STUB_HOST=test01 leaf_run leaf-issue; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'leaf-issue: not on a replica' && [ ! -s "$T/log" ] && no_value \
  && ok "leaf-issue on a replica: refused, no call" || bad "replica leaf-issue" "rc=$rc; $OUT"

# The real openldap-leaf.sh (the README's copy) under leaf-issue: the value reaches docker run -i on
# its stdin alone (no -e), never in an environment, an argv or the output.
reset_host
cp "$SRC/openldap-leaf.sh" "$T/app/openldap-leaf.sh"
LEAF_EXTRA="STUB_RUN_PW_FILE=$T/runpw" leaf_run leaf-issue; rc=$?
got="$(cat "$T/runpw" 2>/dev/null)"; rm -f "$T/runpw"
runline="$(grep -E '^docker run --rm --network identity-platform-net ' "$T/log")"
[ "$rc" -eq 0 ] && grep -qE ' -i smallstep/step-cli[:@]' <<< "$runline" && ! grep -qE ' -e ' <<< "$runline" \
  && ! grep -qF -- '-e LDAP_PROVISIONER_PASSWORD' "$T/log" && grep -qx 'RUNENV ' "$T/log" && ! grep -q '^ENVPW' "$T/log" \
  && [ "$got" = "$LEAF_VAL" ] && echo "$OUT" | grep -q 'openldap is not running' \
  && ok "real openldap-leaf.sh issue: docker run -i, no -e, the name unset; the value on the container's stdin alone" \
  || bad "real leaf issue" "rc=$rc; same=$([ "$got" = "$LEAF_VAL" ] && echo yes || echo no); $OUT; $(cut -c1-200 "$T/log")"
no_value && ok "real openldap-leaf.sh issue: the value is in no output, argv or file" || bad "real leaf issue leaks the value"
cp "$T/leaf-stub.sh" "$T/app/openldap-leaf.sh"

# up never issues and never hands the value on, even when it is set in its environment.
reset_host
LEAF_IN_ENV=1 LEAF_STDIN= LEAF_EXTRA="$DB_NAME=stand-in" leaf_run up; rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^LEAF ' "$T/log" && ! grep -q '^ENVPW' "$T/log" && [ ! -e "$ROOT/openldap-tls" ] \
  && echo "$OUT" | grep -q 'WARN\] openldap leaf: .*missing (.*leaf-issue' && no_value \
  && ok "up with LDAP_PROVISIONER_PASSWORD set: no issue, no openldap-tls, the name in no child's environment, up passes" \
  || bad "up issues" "rc=$rc; $OUT; $(cat "$T/log")"
! grep -qE '(^|[^a-z-])(issue|renew)\b' <(sed -n '/^do_up()/,/^}/p' "$SRC/identity-platform.sh") \
  && ok "do_up names no issue or renew" || bad "do_up mentions issue/renew"

# leaf-renew: no secret, openldap-leaf.sh renew; refused when the value is set, and on a replica.
reset_host
run leaf-renew; rc=$?
[ "$rc" -eq 0 ] && grep -qx 'LEAF renew pw=' "$T/log" && ok "leaf-renew: openldap-leaf.sh renew without any value" || bad "leaf-renew" "rc=$rc; $OUT; $(cat "$T/log")"
LEAF_IN_ENV=1 LEAF_STDIN= leaf_run leaf-renew; rc=$?
[ "$rc" -eq 3 ] && ! grep -q '^LEAF ' "$T/log" && echo "$OUT" | grep -q 'needs no provisioner password' \
  && ok "leaf-renew with LDAP_PROVISIONER_PASSWORD set: refused (3), not run" || bad "leaf-renew with value" "rc=$rc; $OUT"
STUB_HOST=test01 run leaf-renew; rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$T/log" ] && ok "leaf-renew on a replica: refused" || bad "replica leaf-renew" "rc=$rc; $OUT"

# The schedule: never installed by up; leaf-schedule-install only, after a leaf exists.
reset_host
STUB_SET="$DB_NAME" run up; rc=$?
[ "$rc" -eq 0 ] && ! grep -qE '^(sudo|systemctl) ' "$T/log" && [ -z "$(ls -A "$T/systemd")" ] \
  && ok "up installs no schedule (no sudo, no systemctl, no unit)" || bad "up schedule" "rc=$rc; $(ls "$T/systemd"); $(cat "$T/log")"
STUB_DB_RUNNING=1 run verify; rc=$?
! grep -qE '^(sudo|systemctl) ' "$T/log" && ok "verify installs no schedule" || bad "verify schedule" "$(cat "$T/log")"
run leaf-schedule-install; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'run leaf-issue first' && [ -z "$(ls -A "$T/systemd")" ] && ! grep -q '^sudo' "$T/log" \
  && ok "leaf-schedule-install with no leaf: refused, nothing installed" || bad "schedule no leaf" "rc=$rc; $OUT"
mkdir -p "$ROOT/openldap-tls"; echo "stand-in leaf" > "$ROOT/openldap-tls/ldap.crt"
run leaf-schedule-install; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'records no successful leaf-issue' && [ -z "$(ls -A "$T/systemd")" ] \
  && ok "leaf-schedule-install with a leaf but no successful leaf-issue recorded: refused" || bad "schedule no issue" "rc=$rc; $OUT"
leaf_run leaf-issue >/dev/null; echo "stand-in leaf" > "$ROOT/openldap-tls/ldap.crt"
grep -qE '^  "issued_ok": "[0-9]{4}-' "$ROOT/leaf-status.json" && grep -q '"result": "ok"' "$ROOT/leaf-status.json" \
  && ok "leaf-issue writes leaf-status.json: result ok, issued_ok" || bad "issue status" "$(cat "$ROOT/leaf-status.json" 2>/dev/null)"
run leaf-schedule-install; rc=$?
svc_file="$T/systemd/identity-platform-leaf-renew.service"
[ "$rc" -eq 0 ] && grep -qx "ExecStart=$T/app/identity-platform.sh leaf-renew" "$svc_file" \
  && grep -qx "User=$(id -un)" "$svc_file" && ! grep -q '@' "$svc_file" \
  && grep -qx 'RequiresMountsFor=/mnt/docker' "$svc_file" \
  && [ "$(sed -n '/^\[Unit\]/,/^\[/p' "$svc_file" | grep -c '^RequiresMountsFor=/mnt/docker$')" -eq 1 ] \
  && cmp -s "$SRC/identity-platform-leaf-renew.timer" "$T/systemd/identity-platform-leaf-renew.timer" \
  && grep -q '^systemctl enable --now identity-platform-leaf-renew.timer$' "$T/log" \
  && ok "leaf-schedule-install: the service filled in (user, script, leaf-renew; RequiresMountsFor=/mnt/docker in [Unit]), the timer as committed, enabled" \
  || bad "schedule install" "rc=$rc; $OUT; $(cat "$svc_file" 2>/dev/null); $(cat "$T/log")"
grep -qx 'OnCalendar=\*-\*-\* 00/3:17:00' "$SRC/identity-platform-leaf-renew.timer" \
  && grep -qx 'Persistent=true' "$SRC/identity-platform-leaf-renew.timer" \
  && ok "the timer runs every 3 hours, persistent" || bad "timer schedule"
! grep -qiE 'PASSWORD|Environment' "$SRC/identity-platform-leaf-renew.service" \
  && ok "the renew service carries no secret or environment" || bad "service env"
# Idempotent: the first install above wrote both units and daemon-reloaded once; a second one
# installs nothing and does not reload, and enables again; a changed template installs that unit
# alone and reloads once.
[ "$(grep -c '^systemctl daemon-reload$' "$T/log")" -eq 1 ] && [ "$(grep -c '^sudo install ' "$T/log")" -eq 2 ] \
  && ok "leaf-schedule-install (first): both units installed, one daemon-reload" || bad "schedule first install" "$(cat "$T/log")"
run leaf-schedule-install; rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^sudo install ' "$T/log" && ! grep -q 'daemon-reload' "$T/log" \
  && grep -q '^systemctl enable --now identity-platform-leaf-renew.timer$' "$T/log" && echo "$OUT" | grep -q 'unchanged; no daemon-reload' \
  && ok "leaf-schedule-install (second): nothing installed, no daemon-reload, enabled again" || bad "schedule second install" "rc=$rc; $OUT; $(cat "$T/log")"
cp "$T/app/identity-platform-leaf-renew.timer" "$T/timer.orig"
echo "# a template change" >> "$T/app/identity-platform-leaf-renew.timer"
run leaf-schedule-install; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^sudo install ' "$T/log")" -eq 1 ] && grep -q '^sudo install .*leaf-renew.timer ' "$T/log" \
  && [ "$(grep -c '^systemctl daemon-reload$' "$T/log")" -eq 1 ] && cmp -s "$T/app/identity-platform-leaf-renew.timer" "$T/systemd/identity-platform-leaf-renew.timer" \
  && ok "leaf-schedule-install after a timer template change: the timer alone installed, one daemon-reload" || bad "schedule template change" "rc=$rc; $(cat "$T/log")"
cp "$T/timer.orig" "$T/app/identity-platform-leaf-renew.timer"
run leaf-schedule-remove; rc=$?
[ "$rc" -eq 0 ] && [ -z "$(ls -A "$T/systemd")" ] && grep -q '^systemctl disable --now identity-platform-leaf-renew.timer$' "$T/log" \
  && ok "leaf-schedule-remove: disabled and removed" || bad "schedule remove" "rc=$rc; $OUT"

# --- leaf-status.json: what host-maintenance's monitor reads (runner/maint.py status_problems) ---
# A throwaway self-signed certificate as the leaf, made here at run time, ending MINUTES from now;
# its key stays under $T/keys and is removed with $T.
mkdir -p "$T/keys"
mkcert() {   # mkcert MINUTES
  local na
  na="$(python3 -c 'import datetime as d, sys; print((d.datetime.now(d.timezone.utc) + d.timedelta(minutes=int(sys.argv[1]))).strftime("%Y%m%d%H%M%SZ"))' "$1")"
  mkdir -p "$ROOT/openldap-tls"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$T/keys/leaf.key" \
    -out "$ROOT/openldap-tls/ldap.crt" -subj /CN=leaf-standin -not_after "$na" >/dev/null 2>&1
}
stcheck() {   # stcheck ACTION RESULT EXIT SEVERITY|- NOT_AFTER(set|null) ISSUED_OK|-: the file as maint.py reads it
  python3 - "$ROOT/leaf-status.json" "$@" <<'PY'
import datetime as dt, json, re, sys
d = json.load(open(sys.argv[1]))
action, result, rc, sev, na, issued = sys.argv[2:8]
assert (d["action"], d["result"], d["exit"]) == (action, result, int(rc)), d
# maint.py parse_iso is datetime.fromisoformat (python:3.12 in its CI): it reads "...Z" as UTC.
assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", d["time"]), d["time"]
t = dt.datetime.fromisoformat(d["time"])
assert t.utcoffset() == dt.timedelta(0) and abs((dt.datetime.now(dt.timezone.utc) - t).total_seconds()) < 300, d["time"]
assert (d["not_after"] is not None) == (na == "set"), d["not_after"]
assert issued == "-" or d["issued_ok"] == issued, (d["issued_ok"], issued)
if sev == "-":
    assert d["problems"] == [], d["problems"]
else:
    assert len(d["problems"]) == 1 and d["problems"][0]["key"] == "leaf" and d["problems"][0]["severity"] == sev, d["problems"]
    assert action in d["problems"][0]["message"] and f"exit {rc}" in d["problems"][0]["message"], d["problems"]
PY
}
reset_host
leaf_run leaf-issue >/dev/null
issued="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["issued_ok"])' "$ROOT/leaf-status.json" 2>/dev/null)"
if mkcert 1200 && [ -n "$issued" ]; then
  run leaf-renew; rc=$?
  [ "$rc" -eq 0 ] && stcheck leaf-renew ok 0 - set "$issued" \
    && ok "leaf-renew ok: result ok, exit 0, no problem, notAfter, issued_ok carried, time ...Z (UTC, fromisoformat)" \
    || bad "renew ok status" "rc=$rc; $(cat "$ROOT/leaf-status.json")"
  mkcert 370   # 6h10m: outside the 6h boundary
  STUB_LEAF_RC=1 run leaf-renew; rc=$?
  [ "$rc" -eq 1 ] && stcheck leaf-renew fail 1 warn set "$issued" \
    && ok "leaf-renew failed, leaf 6h10m from notAfter: result fail, exit 1, problem leaf warn" \
    || bad "renew fail warn" "rc=$rc; $(cat "$ROOT/leaf-status.json")"
  mkcert 350   # 5h50m: inside it
  STUB_LEAF_RC=1 run leaf-renew; rc=$?
  [ "$rc" -eq 1 ] && stcheck leaf-renew fail 1 urgent set "$issued" \
    && ok "leaf-renew failed, leaf 5h50m from notAfter: problem leaf urgent" \
    || bad "renew fail urgent" "rc=$rc; $(cat "$ROOT/leaf-status.json")"
  mkcert -10   # past
  STUB_LEAF_RC=1 run leaf-renew; rc=$?
  [ "$rc" -eq 1 ] && stcheck leaf-renew fail 1 urgent set "$issued" \
    && ok "leaf-renew failed, leaf expired: problem leaf urgent" || bad "renew fail expired" "rc=$rc; $(cat "$ROOT/leaf-status.json")"
  echo "stand-in leaf" > "$ROOT/openldap-tls/ldap.crt"
  STUB_LEAF_RC=1 run leaf-renew; rc=$?
  [ "$rc" -eq 1 ] && stcheck leaf-renew fail 1 urgent null "$issued" \
    && ok "leaf-renew failed, leaf unreadable: problem leaf urgent, not_after null" || bad "renew fail unreadable" "rc=$rc; $(cat "$ROOT/leaf-status.json")"
  # leaf-issue that openldap-leaf.sh refuses (3: a valid leaf, or its lock held): result refused,
  # the previous file's problems carried forward unchanged (no new work item), issued_ok kept.
  refcheck() {   # refcheck BEFORE ISSUED_OK: refused, exit 3, problems as in BEFORE ("[]" when none)
    python3 - "$ROOT/leaf-status.json" "$1" "$2" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
before = json.load(open(sys.argv[2]))["problems"] if os.path.getsize(sys.argv[2]) else []
assert (d["action"], d["result"], d["exit"]) == ("leaf-issue", "refused", 3), d
assert d["problems"] == before, (d["problems"], before)
want = None if sys.argv[3] == "null" else sys.argv[3]
assert sys.argv[3] == "-" or d["issued_ok"] == want, d["issued_ok"]
PY
  }
  mkcert 1200
  cp "$ROOT/leaf-status.json" "$T/status.before"
  LEAF_EXTRA="STUB_LEAF_RC=3" leaf_run leaf-issue; rc=$?
  [ "$rc" -eq 3 ] && grep -q '"severity": "urgent"' "$T/status.before" && refcheck "$T/status.before" "$issued" \
    && ok "leaf-issue refused (3) by openldap-leaf.sh after a failed renew: result refused, the renew's urgent problem kept as it was, issued_ok kept" \
    || bad "issue refused status (problem kept)" "rc=$rc; $(cat "$ROOT/leaf-status.json")"
  run leaf-renew >/dev/null
  cp "$ROOT/leaf-status.json" "$T/status.before"
  LEAF_EXTRA="STUB_LEAF_RC=3" leaf_run leaf-issue; rc=$?
  [ "$rc" -eq 3 ] && grep -q '"problems": \[\]' "$T/status.before" && refcheck "$T/status.before" "$issued" \
    && ok "leaf-issue refused (3) over a valid leaf after an ok renew: result refused, no problem (no work item), issued_ok kept" \
    || bad "issue refused status (no problem)" "rc=$rc; $(cat "$ROOT/leaf-status.json")"
  rm -f "$ROOT/leaf-status.json"; : > "$T/status.before"
  LEAF_EXTRA="STUB_LEAF_RC=3" leaf_run leaf-issue; rc=$?
  [ "$rc" -eq 3 ] && refcheck "$T/status.before" null \
    && ok "leaf-issue refused (3) with no status file before: result refused, no problem, issued_ok null" \
    || bad "issue refused status (no file)" "rc=$rc; $(cat "$ROOT/leaf-status.json" 2>/dev/null)"
  LEAF_EXTRA="STUB_LEAF_RC=1" leaf_run leaf-issue; rc=$?
  [ "$rc" -eq 1 ] && stcheck leaf-issue fail 1 warn set - \
    && ok "leaf-issue failing otherwise (1): result fail, problem leaf warn (still a work item)" \
    || bad "issue fail status" "rc=$rc; $(cat "$ROOT/leaf-status.json")"
  STUB_LEAF_RC=3 run leaf-renew; rc=$?
  [ "$rc" -eq 3 ] && stcheck leaf-renew fail 3 warn set - \
    && ok "leaf-renew refused (3, run issue): still result fail with a problem" || bad "renew rc3 status" "rc=$rc; $(cat "$ROOT/leaf-status.json")"
else
  bad "a throwaway certificate with -not_after (openssl $(openssl version 2>&1)) or the first issue" "[$issued]"
fi

# The write is atomic: a temp file in the same directory, then mv. With mv failing the old file is
# kept byte for byte, no temp file is left, and the switch exits 1 though openldap-leaf.sh passed
# (or keeps openldap-leaf.sh's own failure).
mkdir -p "$T/mvfail"
printf '#!/bin/bash\nexit 1\n' > "$T/mvfail/mv"; chmod +x "$T/mvfail/mv"
reset_host
leaf_run leaf-issue >/dev/null
cp "$ROOT/leaf-status.json" "$T/status.before"
PATH="$T/mvfail:$PATH" run leaf-renew; rc=$?
[ "$rc" -eq 1 ] && cmp -s "$T/status.before" "$ROOT/leaf-status.json" && [ -z "$(ls -A "$ROOT" | grep '^\.leaf-status')" ] \
  && echo "$OUT" | grep -q 'ERROR\] could not write .*leaf-status.json' \
  && ok "leaf-renew ok but mv fails: exit 1, the old status file unchanged, no temp file left" \
  || bad "atomic mv" "rc=$rc; $(ls -A "$ROOT"); $OUT"
STUB_LEAF_RC=3 PATH="$T/mvfail:$PATH" run leaf-renew; rc=$?
[ "$rc" -eq 3 ] && cmp -s "$T/status.before" "$ROOT/leaf-status.json" \
  && ok "leaf-renew refused (3) and mv fails: exit 3 kept, old file unchanged" || bad "atomic mv rc3" "rc=$rc"
chmod 0555 "$ROOT"
run leaf-renew; rc=$?
chmod 0755 "$ROOT"
[ "$rc" -eq 1 ] && cmp -s "$T/status.before" "$ROOT/leaf-status.json" && [ -z "$(ls -A "$ROOT" | grep '^\.leaf-status')" ] \
  && ok "leaf-renew ok but no temp file can be made: exit 1, old file unchanged" || bad "atomic mktemp" "rc=$rc; $OUT"
rm -f "$ROOT/leaf-status.json"
PATH="$T/mvfail:$PATH" run leaf-renew; rc=$?
[ "$rc" -eq 1 ] && [ ! -e "$ROOT/leaf-status.json" ] && [ -z "$(ls -A "$ROOT" | grep '^\.leaf-status')" ] \
  && ok "no status file before and mv fails: none after (never a partial one)" || bad "atomic none" "rc=$rc; $(ls -A "$ROOT")"

# --- fetch-bundle: the M5 cutover bundle's download ---
# The pull token is $LEAF_VAL, one line on stdin. It reaches curl on its config stdin (-K -) alone,
# and the cutover image's docker pull (only when the image is missing) through the credential
# helper, in that pull's environment alone. Never an argv, a log, the output or a file under the
# host's dirs.
CUT_NAME="THEORG_REGISTRY_PULL_TOKEN"
CUT_VER="m5-0123456789ab"
CUT_IMAGE="gitea.asyla.org/theorg/identity-platform-cutover-bundle:$(sed -nE 's/^CUTOVER_BUNDLE_COMMIT="([0-9a-f]{40})"$/\1/p' "$SRC/identity-platform.sh")"
CUT_URL="https://gitea.asyla.org/api/packages/theorg/generic/identity-platform-cutover/$CUT_VER/bundle.tar.age"
CUT_SCHEME="token"   # the Authorization scheme Gitea takes
printf 'stand-in bundle body\n' > "$T/body"
BODY_SUM="$(if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi < "$T/body" | awk '{print $1}')"
BODY_SIZE="$(wc -c < "$T/body" | tr -d ' ')"
# fetch_run SWITCH...: leaf_run with curl's config kept in $T/curlcfg and its environment in $T/curlenv
# (FETCH_EXTRA: more NAME=value words).
fetch_run() {
  rm -f "$T/curlcfg"; : > "$T/curlenv"
  LEAF_EXTRA="${FETCH_EXTRA:-} STUB_CURL_CFG=$T/curlcfg STUB_CURL_ENV=$T/curlenv" leaf_run "$@"
}
cfg_ok() { [ "$(cat "$T/curlcfg" 2>/dev/null)" = "header = \"Authorization: $CUT_SCHEME $LEAF_VAL\"" ]; }
no_cut_left() {   # no bundle, no temp download and no fetched marker (or temp marker)
  [ ! -e "$ROOT/cutover/bundle.tar.age" ] && [ -z "$(ls -A "$ROOT/cutover" 2>/dev/null)" ] \
    && [ ! -e "$ROOT/cutover-state/fetched" ] && [ -z "$(ls -A "$ROOT/cutover-state" 2>/dev/null | grep '^\.')" ]
}
fetched_ok() {   # the bundle is the body, the marker names the version and its sha256, the output its size and sum
  cmp -s "$T/body" "$ROOT/cutover/bundle.tar.age" && [ "$(ls -A "$ROOT/cutover")" = "bundle.tar.age" ] \
    && [ "$(cat "$ROOT/cutover-state/fetched")" = "$(printf 'version %s\nsha256 %s' "$CUT_VER" "$BODY_SUM")" ] \
    && [ -z "$(ls -A "$ROOT/cutover-state" | grep '^\.')" ] \
    && echo "$OUT" | grep -qF "$CUT_VER, $BODY_SIZE bytes, sha256 $BODY_SUM"
}
curl_ok() {   # one curl call: -q first, the config on stdin, https only, the package URL last; no pull-token name in its env
  [ "$(grep -c '^curl ' "$T/log")" -eq 1 ] \
    && grep -qE "^curl -q -K - --fail --silent --show-error --proto =https --connect-timeout 20 -o $ROOT/cutover/\.bundle\.[A-Za-z0-9]+ $CUT_URL\$" "$T/log" \
    && grep -qx 'CURLENV ' "$T/log" && [ "$(grep -c '^PATH=' "$T/curlenv")" -eq 1 ] && ! grep -qF -- "$LEAF_VAL" "$T/curlenv" \
    && ! grep -qE "^($CUT_NAME|$PULL_NAME)=" "$T/curlenv" && cfg_ok
}
fetch_refused() {   # fetch_refused CODE WHAT PATTERN: that exit, PATTERN in the output, no docker or curl call, nothing written
  [ "$rc" -eq "$1" ] && echo "$OUT" | grep -q -- "$3" && [ ! -s "$T/log" ] && [ ! -e "$T/curlcfg" ] && no_cut_left && no_value \
    && ok "fetch-bundle $2: refused ($1), no docker or curl call, nothing written" \
    || bad "fetch-bundle $2" "rc=$rc; $OUT; $(cat "$T/log")"
}

# The image present: no pull; the bundle and the fetched marker written.
reset_host
fetch_run fetch-bundle "$CUT_VER"; rc=$?
[ "$rc" -eq 0 ] && fetched_ok && curl_ok && no_value \
  && [ "$(grep -c '^docker ' "$T/log")" -eq 1 ] && grep -qx "docker image inspect $CUT_IMAGE" "$T/log" && grep -qx 'INSPECTENV ' "$T/log" \
  && ok "fetch-bundle with the image present: no pull; curl gets the value on its config stdin alone; bundle, size, sha256 and fetched marker" \
  || bad "fetch-bundle present" "rc=$rc; cfg=$(cfg_ok && echo ok || echo wrong); $OUT; $(cat "$T/log")"
# The image missing: pulled first, through the credential helper (the value in that pull's env alone).
reset_host
FETCH_EXTRA="STUB_CUT_MISSING=1" fetch_run fetch-bundle "$CUT_VER"; rc=$?
[ "$rc" -eq 0 ] && fetched_ok && curl_ok && no_value \
  && grep -qx "docker pull $CUT_IMAGE" "$T/log" && grep -q '^PULLCFG {"credHelpers":{"gitea.asyla.org":"identity-platform-env"}}' "$T/log" \
  && grep -qx HELPER_OK "$T/log" && grep -qx 'INSPECTENV ' "$T/log" \
  && [ "$(grep -n "^docker pull" "$T/log" | cut -d: -f1)" -lt "$(grep -n '^curl ' "$T/log" | cut -d: -f1)" ] \
  && ok "fetch-bundle with the image missing: pulls it through the credential helper first, then downloads" \
  || bad "fetch-bundle missing" "rc=$rc; $OUT; $(cat "$T/log")"
reset_host
FETCH_EXTRA="STUB_CUT_MISSING=1 STUB_PULL_RC=1" fetch_run fetch-bundle "$CUT_VER"; rc=$?
[ "$rc" -eq 1 ] && ! grep -q '^curl ' "$T/log" && no_cut_left && no_value && echo "$OUT" | grep -q 'docker pull .* failed' \
  && ok "fetch-bundle: a failed image pull exits 1 before any download" || bad "fetch-bundle pull fails" "rc=$rc; $OUT; $(cat "$T/log")"
reset_host
FETCH_EXTRA="STUB_CURL_RC=22" fetch_run fetch-bundle "$CUT_VER"; rc=$?
[ "$rc" -eq 1 ] && grep -q '^curl ' "$T/log" && no_cut_left && no_value && echo "$OUT" | grep -q 'download of .* failed (curl exit 22); nothing kept' \
  && ok "fetch-bundle: a failed download exits 1 and keeps no bundle, temp file or marker" || bad "fetch-bundle curl fails" "rc=$rc; $OUT; $(ls -A "$ROOT/cutover" 2>/dev/null)"

# The refusals, each before any docker or curl call.
reset_host
FETCH_EXTRA="$CUT_NAME=$LEAF_VAL" fetch_run fetch-bundle "$CUT_VER"; rc=$?
fetch_refused 3 "with $CUT_NAME in its environment" 'the pull token is set in the environment'
reset_host
FETCH_EXTRA="$CUT_NAME=" fetch_run fetch-bundle "$CUT_VER"; rc=$?
fetch_refused 3 "with $CUT_NAME set but empty" 'the pull token is set in the environment'
reset_host
FETCH_EXTRA="$PULL_NAME=$LEAF_VAL" fetch_run fetch-bundle "$CUT_VER"; rc=$?
fetch_refused 3 "with $PULL_NAME in its environment" 'the pull token is set in the environment'
reset_host
tty_run fetch-bundle "$CUT_VER"; rc=$?
rm -f "$T/curlcfg"; fetch_refused 3 "with a terminal on stdin" 'stdin is a terminal'
reset_host
LEAF_STDIN= fetch_run fetch-bundle "$CUT_VER"; rc=$?
fetch_refused 3 "with an empty stdin" 'no pull token read on stdin'
reset_host
LEAF_STDIN=$'\n' fetch_run fetch-bundle "$CUT_VER"; rc=$?
fetch_refused 3 "with an empty line on stdin" 'no pull token read on stdin'
for bad_val in "stand in" "stand-in/value" "stand-in\"value" 'stand-in\value'; do
  reset_host
  LEAF_STDIN="$bad_val"$'\n' fetch_run fetch-bundle "$CUT_VER"; rc=$?
  ! grep -qF -- "$bad_val" <<< "$OUT" || rc=99
  fetch_refused 3 "with a value outside [A-Za-z0-9_.-] ($(printf '%q' "$bad_val"))" 'holds characters outside'
done
for args in "" "m5-0123456789a" "m5-0123456789AB" "m6-0123456789ab" "$CUT_VER $CUT_VER" "$CUT_VER up" "fetch-bundle"; do
  reset_host
  # shellcheck disable=SC2086
  fetch_run fetch-bundle $args; rc=$?
  fetch_refused 2 "with VERSION [$args]" 'fetch-bundle: usage: fetch-bundle VERSION'
done
for order in "up fetch-bundle" "leaf-renew fetch-bundle" "status fetch-bundle $CUT_VER"; do
  reset_host
  # shellcheck disable=SC2086
  fetch_run $order; rc=$?
  fetch_refused 3 "combined ($order)" 'fetch-bundle: refused: run it alone'
done
reset_host
mkdir -p "$ROOT/cutover"; echo old > "$ROOT/cutover/bundle.tar.age"
fetch_run fetch-bundle "$CUT_VER"; rc=$?
[ "$rc" -eq 3 ] && echo "$OUT" | grep -q 'bundle.tar.age exists; run cutover-clean first' && [ ! -s "$T/log" ] \
  && [ "$(cat "$ROOT/cutover/bundle.tar.age")" = old ] && [ ! -e "$ROOT/cutover-state/fetched" ] && no_value \
  && ok "fetch-bundle over an existing bundle: refused (3), no call, the bundle kept" || bad "fetch-bundle existing" "rc=$rc; $OUT"
reset_host
mkdir -p "$ROOT/cutover-state"; echo "version $CUT_VER" > "$ROOT/cutover-state/unpacked"
fetch_run fetch-bundle "$CUT_VER"; rc=$?
[ "$rc" -eq 3 ] && echo "$OUT" | grep -q 'unpacked exists .*run reset-cutover first' && [ ! -s "$T/log" ] \
  && [ ! -e "$ROOT/cutover/bundle.tar.age" ] && [ ! -e "$ROOT/cutover-state/fetched" ] && no_value \
  && ok "fetch-bundle with an unpacked marker: refused (3), no call, nothing written" || bad "fetch-bundle unpacked" "rc=$rc; $OUT"

# Under xtrace (SHELLOPTS=xtrace inherited, or bash -x), the image missing: the trace runs up to the
# read, and the value is in no output, argv or file; curl and the pull still get it.
for mode in SHELLOPTS bash-x; do
  reset_host
  if [ "$mode" = SHELLOPTS ]; then
    FETCH_EXTRA="SHELLOPTS=xtrace STUB_CUT_MISSING=1" fetch_run fetch-bundle "$CUT_VER"; rc=$?
  else
    LEAF_BASH_X=1 FETCH_EXTRA="STUB_CUT_MISSING=1" fetch_run fetch-bundle "$CUT_VER"; rc=$?
  fi
  [ "$rc" -eq 0 ] && grep -q '^+.*do_fetch_bundle' <<< "$OUT" && fetched_ok && curl_ok && grep -qx HELPER_OK "$T/log" && no_value \
    && ok "fetch-bundle under xtrace ($mode): traced up to the read, the value in no trace, argv or file; bundle fetched" \
    || bad "fetch-bundle xtrace $mode" "rc=$rc; leaked=$(grep -cF -- "$LEAF_VAL" <<< "$OUT"); $(grep -c '^+' <<< "$OUT") trace lines; $(cat "$T/log")"
done

# --- LDAP_PROVISIONER_PASSWORD reaches openldap-leaf.sh issue and no other child ---
# PATH wrappers for every outside command the script may run dump their environment to
# $T/envdump, then run the real one; the $T/bin stubs (docker, hostname, sudo, systemctl, flock)
# dump theirs there too; the openldap-leaf.sh stub dumps its own to $T/leafenv. common.env is a
# probe that records whether the name is set when it is sourced, and every exported variable.
mkdir -p "$T/envbin"
for c in dirname basename mkdir mktemp chmod mv rm cp cmp date sed head tail grep tr cat openssl id \
    install awk sort cut wc ls stat sleep tee touch ln readlink realpath uname whoami sha256sum shasum base64 timeout; do
  real="$(command -v "$c" 2>/dev/null)" || continue
  case "$real" in /*) ;; *) continue ;; esac
  printf '#!/bin/bash\n[ -z "${STUB_ENVDUMP:-}" ] || %q >> "$STUB_ENVDUMP"\nexec %q "$@"\n' "$(command -v env)" "$real" > "$T/envbin/$c"
  chmod +x "$T/envbin/$c"
done
for s in docker hostname sudo systemctl flock; do
  sed -i.orig '1a\
[ -z "${STUB_ENVDUMP:-}" ] || env >> "$STUB_ENVDUMP"
' "$T/bin/$s" && rm -f "$T/bin/$s.orig"
done
sed -i.orig '1a\
[ -z "${STUB_LEAF_ENV:-}" ] || env >> "$STUB_LEAF_ENV"
' "$T/app/openldap-leaf.sh" && rm -f "$T/app/openldap-leaf.sh.orig"
cp "$T/home/scripts/docker/common.env" "$T/common.env.orig"
cat > "$T/home/scripts/docker/common.env" <<EOF
DOCKER_DL=$T/dl
echo "probe pw=\${LDAP_PROVISIONER_PASSWORD+set}" >> "\$STUB_PROBE"
export -p >> "\$STUB_PROBE"
EOF
envrun() {   # envrun SWITCH...: leaf_run with the wrappers first on PATH and fresh dumps
  : > "$T/envdump"; : > "$T/leafenv"; : > "$T/probe"
  LEAF_EXTRA="${ENV_EXTRA:-} STUB_ENVDUMP=$T/envdump STUB_LEAF_ENV=$T/leafenv STUB_PROBE=$T/probe" PATH="$T/envbin:$PATH" leaf_run "$@"
}
reset_host
ENV_EXTRA="STUB_LEAF_PW_FILE=$T/leafpw" envrun leaf-issue; rc=$?
got="$(cat "$T/leafpw" 2>/dev/null)"; rm -f "$T/leafpw"
n="$(grep -c '^PATH=' "$T/envdump")"
[ "$rc" -eq 0 ] && [ "$n" -ge 10 ] && ! grep -qF -- "$LEAF_VAL" "$T/envdump" && ! grep -qF -- "$LEAF_VAL" "$T/leafenv" \
  && ! grep -q '^LDAP_PROVISIONER_PASSWORD=' "$T/envdump" "$T/leafenv" && [ "$(grep -c '^PATH=' "$T/leafenv")" -eq 1 ] \
  && [ "$got" = "$LEAF_VAL" ] \
  && ok "leaf-issue: the value on openldap-leaf.sh issue's stdin alone, in no environment of it or of $n other children" \
  || bad "leaf-issue env" "rc=$rc; n=$n; dump=$(grep -cF -- "$LEAF_VAL" "$T/envdump"); leaf=$(grep -c '^PATH=' "$T/leafenv"); $(cat "$T/log")"
grep -qx 'probe pw=' "$T/probe" && ! grep -qF -- "$LEAF_VAL" "$T/probe" \
  && ok "leaf-issue: common.env is sourced with LDAP_PROVISIONER_PASSWORD unset and nothing exported holding the value" \
  || bad "leaf-issue common.env probe" "$(grep '^probe' "$T/probe")"
# A same-named variable exported into the script's environment (pw=x): bash's local would keep its
# export flag and hand the value to every child; the script unsets it and declares the local +x.
reset_host
ENV_EXTRA="pw=x STUB_LEAF_PW_FILE=$T/leafpw" envrun leaf-issue; rc=$?
got="$(cat "$T/leafpw" 2>/dev/null)"; rm -f "$T/leafpw"
[ "$rc" -eq 0 ] && [ "$got" = "$LEAF_VAL" ] && [ "$(grep -c '^PATH=' "$T/envdump")" -ge 10 ] \
  && ! grep -qF -- "$LEAF_VAL" "$T/envdump" && ! grep -qF -- "$LEAF_VAL" "$T/leafenv" && ! grep -qF -- "$LEAF_VAL" "$T/probe" \
  && ! grep -q '^pw=' "$T/leafenv" \
  && ok "leaf-issue with pw=x exported in its environment: the value in no child's environment (pw unset, the local never exported)" \
  || bad "leaf-issue exported pw" "rc=$rc; dump=$(grep -cF -- "$LEAF_VAL" "$T/envdump"); leaf=$(grep -cF -- "$LEAF_VAL" "$T/leafenv")"
reset_host
LEAF_IN_ENV=1 envrun leaf-issue; rc=$?
[ "$rc" -eq 3 ] && ! grep -qF -- "$LEAF_VAL" "$T/envdump" && [ ! -s "$T/leafenv" ] && grep -qx 'probe pw=' "$T/probe" \
  && ok "leaf-issue with the value in its environment: refused (3), no child has it, openldap-leaf.sh not run" \
  || bad "leaf-issue env refused" "rc=$rc; dump=$(grep -cF -- "$LEAF_VAL" "$T/envdump")"
reset_host
LEAF_IN_ENV=1 LEAF_STDIN= envrun leaf-renew; rc=$?
[ "$rc" -eq 3 ] && [ "$(grep -c '^PATH=' "$T/envdump")" -ge 1 ] && ! grep -qF -- "$LEAF_VAL" "$T/envdump" && [ ! -s "$T/leafenv" ] \
  && grep -qx 'probe pw=' "$T/probe" \
  && ok "leaf-renew with the value set: refused (3), no child has it, openldap-leaf.sh not run" || bad "renew env" "rc=$rc"
# fetch-bundle, with tok=x exported in its environment (the local is never exported): the image
# present, the value in no child's environment; the image missing, it is in the docker pull's
# environment (and so its children's: the stub's grep, cat, the helper) under the pull-token name
# alone, never in curl's.
for missing in "" 1; do
  reset_host
  rm -f "$T/curlcfg"; : > "$T/curlenv"
  ENV_EXTRA="tok=x STUB_CUT_MISSING=$missing STUB_CURL_CFG=$T/curlcfg STUB_CURL_ENV=$T/curlenv" envrun fetch-bundle "$CUT_VER"; rc=$?
  if [ -z "$missing" ]; then
    leakok=true; ! grep -qF -- "$LEAF_VAL" "$T/envdump" || leakok=false
  else
    leakok=true
    grep -qx "$PULL_NAME=$LEAF_VAL" "$T/envdump" || leakok=false
    [ -z "$(grep -F -- "$LEAF_VAL" "$T/envdump" | grep -vx "$PULL_NAME=$LEAF_VAL")" ] || leakok=false
  fi
  [ "$rc" -eq 0 ] && $leakok && [ "$(grep -c '^PATH=' "$T/envdump")" -ge 5 ] && ! grep -qF -- "$LEAF_VAL" "$T/curlenv" \
    && ! grep -q '^tok=' "$T/curlenv" && ! grep -qF -- "$LEAF_VAL" "$T/probe" && fetched_ok && curl_ok && no_value \
    && ok "fetch-bundle (image $([ -n "$missing" ] && echo missing || echo present)) with tok=x exported: the value in curl's config alone$([ -n "$missing" ] && echo ' and the pull'"'"'s environment under the pull-token name')" \
    || bad "fetch-bundle env (missing=$missing)" "rc=$rc; dump=$(grep -cF -- "$LEAF_VAL" "$T/envdump"); curl=$(grep -cF -- "$LEAF_VAL" "$T/curlenv"); $(cat "$T/log")"
done

# identity-platform.sh never traces and never exports the name (comments aside).
code="$(grep -vE '^[[:space:]]*#' "$SRC/identity-platform.sh")"
! grep -qE 'set -[a-z]*x|set -o xtrace|bash -x' <<< "$code" \
  && ok "identity-platform.sh: no set -x (xtrace) anywhere" || bad "identity-platform.sh traces" "$(grep -nE 'set -[a-z]*x|xtrace' "$SRC/identity-platform.sh")"
! grep -qE 'export[^#]*LDAP_PROVISIONER_PASSWORD|declare -[a-z]*x[^#]*LDAP_PROVISIONER_PASSWORD' <<< "$code" \
  && ok "identity-platform.sh: LDAP_PROVISIONER_PASSWORD is never exported" || bad "identity-platform.sh exports the name"
cp "$T/common.env.orig" "$T/home/scripts/docker/common.env"

# --- a function in common.env named like a command the value passes through ---
# common.env is sourced before leaf-issue runs, so a function it defines shadows a command of the
# same name. Each case defines one recording function: printf and [ (the value as an argument),
# read and openldap-leaf.sh's own path (the value on their stdin). leaf-issue uses bash's builtin
# read and printf, [[ ]], and runs openldap-leaf.sh with `builtin exec` (never a function), so
# the value reaches the stub alone. printf and [ also run elsewhere in the script: their record
# shows the function was in force.
LEAF_FN="$(cd "$T/app" && pwd)/openldap-leaf.sh"
for shadow in printf '[' read leaf; do
  case "$shadow" in
    printf) def='printf() { builtin printf "printf %s\n" "$*" >> "$STUB_SHADOW"; builtin printf "$@"; }' ;;
    '[') def='[() { builtin printf "[ %s\n" "$*" >> "$STUB_SHADOW"; builtin [ "$@"; }' ;;
    read) def='read() { { builtin printf "read stdin "; cat; } >> "$STUB_SHADOW"; }' ;;
    leaf) def="$LEAF_FN"'() { { builtin printf "leaf stdin "; cat; } >> "$STUB_SHADOW"; }' ;;
  esac
  { cat "$T/common.env.orig"; printf '%s\n' "$def"; } > "$T/home/scripts/docker/common.env"
  : > "$T/shadow"
  reset_host
  LEAF_EXTRA="STUB_LEAF_PW_FILE=$T/leafpw STUB_SHADOW=$T/shadow" leaf_run leaf-issue; rc=$?
  got="$(cat "$T/leafpw" 2>/dev/null)"; rm -f "$T/leafpw"
  inforce=true
  case "$shadow" in printf) grep -q '^printf ' "$T/shadow" || inforce=false ;; '[') grep -q '^\[ ' "$T/shadow" || inforce=false ;; esac
  [ "$rc" -eq 0 ] && [ "$got" = "$LEAF_VAL" ] && ! grep -qF -- "$LEAF_VAL" "$T/shadow" && $inforce && no_value \
    && ok "leaf-issue with a $shadow function in common.env: the function never sees the value; openldap-leaf.sh issue gets it" \
    || bad "leaf-issue $shadow function" "rc=$rc; same=$([ "$got" = "$LEAF_VAL" ] && echo yes || echo no); in-force=$inforce; seen=$(grep -cF -- "$LEAF_VAL" "$T/shadow")"
done
rm -f "$T/shadow"
cp "$T/common.env.orig" "$T/home/scripts/docker/common.env"

# host.toml: start is up alone; LDAP_PROVISIONER_PASSWORD is in no start_env.
python3 - "$REPO/d05/host.toml" <<'PY' && ok "host.toml: identity-platform starts with up alone; LDAP_PROVISIONER_PASSWORD in no start_env" || bad "host.toml leaf"
import sys, tomllib
spec = tomllib.load(open(sys.argv[1], "rb"))
a = [x for x in spec["app"] if x["name"] == "identity-platform"][0]
assert a["start"] == ["up"], a["start"]
for x in spec["app"]:
    assert "LDAP_PROVISIONER_PASSWORD" not in x.get("start_env", []) + x.get("start_env_optional", []), x["name"]
PY

# openldap-leaf.sh is theOrg's copy the README names (git blob sha).
blob="$(sed -nE 's/.*git blob `([0-9a-f]{40})`.*/\1/p' "$SRC/README.md")"
[ -n "$blob" ] && [ "$(git hash-object "$SRC/openldap-leaf.sh")" = "$blob" ] && [ -x "$SRC/openldap-leaf.sh" ] \
  && ok "openldap-leaf.sh is the README's provenance blob ($blob), executable" || bad "openldap-leaf.sh provenance" "[$blob]"

[ "$fail" -eq 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
