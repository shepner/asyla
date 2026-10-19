#!/bin/bash
# ns02/apps/pihole/pihole.sh and ns01/apps/pihole/pihole.sh against stubs (docker, hostname,
# mountpoint, sudo, ss): the DHCP guard, the NAS hosts-file refusal, the backup filter and host guard,
# restore, verify's checks (ns01: the udp/67 listener), the admin password (stdin only; the value
# never in a docker argument) and the allowlist; ns01's copy against ns02's (only DHCP may differ).
# Nothing here reaches a host, the NAS or a registry.
# Run: bash scripts/tests/test_pihole_sh.sh [ns02|ns01]   (no argument: both trees)
set -uo pipefail

if [ $# -eq 0 ]; then
  rc=0
  for t in ns02 ns01; do echo "== $t"; bash "${BASH_SOURCE[0]}" "$t" || rc=1; done
  exit "$rc"
fi
case "$1" in ns01|ns02) TREE="$1" ;; *) echo "usage: $0 [ns02|ns01]" >&2; exit 2 ;; esac
CT="pihole-$TREE"                                          # the container and compose project
DHCP_ON=$([ "$TREE" = ns01 ] && echo true || echo false)   # what verify on the tree's own host expects

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

APP="$T/home/scripts/$TREE/apps/pihole"
mkdir -p "$T/home/scripts/docker" "$APP" "$T/bin" "$T/dl" "$T/d1" "$T/d2/pihole"
cp "$REPO/docker/backup_lib.sh" "$T/home/scripts/docker/"
cp "$REPO"/$TREE/apps/pihole/{pihole.sh,compose.yml,compose.admin-login.yml,allowlist} "$APP/"
# common.env as a hostile one: it tries to turn DHCP on and to pass a password; pihole.sh must
# override both.
printf 'DOCKER_DL=%s\nDOCKER_D1=%s\nDOCKER_D2=%s\nDOCKER_UID=1003\nDOCKER_GID=1000\nPIHOLE_DHCP_ACTIVE=true\nexport FTLCONF_webserver_api_password=example_value\n' \
  "$T/dl" "$T/d1" "$T/d2" > "$T/home/scripts/docker/common.env"
# The NAS hosts file and dnsmasq file (documentation addresses only).
printf '127.0.0.1 localhost\n# lan\n192.0.2.10 host-a.example.org host-a\n192.0.2.11 host-b.example.org\n' > "$T/d2/pihole/hosts"
printf 'domain=example.org\n' > "$T/d2/pihole/03-lan-dns.conf"

# docker: logs each call with the DHCP value it was given and whether a password is in its
# environment (pw=set:LENGTH, never the value); inspect prints STUB_STATE; exec answers
# cat /etc/hosts (STUB_HOSTS_IN), pihole-FTL --config (STUB_CNAMES, STUB_DHCP), the domainlist query
# (STUB_ALLOWED), an API login (true when stdin is STUB_PW_OK) and dig (STUB_ANSWERS: "name answer"
# lines; example.com answers unless STUB_NO_OUTSIDE). An up with a non-empty password writes a hash
# into pihole.toml, as Pi-hole does.
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
pw="${FTLCONF_webserver_api_password+set:${#FTLCONF_webserver_api_password}}"
echo "docker $* [dhcp=${PIHOLE_DHCP_ACTIVE:-unset}] [pw=$pw]" \
  | sed -E "s#-f [^ ]*/compose.yml#-f compose.yml#; s#-f [^ ]*/compose.admin-login.yml#-f compose.admin-login.yml#; s# --project-directory [^ ]*##" >> "$STUB_LOG"
case "$*" in
  compose*" up -d")
    if [ -n "${FTLCONF_webserver_api_password:-}" ]; then
      mkdir -p "$STUB_DL/$STUB_APP/etc-pihole"; printf '    pwhash = "$BALLOON-SHA256$stub"\n' > "$STUB_DL/$STUB_APP/etc-pihole/pihole.toml"
    fi ;;
  inspect*) echo "${STUB_STATE:-running healthy}" ;;
  "exec -i $STUB_APP sh -c "*) [ "$(cat)" = "${STUB_PW_OK:-}" ] && echo true || echo false ;;
  "exec $STUB_APP pihole-FTL sqlite3 "*) printf '%s\n' "${STUB_ALLOWED-trace.svc.ui.com metrics.icloud.com}" | tr ' ' '\n' ;;
  "exec $STUB_APP cat /etc/hosts") cat "${STUB_HOSTS_IN:?}" ;;
  "exec $STUB_APP pihole-FTL --config dns.cnameRecords") echo "${STUB_CNAMES-[ alias.example.org,host-a.example.org, b.example.org,host-b.example.org ]}" ;;
  "exec $STUB_APP pihole-FTL --config dhcp.active") echo "${STUB_DHCP:?}" ;;
  "exec $STUB_APP dig "*)
    name=$(echo "$*" | awk '{print $(NF-1)}')
    if [ "$name" = example.com ]; then [ -n "${STUB_NO_OUTSIDE:-}" ] || echo 203.0.113.5
    else awk -v n="$name" '$1 == n {print $2}' "${STUB_ANSWERS:?}"; fi ;;
esac
exit 0
EOF
# ss -Hlun: a udp/67 listener when STUB_SS67 is set (run sets it on ns01 unless a case says otherwise).
cat > "$T/bin/ss" <<'EOF'
#!/bin/bash
echo "UNCONN 0 0 0.0.0.0:53 0.0.0.0:*"
[ -n "${STUB_SS67:-}" ] && echo "UNCONN 0 0 0.0.0.0:67 0.0.0.0:*"
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
printf 'alias.example.org host-a.example.org\nalias.example.org 192.0.2.10\nhost-a.example.org 192.0.2.10\nwpad 255.255.255.255\n' > "$T/answers"

# run HOST SWITCH...: output in $OUT, docker calls in $T/log, status returned; stdin: $STDIN; RUN_ERR=/dev/null:
# stdout only. A consistent world unless a case says otherwise: on ns01, dhcp.active true and udp/67 listening.
run() {
  : > "$T/log"
  local on=; [ "$1" = ns01 ] && on=1
  OUT="$(printf '%s' "${STDIN:-}" | env HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_HOST="$1" STUB_MOUNTED="${STUB_MOUNTED-$T/d2}" \
    STUB_APP="$CT" STUB_DHCP="${STUB_DHCP-$([ -n "$on" ] && echo true || echo false)}" STUB_SS67="${STUB_SS67-$on}" \
    STUB_HOSTS_IN="${STUB_HOSTS_IN:-$T/d2/pihole/hosts}" STUB_ANSWERS="$T/answers" STUB_DL="$T/dl" BACKUP_LOCK_DIR="$T" \
    PIHOLE_VERIFY_WAIT_S=0 bash "$APP/pihole.sh" "${@:2}" 2>"${RUN_ERR:-/dev/stdout}")"
}

# The DHCP guard: true on ns01 only, whatever common.env or the caller's environment says.
run ns02 up; rc=$?
[ "$rc" -eq 0 ] && grep -qE "compose -p $CT -f compose.yml( -f compose.admin-login.yml)? up -d \\[dhcp=false\\]" "$T/log" \
  && ok "up on ns02: DHCP off, though common.env says true" || bad "ns02 up" "rc=$rc; $OUT; $(cat "$T/log")"
OUT="$(PIHOLE_DHCP_ACTIVE=true; export PIHOLE_DHCP_ACTIVE; run test01 up; echo "$OUT")"
grep -q 'up -d \[dhcp=false\]' "$T/log" && ! grep -q 'dhcp=true' "$T/log" \
  && ok "up on a replica (test01) with PIHOLE_DHCP_ACTIVE=true exported: DHCP off" || bad "replica dhcp" "$(cat "$T/log")"
run ns01 up; rc=$?
[ "$rc" -eq 0 ] && grep -q 'up -d \[dhcp=true\]' "$T/log" && ok "up on ns01: DHCP on" || bad "ns01 up" "rc=$rc; $(cat "$T/log")"
grep -qF -- '- FTLCONF_dhcp_active=${PIHOLE_DHCP_ACTIVE:-false}' "$REPO/$TREE/apps/pihole/compose.yml" \
  && ok "compose: FTLCONF_dhcp_active defaults to false" || bad "compose dhcp default"
# Docker's own reading of the file, when compose is here (offline: config only).
if docker compose version >/dev/null 2>&1 && [ "$(command -v docker)" != "$T/bin/docker" ]; then
  got=$(env -u PIHOLE_DHCP_ACTIVE docker compose -f "$REPO/$TREE/apps/pihole/compose.yml" config --format json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["pihole"]["environment"]["FTLCONF_dhcp_active"])' 2>/dev/null)
  [ "$got" = false ] && ok "docker compose config with PIHOLE_DHCP_ACTIVE unset: FTLCONF_dhcp_active is false" \
    || bad "compose config dhcp" "[$got]"
else
  echo "skip docker compose config (no docker compose here)"
fi
[ -f "$T/dl/$CT/etc-dnsmasq.d/03-lan-dns.conf" ] && ok "up copies 03-lan-dns.conf from the NAS" || bad "dnsmasq copy"

# The NAS hosts file: up refuses without it, before any docker call.
STUB_MOUNTED="" run $TREE up; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'not mounted' && [ ! -s "$T/log" ] \
  && ok "up with the NAS share not mounted: refused before any docker call" || bad "up unmounted" "rc=$rc; $OUT; $(cat "$T/log")"
mv "$T/d2/pihole/hosts" "$T/hosts.away"
run $TREE up; rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$T/log" ] && ok "up with the share mounted but no hosts file: refused" || bad "up no hosts" "rc=$rc; $OUT"
mv "$T/hosts.away" "$T/d2/pihole/hosts"

# Backup: only the tree's host writes its mirror.
run test01 backup; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q "only $TREE writes" && [ ! -e "$T/d1/$CT" ] \
  && ok "backup on another host (a replica): refused, no mirror written" || bad "replica backup" "rc=$rc; $OUT"
D="$T/dl/$CT"
printf 'x\n' > "$D/etc-pihole/pihole.toml"; printf 'g\n' > "$D/etc-pihole/gravity.db"
printf 'q\n' > "$D/etc-pihole/pihole-FTL.db"; printf 'w\n' > "$D/etc-pihole/pihole-FTL.db-wal"
printf 'c\n' > "$D/etc-pihole/cli_pw"; printf 'lease\n' > "$D/etc-pihole/dhcp.leases"; printf 'l\n' > "$D/etc-pihole/logrotate"
mkdir -p "$D/$CT/$CT"; printf 'old\n' > "$D/$CT/$CT/stale"; printf 'n\n' > "$D/notes.txt"
if $LIB_OK; then
  M="$T/d1/$CT/mirror"
  run $TREE backup; rc=$?
  have=$(cd "$M" 2>/dev/null && find . -type f ! -name '.backup-*' | sort | tr '\n' ' ')
  want="./etc-dnsmasq.d/03-lan-dns.conf ./etc-pihole/dhcp.leases ./etc-pihole/gravity.db ./etc-pihole/pihole.toml "
  [ "$rc" -eq 0 ] && [ "$have" = "$want" ] && grep -q '^OK' "$M/.backup-status" \
    && ok "backup on $TREE: etc-pihole (no query history, cli_pw, logrotate; the DHCP leases kept) and etc-dnsmasq.d only, status OK" || bad "backup" "rc=$rc; [$have]; $OUT"
  run $TREE restore; rc=$?
  [ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'is not empty; refusing to restore over it' \
    && ok "restore over data: refused with the message build_host.py reads as a skip" || bad "restore over data" "rc=$rc; $OUT"
  rm -rf "$D"
  run $TREE restore; rc=$?
  [ "$rc" -eq 0 ] && [ -f "$D/etc-pihole/pihole.toml" ] && [ -f "$D/etc-dnsmasq.d/03-lan-dns.conf" ] && [ ! -e "$D/etc-pihole/pihole-FTL.db" ] \
    && ok "restore into an empty data dir: the mirror's files back" || bad "restore" "rc=$rc; $OUT"
else
  skip "backup filter, restore refusal, restore"
fi

# verify.
run $TREE verify; rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -q "^\[OK\] pihole: .*outside answer; dhcp.active $DHCP_ON" && grep -q 'dig .* example.com' "$T/log" \
  && ok "verify on $TREE: healthy, hosts file, CNAME, hosts-file name, outside name, DHCP $DHCP_ON" || bad "verify $TREE" "rc=$rc; $OUT"
! echo "$OUT" | grep -q 'host-a\|192.0.2' && ok "verify prints no name or address from the hosts file" || bad "verify leaks" "$OUT"
run test01 verify; rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -q 'outside names not checked' && ! grep -q 'example.com' "$T/log" \
  && ok "verify on a replica: local answers only (egress blocked)" || bad "verify replica" "rc=$rc; $OUT"
STUB_DHCP=true run ns02 verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q "dhcp.active is 'true', this host should have false" \
  && ok "verify on ns02 with DHCP on: FAIL" || bad "verify dhcp on" "rc=$rc; $OUT"
STUB_DHCP=false run ns01 verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q "should have true" && ok "verify on ns01 with DHCP off: FAIL" || bad "verify ns01 dhcp" "rc=$rc; $OUT"
if [ "$TREE" = ns01 ]; then
  STUB_SS67="" run ns01 verify; rc=$?
  [ "$rc" -ne 0 ] && echo "$OUT" | grep -q "udp/67 listener absent, this host should have DHCP true" \
    && ok "verify on ns01 with no udp/67 listener: FAIL" || bad "verify ns01 no 67" "rc=$rc; $OUT"
  STUB_SS67=1 run test01 verify; rc=$?
  [ "$rc" -ne 0 ] && echo "$OUT" | grep -q "udp/67 listener present, this host should have DHCP false" \
    && ok "verify on a replica with a udp/67 listener: FAIL" || bad "verify replica 67" "rc=$rc; $OUT"
  run ns01 verify; rc=$?
  [ "$rc" -eq 0 ] && echo "$OUT" | grep -q 'dhcp.active true, udp/67 listening' \
    && ok "verify on ns01: dhcp.active true, udp/67 listening" || bad "verify ns01 67" "rc=$rc; $OUT"
  run test01 verify; rc=$?
  [ "$rc" -eq 0 ] && echo "$OUT" | grep -q 'dhcp.active false, udp/67 closed' \
    && ok "verify on a replica of ns01: dhcp.active false, udp/67 closed" || bad "verify replica ns01" "rc=$rc; $OUT"
  C="$REPO/ns01/apps/pihole/compose.yml"; miss=""
  for kv in dhcp_start=10.0.0.100 dhcp_end=10.0.0.254 dhcp_router=10.0.0.1 dhcp_leaseTime=6h dhcp_ipv6=false dhcp_rapidCommit=false; do
    grep -qxF -- "      - FTLCONF_$kv" "$C" || miss+=" $kv"
  done
  ! grep -q 'FTLCONF_dhcp_hosts' "$C" && [ -z "$miss" ] \
    && ok "ns01 compose: range, router, lease time, no IPv6 pinned; reservations not pinned (operator Q5)" || bad "ns01 dhcp pins" "[$miss]"
  # ns01's copy is ns02's with the names swapped; only DHCP lines may differ (the two must not drift).
  PIHOLE_DRIFT_OK='dhcp|udp/67|l67|lease|reservation|this host is ns01|copy differs only|image:|^[<>] *# *(ns0[12]|the DHCP guard|host\) never|replica\))|network\)\.|Names and records are never|2026\.05\.0|netmask is left|option 6, from the NAS'
  swap() { sed -e 's/ns01/@A@/g; s/ns02/ns01/g; s/@A@/ns02/g; s/NS01/@B@/g; s/NS02/NS01/g; s/@B@/NS02/g' \
               -e 's/10\.0\.0\.11/@C@/g; s/10\.0\.0\.10/10.0.0.11/g; s/@C@/10.0.0.10/g' "$1"; }
  for f in pihole.sh compose.yml compose.admin-login.yml; do
    extra=$(diff <(swap "$REPO/ns02/apps/pihole/$f") "$REPO/ns01/apps/pihole/$f" | grep '^[<>]' \
              | grep -viE "$PIHOLE_DRIFT_OK" || true)
    [ -z "$extra" ] && ok "ns01's $f is ns02's but for DHCP" || bad "ns01 $f drift" "$extra"
  done
  doms() { grep -vE '^[[:space:]]*(#|$)' "$1"; }
  [ "$(doms "$REPO/ns01/apps/pihole/allowlist")" = "$(doms "$REPO/ns02/apps/pihole/allowlist")" ] \
    && ok "ns01 and ns02 allow the same domains" || bad "allowlist drift"
fi
printf '192.0.2.99 other\n' > "$T/other-hosts"
STUB_HOSTS_IN="$T/other-hosts" run $TREE verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'not the NAS hosts file' && ok "verify with another /etc/hosts in the container: FAIL" \
  || bad "verify hosts mismatch" "rc=$rc; $OUT"
STUB_CNAMES="[]" run $TREE verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'no CNAME' && ok "verify with no CNAME (not restored): FAIL" || bad "verify no cname" "rc=$rc; $OUT"
STUB_NO_OUTSIDE=1 run $TREE verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'outside name' && ok "verify on $TREE with no outside answer: FAIL" || bad "verify outside" "rc=$rc; $OUT"
STUB_STATE="running unhealthy" run $TREE verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q "is 'running unhealthy'" && ok "verify with the container unhealthy: FAIL" || bad "verify unhealthy" "rc=$rc; $OUT"
STUB_ALLOWED="trace.svc.ui.com" run $TREE verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'allowlist: metrics.icloud.com is not an enabled exact allow' \
  && ok "verify with an allowlist domain missing: FAIL" || bad "verify allowlist" "rc=$rc; $OUT"
printf 'alias.example.org host-a.example.org\nhost-a.example.org 192.0.2.10\n' > "$T/answers.nowpad"
cp "$T/answers" "$T/answers.keep"; cp "$T/answers.nowpad" "$T/answers"
run $TREE verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'wpad does not answer' && ok "verify with no wpad record: FAIL" || bad "verify wpad" "rc=$rc; $OUT"
cp "$T/answers.keep" "$T/answers"
printf 'alias.example.org host-a.example.org\nhost-a.example.org 192.0.2.77\nwpad 255.255.255.255\n' > "$T/answers"
run $TREE verify; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'hosts-file name does not answer with its address' \
  && ok "verify with a hosts-file name answering another address: FAIL" || bad "verify hosts answer" "rc=$rc; $OUT"
cp "$T/answers.keep" "$T/answers"

# The admin password. compose.yml never sets it (set that way it is read-only and an empty value
# removes it at every start); compose.admin-login.yml passes it from pihole.sh's environment.
! grep -vE '^[[:space:]]*#' "$REPO/$TREE/apps/pihole/compose.yml" | grep -q 'FTLCONF_webserver_api_password' \
  && ok "compose.yml sets no FTLCONF_webserver_api_password" || bad "compose password line"
if docker compose version >/dev/null 2>&1 && [ "$(command -v docker)" != "$T/bin/docker" ]; then
  P="$REPO/$TREE/apps/pihole"
  got=$(env FTLCONF_webserver_api_password=example_value docker compose -f "$P/compose.yml" config --format json 2>/dev/null \
        | python3 -c 'import json,sys; print("FTLCONF_webserver_api_password" in json.load(sys.stdin)["services"]["pihole"]["environment"])' 2>/dev/null)
  got2=$(env FTLCONF_webserver_api_password=example_value docker compose -f "$P/compose.yml" -f "$P/compose.admin-login.yml" config --format json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["pihole"]["environment"]["FTLCONF_webserver_api_password"] == "example_value")' 2>/dev/null)
  [ "$got" = False ] && [ "$got2" = True ] \
    && ok "docker compose config: the password only with compose.admin-login.yml, from the environment" || bad "compose password config" "[$got] [$got2]"
else
  echo "skip docker compose config of the password file (no docker compose here)"
fi
D="$T/dl/$CT"; rm -rf "$D"
run $TREE up; rc=$?
[ "$rc" -eq 0 ] && grep -q 'compose.admin-login.yml up -d .* \[pw=set:0\]' "$T/log" && echo "$OUT" | grep -q 'no admin password set' \
  && ok "up with no password hash: an empty password (no random one in the log), and a warning" || bad "up no hash" "rc=$rc; $OUT; $(cat "$T/log")"
grep -q "exec $CT pihole allow -q trace.svc.ui.com metrics.icloud.com --comment" "$T/log" \
  && ok "up adds the allowlist's domains (pihole allow)" || bad "up allowlist" "$(cat "$T/log")"
STDIN="" run $TREE password; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'no value on stdin' && [ ! -s "$T/log" ] \
  && ok "password with nothing on stdin: refused before any docker call" || bad "password empty" "rc=$rc; $OUT"
PWV="example_value"
STDIN="$PWV"$'\n' STUB_PW_OK="$PWV" run $TREE password; rc=$?
ups=$(grep ' up -d ' "$T/log")
[ "$rc" -eq 0 ] && echo "$OUT" | grep -q '^\[OK\] password: set' \
  && [ "$(echo "$ups" | sed -n 1p | grep -c "compose.admin-login.yml up -d .*\[pw=set:${#PWV}\]")" = 1 ] \
  && [ "$(echo "$ups" | sed -n 2p | grep -c -- '-f compose.yml up -d .*\[pw=\]')" = 1 ] \
  && grep -q '^ *pwhash = "' "$D/etc-pihole/pihole.toml" \
  && ok "password from stdin: one start with the value, then one without, and it logs in" || bad "password" "rc=$rc; $OUT; $(cat "$T/log")"
! grep -qF "$PWV" "$T/log" && ! echo "$OUT" | grep -qF "$PWV" && ! grep -rqF "$PWV" "$T/dl" \
  && ok "password: the value is in no docker argument, no output and no file" || bad "password leak"
run $TREE up; rc=$?
[ "$rc" -eq 0 ] && grep -q -- '-f compose.yml up -d .*\[pw=\]' "$T/log" && ! grep -q 'compose.admin-login.yml' "$T/log" \
  && ! echo "$OUT" | grep -q 'no admin password' \
  && ok "up with a hash: compose.yml only, no password in the environment (common.env's is dropped)" || bad "up hash" "rc=$rc; $OUT; $(cat "$T/log")"
OUT="$(FTLCONF_webserver_api_password=example_user; export FTLCONF_webserver_api_password; run $TREE up; echo "$OUT")"
grep -q '\[pw=\]' "$T/log" && ! grep -q 'pw=set' "$T/log" && ok "up with a password exported by the caller: not passed" || bad "up caller pw" "$(cat "$T/log")"
STDIN="wrong"$'\n' STUB_PW_OK="$PWV" run $TREE password; rc=$?
[ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'does not log in' && ok "password whose value does not log in afterwards: FAIL" || bad "password no login" "rc=$rc; $OUT"
printf 'x\n' > "$D/etc-pihole/pihole.toml"
run $TREE verify; rc=$?
[ "$rc" -eq 0 ] && echo "$OUT" | grep -q 'WARN.*no admin password set' && ok "verify with no password: a warning, not a failure" || bad "verify no pw" "rc=$rc; $OUT"
RUN_ERR=/dev/null run $TREE verify; rc=$?
[ "$rc" -eq 0 ] && [ "$(echo "$OUT" | grep -n '^\[WARN\] pihole: no admin password set' | cut -d: -f1)" = 1 ] \
  && [ "$(echo "$OUT" | grep -n '^\[OK\] pihole: ' | cut -d: -f1)" = 2 ] \
  && ok "verify with no password: the warning on stdout, just before the [OK] line" || bad "verify no pw stdout" "rc=$rc; $OUT"

# build_host.py finds the restore and verify switches (its app_has pattern).
for sw in restore verify backup; do
  grep -qE "^[[:space:]]+([a-z_|-]+\|)?$sw(\|[a-z_|-]+)?\)" "$REPO/$TREE/apps/pihole/pihole.sh" \
    && ok "build_host.py's switch pattern finds $sw" || bad "switch $sw"
done

exit "$fail"
