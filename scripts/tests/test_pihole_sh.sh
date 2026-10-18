#!/bin/bash
# ns02/apps/pihole/pihole.sh against stubs (docker, hostname, mountpoint, sudo): the DHCP guard, the
# NAS hosts-file refusal, the backup filter and host guard, restore, and verify's checks. Nothing
# here reaches a host, the NAS or a registry. Run: bash scripts/tests/test_pihole_sh.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }
# backup_lib.sh's lock needs bash >= 4.1 ({fd} redirection) and flock, and its mirror GNU stat and
# rsync: the hosts have them, macOS does not. Without them the backup and restore cases are skipped.
LIB_OK=false
if command -v flock >/dev/null && stat -c %a / >/dev/null 2>&1 && [[ "$(rsync --version 2>/dev/null)" == rsync* ]] \
   && bash -c '[ "${BASH_VERSINFO[0]}" -ge 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }'; then
  LIB_OK=true
fi
skip() { echo "skip $1 (needs bash >= 4.1, flock, GNU stat and rsync; run on a host)"; }

APP="$T/home/scripts/ns02/apps/pihole"
mkdir -p "$T/home/scripts/docker" "$APP" "$T/bin" "$T/dl" "$T/d1" "$T/d2/pihole"
cp "$REPO/docker/backup_lib.sh" "$T/home/scripts/docker/"
cp "$REPO"/ns02/apps/pihole/{pihole.sh,compose.yml} "$APP/"
# common.env as a hostile one: it tries to turn DHCP on; pihole.sh must override it.
printf 'DOCKER_DL=%s\nDOCKER_D1=%s\nDOCKER_D2=%s\nDOCKER_UID=1003\nDOCKER_GID=1000\nPIHOLE_DHCP_ACTIVE=true\n' \
  "$T/dl" "$T/d1" "$T/d2" > "$T/home/scripts/docker/common.env"
# The NAS hosts file and dnsmasq file (documentation addresses only).
printf '127.0.0.1 localhost\n# lan\n192.0.2.10 host-a.example.org host-a\n192.0.2.11 host-b.example.org\n' > "$T/d2/pihole/hosts"
printf 'domain=example.org\n' > "$T/d2/pihole/03-lan-dns.conf"

# docker: logs each call with the DHCP value it was given; inspect prints STUB_STATE; exec answers
# cat /etc/hosts (STUB_HOSTS_IN), pihole-FTL --config (STUB_CNAMES, STUB_DHCP) and dig (STUB_ANSWERS:
# "name answer" lines; example.com answers unless STUB_NO_OUTSIDE).
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $* [dhcp=${PIHOLE_DHCP_ACTIVE:-unset}]" | sed -E "s#-f [^ ]*/compose.yml#-f compose.yml#; s# --project-directory [^ ]*##" >> "$STUB_LOG"
case "$*" in
  inspect*) echo "${STUB_STATE:-running healthy}" ;;
  "exec pihole-ns02 cat /etc/hosts") cat "${STUB_HOSTS_IN:?}" ;;
  "exec pihole-ns02 pihole-FTL --config dns.cnameRecords") echo "${STUB_CNAMES-[ alias.example.org,host-a.example.org, b.example.org,host-b.example.org ]}" ;;
  "exec pihole-ns02 pihole-FTL --config dhcp.active") echo "${STUB_DHCP:-false}" ;;
  "exec pihole-ns02 dig "*)
    name=$(echo "$*" | awk '{print $(NF-1)}')
    if [ "$name" = example.com ]; then [ -n "${STUB_NO_OUTSIDE:-}" ] || echo 203.0.113.5
    else awk -v n="$name" '$1 == n {print $2}' "${STUB_ANSWERS:?}"; fi ;;
esac
exit 0
EOF
cat > "$T/bin/hostname" <<'EOF'
#!/bin/bash
echo "$STUB_HOST"
EOF
cat > "$T/bin/mountpoint" <<'EOF'
#!/bin/bash
[ "$1" = -q ] && shift
[ -n "${STUB_MOUNTED:-}" ] && [ "$1" = "$STUB_MOUNTED" ]
EOF
cat > "$T/bin/sudo" <<'EOF'
#!/bin/bash
[ "$1" = -n ] && shift
"$@"
EOF
chmod +x "$T/bin/"*
printf 'alias.example.org host-a.example.org\nalias.example.org 192.0.2.10\nhost-a.example.org 192.0.2.10\n' > "$T/answers"

run() {   # run HOST SWITCH...: output in $OUT, docker calls in $T/log, status returned
  : > "$T/log"
  OUT="$(env HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_HOST="$1" STUB_MOUNTED="${STUB_MOUNTED-$T/d2}" \
    STUB_HOSTS_IN="${STUB_HOSTS_IN:-$T/d2/pihole/hosts}" STUB_ANSWERS="$T/answers" BACKUP_LOCK_DIR="$T" \
    PIHOLE_VERIFY_WAIT_S=0 bash "$APP/pihole.sh" "${@:2}" 2>&1 </dev/null)"
}

# The DHCP guard: true on ns01 only, whatever common.env or the caller's environment says.
run ns02 up; rc=$?
[ "$rc" -eq 0 ] && grep -q 'compose -p pihole-ns02 -f compose.yml up -d \[dhcp=false\]' "$T/log" \
  && ok "up on ns02: DHCP off, though common.env says true" || bad "ns02 up" "rc=$rc; $OUT; $(cat "$T/log")"
OUT="$(PIHOLE_DHCP_ACTIVE=true; export PIHOLE_DHCP_ACTIVE; run test01 up; echo "$OUT")"
grep -q 'up -d \[dhcp=false\]' "$T/log" && ! grep -q 'dhcp=true' "$T/log" \
  && ok "up on a replica (test01) with PIHOLE_DHCP_ACTIVE=true exported: DHCP off" || bad "replica dhcp" "$(cat "$T/log")"
run ns01 up; rc=$?
[ "$rc" -eq 0 ] && grep -q 'up -d \[dhcp=true\]' "$T/log" && ok "up on ns01: DHCP on" || bad "ns01 up" "rc=$rc; $(cat "$T/log")"
grep -qF -- '- FTLCONF_dhcp_active=${PIHOLE_DHCP_ACTIVE:-false}' "$REPO/ns02/apps/pihole/compose.yml" \
  && ok "compose: FTLCONF_dhcp_active defaults to false" || bad "compose dhcp default"
# Docker's own reading of the file, when compose is here (offline: config only).
if docker compose version >/dev/null 2>&1 && [ "$(command -v docker)" != "$T/bin/docker" ]; then
  got=$(env -u PIHOLE_DHCP_ACTIVE docker compose -f "$REPO/ns02/apps/pihole/compose.yml" config --format json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["pihole"]["environment"]["FTLCONF_dhcp_active"])' 2>/dev/null)
  [ "$got" = false ] && ok "docker compose config with PIHOLE_DHCP_ACTIVE unset: FTLCONF_dhcp_active is false" \
    || bad "compose config dhcp" "[$got]"
else
  echo "skip docker compose config (no docker compose here)"
fi
[ -f "$T/dl/pihole-ns02/etc-dnsmasq.d/03-lan-dns.conf" ] && ok "up copies 03-lan-dns.conf from the NAS" || bad "dnsmasq copy"

# The NAS hosts file: up refuses without it, before any docker call.
STUB_MOUNTED="" run ns02 up; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'not mounted' && [ ! -s "$T/log" ] \
  && ok "up with the NAS share not mounted: refused before any docker call" || bad "up unmounted" "rc=$rc; $OUT; $(cat "$T/log")"
mv "$T/d2/pihole/hosts" "$T/hosts.away"
run ns02 up; rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$T/log" ] && ok "up with the share mounted but no hosts file: refused" || bad "up no hosts" "rc=$rc; $OUT"
mv "$T/hosts.away" "$T/d2/pihole/hosts"

# Backup: only ns02 writes ns02's mirror.
run test01 backup; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'only ns02 writes' && [ ! -e "$T/d1/pihole-ns02" ] \
  && ok "backup on another host (a replica): refused, no mirror written" || bad "replica backup" "rc=$rc; $OUT"
D="$T/dl/pihole-ns02"
printf 'x\n' > "$D/etc-pihole/pihole.toml"; printf 'g\n' > "$D/etc-pihole/gravity.db"
printf 'q\n' > "$D/etc-pihole/pihole-FTL.db"; printf 'w\n' > "$D/etc-pihole/pihole-FTL.db-wal"
mkdir -p "$D/pihole-ns02/pihole-ns02"; printf 'old\n' > "$D/pihole-ns02/pihole-ns02/stale"; printf 'n\n' > "$D/notes.txt"
if $LIB_OK; then
  M="$T/d1/pihole-ns02/mirror"
  run ns02 backup; rc=$?
  have=$(cd "$M" 2>/dev/null && find . -type f ! -name '.backup-*' | sort | tr '\n' ' ')
  want="./etc-dnsmasq.d/03-lan-dns.conf ./etc-pihole/gravity.db ./etc-pihole/pihole.toml "
  [ "$rc" -eq 0 ] && [ "$have" = "$want" ] && grep -q '^OK' "$M/.backup-status" \
    && ok "backup on ns02: etc-pihole (no query history) and etc-dnsmasq.d only, status OK" || bad "backup" "rc=$rc; [$have]; $OUT"
  run ns02 restore; rc=$?
  [ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'is not empty; refusing to restore over it' \
    && ok "restore over data: refused with the message build_host.py reads as a skip" || bad "restore over data" "rc=$rc; $OUT"
  rm -rf "$D"
  run ns02 restore; rc=$?
  [ "$rc" -eq 0 ] && [ -f "$D/etc-pihole/pihole.toml" ] && [ -f "$D/etc-dnsmasq.d/03-lan-dns.conf" ] && [ ! -e "$D/etc-pihole/pihole-FTL.db" ] \
    && ok "restore into an empty data dir: the mirror's files back" || bad "restore" "rc=$rc; $OUT"
else
  skip "backup filter, restore refusal, restore"
fi

# verify.
run ns02 verify; rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -q '^\[OK\] pihole: .*outside answer; dhcp.active false' && grep -q 'dig .* example.com' "$T/log" \
  && ok "verify on ns02: healthy, hosts file, CNAME, hosts-file name, outside name, DHCP off" || bad "verify ns02" "rc=$rc; $OUT"
! echo "$OUT" | grep -q 'host-a\|192.0.2' && ok "verify prints no name or address from the hosts file" || bad "verify leaks" "$OUT"
run test01 verify; rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -q 'outside names not checked' && ! grep -q 'example.com' "$T/log" \
  && ok "verify on a replica: local answers only (egress blocked)" || bad "verify replica" "rc=$rc; $OUT"
STUB_DHCP=true run ns02 verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q "dhcp.active is 'true', this host should have false" \
  && ok "verify on ns02 with DHCP on: FAIL" || bad "verify dhcp on" "rc=$rc; $OUT"
STUB_DHCP=false run ns01 verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q "should have true" && ok "verify on ns01 with DHCP off: FAIL" || bad "verify ns01 dhcp" "rc=$rc; $OUT"
printf '192.0.2.99 other\n' > "$T/other-hosts"
STUB_HOSTS_IN="$T/other-hosts" run ns02 verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'not the NAS hosts file' && ok "verify with another /etc/hosts in the container: FAIL" \
  || bad "verify hosts mismatch" "rc=$rc; $OUT"
STUB_CNAMES="[]" run ns02 verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'no CNAME' && ok "verify with no CNAME (not restored): FAIL" || bad "verify no cname" "rc=$rc; $OUT"
STUB_NO_OUTSIDE=1 run ns02 verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'outside name' && ok "verify on ns02 with no outside answer: FAIL" || bad "verify outside" "rc=$rc; $OUT"
STUB_STATE="running unhealthy" run ns02 verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q "is 'running unhealthy'" && ok "verify with the container unhealthy: FAIL" || bad "verify unhealthy" "rc=$rc; $OUT"
printf 'alias.example.org host-a.example.org\nhost-a.example.org 192.0.2.77\n' > "$T/answers"
run ns02 verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'hosts-file name does not answer with its address' \
  && ok "verify with a hosts-file name answering another address: FAIL" || bad "verify hosts answer" "rc=$rc; $OUT"

# build_host.py finds the restore and verify switches (its app_has pattern).
for sw in restore verify backup; do
  grep -qE "^[[:space:]]+([a-z_|-]+\|)?$sw(\|[a-z_|-]+)?\)" "$REPO/ns02/apps/pihole/pihole.sh" \
    && ok "build_host.py's switch pattern finds $sw" || bad "switch $sw"
done

exit "$fail"
