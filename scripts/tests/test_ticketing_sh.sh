#!/bin/bash
# d06/apps/ticketing/ticketing.sh against stubs (docker, hostname, getent): the start order, the
# replica mode, the restore refusal build_host.py reads as a skip, the seeded restore, and the backup host guard.
# Nothing here reaches a registry, the vault or a host. Run: bash scripts/tests/test_ticketing_sh.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }
# backup_lib.sh's lock needs bash >= 4.1 ({fd} redirection) and flock: the hosts have both, macOS's
# bash 3.2 does not. Without them the two cases that reach the lock are skipped, and say so.
LOCK_OK=false
if command -v flock >/dev/null && bash -c '[ "${BASH_VERSINFO[0]}" -ge 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }'; then
  LOCK_OK=true
fi
skip() { echo "skip $1 (needs bash >= 4.1 and flock; run on a host)"; }

mkdir -p "$T/home/scripts/docker" "$T/bin" "$T/app" "$T/dl" "$T/d1"
cp "$REPO/docker/backup_lib.sh" "$T/home/scripts/docker/"
printf 'DOCKER_DL=%s\nDOCKER_D1=%s\n' "$T/dl" "$T/d1" > "$T/home/scripts/docker/common.env"
cp "$REPO"/d06/apps/ticketing/{ticketing.sh,compose.yml,compose.vault.yml,docker-credential-ticketing-env} "$T/app/"
# The names the workstation hands ticketing.sh at deploy. A case sets them (to a plain stand-in
# word) by listing names in STUB_SET; no value is written here.
DEX_NAMES="TICKETING_DEPLOY_DEX_CLIENT_SECRET TICKETING_MCP_DEX_CLIENT_SECRET"
PULL_NAME="TICKETING_REGISTRY_PULL_TOKEN"

# docker: logs every call; `image inspect` says present unless STUB_MISSING; `compose ... config
# --images` names one image; a pull logs its DOCKER_CONFIG and asks the credential helper there, as
# Docker would; `exec -T vikunja-mcp` prints STUB_MCP ("200 401" by default). Like
# compose, any compose call fails when a `${...:?}` the files use is empty: compose interpolates
# the whole file, unused services included.
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" | sed -E "s#-f [^ ]*/compose.yml#-f compose.yml#; s#-f [^ ]*/compose.vault.yml#-f compose.vault.yml#; s# --project-directory [^ ]*##; s#-c .*#-c PROBE#" >> "$STUB_LOG"
if [ "$1" = compose ]; then
  for v in TICKETING_ROOT TICKETING_TAG; do
    [ -n "${!v:-}" ] || { echo "required variable $v is missing a value" >&2; echo "INTERPOLATION $v" >> "$STUB_LOG"; exit 1; }
  done
fi
case "$*" in
  *"config --images"*) echo "img:1" ;;
  "image inspect"*) [ -z "${STUB_MISSING:-}" ] ;;
  *" pull"*)
    echo "PULLCFG $DOCKER_CONFIG $(cat "$DOCKER_CONFIG/config.json" 2>/dev/null)" >> "$STUB_LOG"
    printf 'gitea.asyla.org' | docker-credential-ticketing-env get | grep -q '"Username":"theorg-registry"' \
      && echo "HELPER_OK" >> "$STUB_LOG" ;;
  *"ps -q vikunja"*) if [ -n "${STUB_RUNNING:-}" ]; then echo abc; fi ;;
  *"exec -T vikunja-mcp python -c"*) echo "${STUB_MCP:-200 401}" ;;
esac
EOF
cat > "$T/bin/hostname" <<'EOF'
#!/bin/bash
case "$1" in -s) echo "$STUB_HOST" ;; -I) echo "$STUB_IP " ;; esac
EOF
cat > "$T/bin/getent" <<'EOF'
#!/bin/bash
[ -n "${STUB_RESOLVES:-}" ] && echo "$STUB_RESOLVES  STREAM vikunja.asyla.org"
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/"*

run() {   # run HOST SWITCH...: output in $OUT, docker calls in $T/log, status returned
  : > "$T/log"
  local set=() n
  for n in ${STUB_SET:-}; do set+=("$n=stand-in"); done
  OUT="$(env ${set[@]+"${set[@]}"} HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_HOST="$1" \
    TICKETING_VERIFY_WAIT_S=0 bash "$T/app/ticketing.sh" "${@:2}" 2>&1)"
}

# Start order on d06: DEPLOY.md 1-4, configure before vikunja-mcp, with the vault file.
STUB_SET="$DEX_NAMES" STUB_IP=10.0.0.65 run d06 up; rc=$?
calls="$(grep -E 'run --rm configure|up -d' "$T/log" | sed -E 's/^docker compose -f compose.yml -f compose.vault.yml //')"
want="--profile ops run --rm configure jwt-secret
up -d vikunja
--profile ops run --rm configure
up -d vikunja-mcp"
[ "$rc" -eq 0 ] && [ "$calls" = "$want" ] && ok "up on d06: DEPLOY.md's start order, with compose.vault.yml" || bad "up on d06" "rc=$rc; $calls"
echo "$OUT" | grep -q 'vector not started' && ok "up without Loki/chronicle addresses warns that vector is off" \
  || bad "vector warning" "$OUT"

# d06 without both Dex values in its environment: up, restart and configure refuse before any docker call.
for sw in up restart configure; do
  STUB_SET="TICKETING_MCP_DEX_CLIENT_SECRET" STUB_IP=10.0.0.65 run d06 "$sw"; rc=$?
  [ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'come from OpenBao at deploy' && [ ! -s "$T/log" ] \
    && ok "$sw on d06 with one Dex value missing: refused before anything stops" || bad "d06 $sw without Dex" "rc=$rc; $OUT; $(cat "$T/log")"
done

# Replica: compose.yml alone, vikunja only, no configure, no Dex values needed.
STUB_IP=10.0.0.69 run test01 up; rc=$?
[ "$rc" -eq 0 ] && grep -q 'compose.yml up -d --no-deps vikunja' "$T/log" && ! grep -q 'configure\|compose.vault.yml' "$T/log" \
  && ok "up on a replica: compose.yml alone, vikunja only, no configure" || bad "replica up" "rc=$rc; $(cat "$T/log")"
# Replica with a missing image: pulled after a registry login.
STUB_SET="$PULL_NAME" STUB_MISSING=1 STUB_IP=10.0.0.69 run test01 up; rc=$?
[ "$rc" -eq 0 ] && ! grep -q INTERPOLATION "$T/log" && grep -q HELPER_OK "$T/log" \
  && grep -q 'compose.yml --profile ops pull' "$T/log" && grep -q 'up -d --no-deps vikunja' "$T/log" \
  && ok "replica with a missing image: pulls through the credential helper, starts vikunja" \
  || bad "replica pull" "rc=$rc; $OUT; $(cat "$T/log")"
# The pull config held only the helper's name, and was removed when the script ended.
cfg="$(awk '/^PULLCFG/ {print $2; exit}' "$T/log")"
grep -qF '{"credHelpers":{"gitea.asyla.org":"ticketing-env"}}' "$T/log" && [ -n "$cfg" ] && [ ! -e "$cfg" ] \
  && ok "pulls use a throwaway DOCKER_CONFIG naming only the helper, removed afterwards" || bad "pull config" "[$cfg] $(cat "$T/log")"
# Missing images and no pull token in the environment: a failure naming where it comes from.
STUB_MISSING=1 STUB_IP=10.0.0.69 run test01 up; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'images missing; the pull token comes from the workstation' \
  && ! grep -q 'pull\|up -d' "$T/log" && ok "missing images with no pull token: fails before any pull or start" \
  || bad "missing images no token" "rc=$rc; $OUT; $(cat "$T/log")"
# The helper alone: get answers only with a plain value; store, erase and list refuse; no value is printed on stderr.
HELPER="$T/app/docker-credential-ticketing-env"
[ "$(stat -f %Lp "$REPO/d06/apps/ticketing/docker-credential-ticketing-env" 2>/dev/null || stat -c %a "$REPO/d06/apps/ticketing/docker-credential-ticketing-env")" = 755 ] \
  && ok "the helper is executable (755)" || bad "helper mode"
got="$(printf 'gitea.asyla.org\n' | env "$PULL_NAME=stand-in" "$HELPER" get)"; rc=$?
want="$(printf '{"ServerURL":"%s","Username":"%s","Secret":"%s"}' gitea.asyla.org theorg-registry stand-in)"
[ "$rc" -eq 0 ] && [ "$got" = "$want" ] \
  && ok "helper get: the server, the user and the environment's value as JSON" || bad "helper get" "rc=$rc"
err="$(printf 'gitea.asyla.org' | env -u "$PULL_NAME" "$HELPER" get 2>&1 >/dev/null)"; rc=$?
[ "$rc" -ne 0 ] && echo "$err" | grep -q 'not in this process' && ok "helper get with the value unset: exit 1, says why" || bad "helper unset" "rc=$rc"
err="$(printf 'gitea.asyla.org' | env "$PULL_NAME=stand in\"x" "$HELPER" get 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && echo "$err" | grep -q 'outside' && ! echo "$err" | grep -q 'stand in' \
  && ok "helper get with a value outside [A-Za-z0-9_.-]: refused, value not shown" || bad "helper bad value" "rc=$rc"
hrc=0
for c in store erase list; do echo '{}' | "$HELPER" "$c" 2>/dev/null && hrc=1; done
[ "$hrc" -eq 0 ] && ok "helper store, erase and list refuse" || bad "helper write ops"
# images (build_host.py's replica guard): pull missing with the login, image names alone on stdout.
: > "$T/log"
IMGS="$(env "$PULL_NAME=stand-in" HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_HOST=test01 STUB_MISSING=1 bash "$T/app/ticketing.sh" images 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ "$IMGS" = "img:1" ] && grep -q HELPER_OK "$T/log" \
  && ok "images on a replica: pulls through the credential helper, prints only image names" || bad "images" "rc=$rc; [$IMGS]"
STUB_SET="$DEX_NAMES" STUB_IP=10.0.0.69 run test01 configure; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'never on a replica' && ok "configure refused on a replica" \
  || bad "replica configure" "rc=$rc; $OUT"

# verify on d06: vikunja-mcp checked inside its container (it has no published port).
STUB_IP=10.0.0.65 run d06 verify; rc=$?
[ "$rc" -eq 0 ] && grep -q 'compose.vault.yml exec -T vikunja-mcp python -c' "$T/log" && echo "$OUT" | grep -q '(401)' \
  && ok "verify on d06: vikunja-mcp /metrics 200 and /mcp 401 from inside its container" || bad "verify d06" "rc=$rc; $OUT"
STUB_MCP="200 200" STUB_IP=10.0.0.65 run d06 verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'answered 200, not 401' && ok "verify on d06: an open /mcp fails" || bad "verify open mcp" "rc=$rc; $OUT"
STUB_IP=10.0.0.69 run test01 verify; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'exec' "$T/log" && ok "verify on a replica: vikunja only" || bad "verify replica" "rc=$rc; $OUT"

# Restore: a db with data is refused with the marker build_host.py reads as a skip.
mkdir -p "$T/dl/Ticketing/db" && touch "$T/dl/Ticketing/db/vikunja.db"
STUB_IP=10.0.0.65 run d06 restore; rc=$?
marker="$(python3 -c "import sys; sys.path.insert(0, '$REPO/scripts'); import build_host; print(build_host.RESTORE_NOT_EMPTY)")"
[ "$rc" -ne 0 ] && echo "$OUT" | grep -qF "$marker" && ! grep -q 'run --rm backup' "$T/log" \
  && ok "restore over a db with data: refused with build_host's skip marker" || bad "restore refusal" "rc=$rc; $OUT"
rm -rf "$T/dl/Ticketing"

# Restore with no backup in the mirror: fails before theOrg's restore runs.
STUB_IP=10.0.0.65 run d06 restore; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'No backup at' && ! grep -q 'run --rm backup' "$T/log" \
  && ok "restore with no mirror: a failure, not a skip" || bad "restore no mirror" "rc=$rc; $OUT"

# Restore from an OK mirror into an empty db: staging copied (old staging overwritten), then theOrg's restore.
mkdir -p "$T/d1/Ticketing/mirror" "$T/dl/Ticketing/backup"
echo "OK test" > "$T/d1/Ticketing/mirror/.backup-status"
echo new > "$T/d1/Ticketing/mirror/vikunja.db"
echo stale > "$T/dl/Ticketing/backup/old"
if $LOCK_OK; then
  STUB_IP=10.0.0.65 run d06 restore; rc=$?
  [ "$rc" -eq 0 ] && grep -q -- '--profile ops run --rm backup restore' "$T/log" \
    && [ "$(cat "$T/dl/Ticketing/backup/vikunja.db")" = new ] && [ ! -e "$T/dl/Ticketing/backup/old" ] \
    && ok "restore from an OK mirror: staging replaced, then theOrg's restore" || bad "restore" "rc=$rc; $OUT"
else
  skip "restore from an OK mirror"
fi
STUB_RUNNING=1 STUB_IP=10.0.0.65 run d06 restore; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'vikunja is running' && ok "restore refused while vikunja runs" \
  || bad "restore while running" "rc=$rc; $OUT"
rm -rf "$T/dl/Ticketing" "$T/d1/Ticketing"

# Seeded restore (backup/SEED from seed_ticketing.py): backup/ as it stands, no mirror read, SEED removed.
# No mirror exists here, so a mirror rsync would fail the case; the seeded path takes no lock.
mkdir -p "$T/dl/Ticketing/backup"
echo "OK 2026-10-18T00:00:00Z" > "$T/dl/Ticketing/backup/STATUS"
echo "SEED 2026-10-18T00:00:00Z from the Mini (OK 2026-10-18T00:00:00Z)" > "$T/dl/Ticketing/backup/SEED"
echo seeded > "$T/dl/Ticketing/backup/vikunja.db"
STUB_IP=10.0.0.65 run d06 restore; rc=$?
[ "$rc" -eq 0 ] && grep -q -- '--profile ops run --rm backup restore' "$T/log" && [ ! -e "$T/dl/Ticketing/backup/SEED" ] \
  && [ "$(cat "$T/dl/Ticketing/backup/vikunja.db")" = seeded ] && [ ! -e "$T/d1/Ticketing/mirror" ] \
  && ! echo "$OUT" | grep -q 'No backup at' && echo "$OUT" | grep -q 'restored from the seeded copy (SEED)' \
  && ok "seeded restore: theOrg's restore without the mirror, SEED removed" || bad "seeded restore" "rc=$rc; $OUT"
# SEED with a STATUS that is not OK: refused before any backup-image call, SEED kept.
echo "SEED 2026-10-18T00:00:00Z from the Mini (FAIL x)" > "$T/dl/Ticketing/backup/SEED"
echo "FAIL x" > "$T/dl/Ticketing/backup/STATUS"
STUB_IP=10.0.0.65 run d06 restore; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q "seeded copy's STATUS is not OK" && ! grep -q 'run --rm backup' "$T/log" \
  && [ -f "$T/dl/Ticketing/backup/SEED" ] && ok "seeded restore with STATUS not OK: refused, SEED kept" \
  || bad "seeded restore not OK" "rc=$rc; $OUT"
# No SEED: the mirror path (here no mirror, so its failure shows the mirror was used).
rm "$T/dl/Ticketing/backup/SEED"
echo "OK 2026-10-18T00:00:00Z" > "$T/dl/Ticketing/backup/STATUS"
STUB_IP=10.0.0.65 run d06 restore; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'No backup at' && ! grep -q 'run --rm backup' "$T/log" \
  && ok "restore without SEED: from the mirror, even with backup/STATUS OK" || bad "restore without SEED" "rc=$rc; $OUT"
rm -rf "$T/dl/Ticketing"

# Backup only on the host the name resolves to.
STUB_IP=10.0.0.65 STUB_RESOLVES=10.0.0.62 run d06 _backup; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'not to this host' && ! grep -q 'run --rm backup' "$T/log" \
  && ok "backup refused while the name reaches another host (before the cutover)" || bad "backup guard" "rc=$rc; $OUT"
STUB_IP=10.0.0.65 run d06 _backup; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'does not resolve' && ok "backup refused when the name does not resolve" \
  || bad "backup unresolved" "rc=$rc; $OUT"

# Backup on the serving host: backup, verify, then the mirror (STATUS OK written by the stubbed image here).
mkdir -p "$T/dl/Ticketing/backup" && echo "OK 2026-10-18T00:00:00Z" > "$T/dl/Ticketing/backup/STATUS"
if $LOCK_OK; then
  STUB_IP=10.0.0.65 STUB_RESOLVES=10.0.0.65 run d06 _backup; rc=$?
  [ "$rc" -eq 0 ] && grep -q 'run --rm backup backup' "$T/log" && grep -q 'run --rm backup verify' "$T/log" \
    && head -1 "$T/d1/Ticketing/mirror/.backup-status" | grep -q '^OK' && [ -f "$T/d1/Ticketing/mirror/STATUS" ] \
    && ok "backup on the serving host: image backup, verify, mirror OK" || bad "backup" "rc=$rc; $OUT"
else
  skip "backup on the serving host"
fi
rm "$T/dl/Ticketing/backup/STATUS"
STUB_IP=10.0.0.65 STUB_RESOLVES=10.0.0.65 run d06 _backup; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'STATUS is not OK' && ok "no STATUS OK: not mirrored" || bad "backup status" "rc=$rc; $OUT"

exit "$fail"
