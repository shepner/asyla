#!/bin/bash
# d05/apps/identity-platform/identity-platform.sh against stubs (docker, hostname): M1 only. up creates
# the two networks once (edge with --internal) and refuses one whose IPAM differs at all; up starts keycloak-db
# alone, never openldap, keycloak or an ops one-shot, and never creates openldap's data dirs;
# start-openldap, start-keycloak and restore refuse; a root CA copy with another fingerprint is
# refused; a missing openldap-tls leaf is reported, not fatal; the replica mode (a host not named
# d05: a throwaway keycloak-db password) and images (build_host.py's replica guard); usage only for
# an unknown switch. Plus compose.yml's rules (networks external, secrets by name only, the cutover
# profile, keycloak's address, no ports, its proxy, theOrg's digests; the default services from a
# real `docker compose config` when docker is here) and the pull through the credential helper.
# Nothing here reaches a registry, the vault or a host; every value is a plain stand-in word made
# at run time. Run: bash scripts/tests/test_identity_platform_sh.sh
set -uo pipefail
unset IDP_KEYCLOAK_DB_PASSWORD IDP_LDAP_ADMIN_PASSWORD IDP_DEPLOY_DEX_CLIENT_SECRET \
  IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN IDENTITY_PLATFORM_TAG_OVERRIDE STUB_MISSING STUB_DB_RUNNING \
  STUB_HOST STUB_PW_FILE

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO/d05/apps/identity-platform"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }

mkdir -p "$T/home/scripts/docker" "$T/bin" "$T/app" "$T/dl" "$T/net"
printf 'DOCKER_DL=%s\n' "$T/dl" > "$T/home/scripts/docker/common.env"
cp "$SRC"/{compose.yml,identity-platform.sh,docker-credential-identity-platform-env,theorg-v2-root.crt} "$T/app/"
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
  *"--profile"*"config --images"*) printf 'postgres:16@sha256:aa\ngitea.asyla.org/theorg/identity-platform-openldap:%s\n' "$IDENTITY_PLATFORM_TAG" ;;
  *"config --images"*) echo 'postgres:16@sha256:aa' ;;
  "image inspect"*) [ -z "${STUB_MISSING:-}" ]; exit ;;
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
chmod +x "$T/bin/docker" "$T/bin/hostname"
# bash skips a file on PATH it cannot run (a noexec temp dir) and takes the next one: the real
# docker would then act on this machine. Refuse to run then.
for s in docker hostname; do
  [ "$(PATH="$T/bin:$PATH" command -v "$s")" = "$T/bin/$s" ] || { echo "stub $s not runnable in $T/bin" >&2; exit 2; }
done

run() {   # run SWITCH...: output in $OUT, docker calls in $T/log, status returned; on d05 unless STUB_HOST
  : > "$T/log"
  local set=() n rc
  for n in ${STUB_SET:-}; do set+=("$n=stand-in"); done
  OUT="$(env ${set[@]+"${set[@]}"} HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_NET="$T/net" STUB_HOST="${STUB_HOST:-d05}" \
    IDENTITY_PLATFORM_DB_WAIT_S=120 bash "$T/app/identity-platform.sh" "$@" 2>&1)"
  rc=$?
  return "$rc"
}
reset_host() { rm -rf "$T/net"/* "$T/dl"/*; }
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
  awk -v s="$s" '$0 ~ "^  "s":$" {f=1; next} f && /^  [^ ]/ {f=0} f && /profiles: \[cutover\]/ {p=1} END {exit !p}' "$C" \
    && ok "compose.yml: $s is in the cutover profile" || bad "compose.yml: $s profile"
done
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
# theOrg identity-platform 701e893 deploy/d05/compose.example.yml, read 2026-11-14 (git show).
KC_IMAGE="quay.io/keycloak/keycloak:26.8.2@sha256:3879c623248408de29a5303178b5816c77e8dfef3890c361f8c0bbeaa979ba3b"
DB_IMAGE="postgres:16.14-bookworm@sha256:64154d0babcb1741988719e703419af0382b19953706149f9872fbd0f438efa8"
[ "$(grep -E '^    image:' <<< "$KC")" = "    image: $KC_IMAGE" ] \
  && ok "compose.yml: keycloak's image is 701e893's digest" || bad "compose.yml: keycloak image" "$(grep -E '^    image:' <<< "$KC")"
[ "$(grep -E '^    image:' <<< "$DB")" = "    image: $DB_IMAGE" ] \
  && ok "compose.yml: keycloak-db's image is 701e893's digest" || bad "compose.yml: keycloak-db image" "$(grep -E '^    image:' <<< "$DB")"
! grep -q 'profiles:' <<< "$DB" && ok "compose.yml: keycloak-db has no profile (the one M1 service)" || bad "compose.yml: keycloak-db has a profile"
# The real compose, when docker is here: no daemon is asked (config only), every value a stand-in.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  cfg() { env -u DOCKER_HOST -u DOCKER_CONTEXT -u COMPOSE_PROFILES -u COMPOSE_FILE -u LDAP_ADMIN_PASSWORD \
    IDENTITY_PLATFORM_ROOT="$T/cfg-root" IDENTITY_PLATFORM_TAG=standin-tag \
    docker compose -f "$T/app/compose.yml" --project-directory "$T/app" "$@" config --services 2>&1 | sort | tr '\n' ' '; }
  got="$(cfg)"
  [ "$got" = "keycloak-db " ] && ok "docker compose config: keycloak-db is the only service without a profile" || bad "compose config default services" "[$got]"
  got="$(cfg --profile cutover)"
  [ "$got" = "keycloak keycloak-db openldap " ] && ok "docker compose config: cutover adds keycloak and openldap only" || bad "compose config cutover" "[$got]"
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
  && grep -q '^docker compose -f compose.yml --profile ops --profile cutover pull$' "$T/log" \
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
[ "$rc" -eq 0 ] && grep -q '^docker compose -f compose.yml --profile ops --profile cutover pull$' "$T/log" \
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
[ "$tags" = "701e89316d99a4f28637def5993f2c66bdbbae53" ] \
  && ok "theOrg's images are pinned to 701e893's full sha in every compose call" || bad "tag pin" "[$tags]"

# The credential helper: read-only, and it never takes a value with unexpected characters.
H="$SRC/docker-credential-identity-platform-env"
for v in store erase list; do
  "$H" "$v" </dev/null >/dev/null 2>&1 && bad "helper $v accepted" || ok "helper refuses $v"
done
printf 'gitea.asyla.org' | env -u "$PULL_NAME" "$H" get >/dev/null 2>&1 && bad "helper get with no token passed" || ok "helper get with no token: refused"
out="$(printf 'gitea.asyla.org' | env "$PULL_NAME=stand-in" "$H" get 2>/dev/null)"
grep -q '"Username":"theorg-registry"' <<< "$out" && ok "helper get hands Docker the token from its environment" || bad "helper get" "[$out]"

[ "$fail" -eq 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
