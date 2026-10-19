#!/bin/bash
# Pi-hole DNS server on ns01. Usage: pihole.sh [switch ...]  (up|down|restart|backup|restore|verify|password|update|refresh|logs)
# Switches can be combined (e.g. down backup up). Loads ~/scripts/docker/common.env.
#
# Data: ${DOCKER_DL}/pihole-ns01/{etc-pihole,etc-dnsmasq.d}. From the NAS, by design (central,
# snapshotted, reachable when all else is down; never in a repo): ${DOCKER_D2}/pihole/hosts,
# mounted as the container's /etc/hosts, and 03-lan-dns.conf, copied into etc-dnsmasq.d at up.
# Backup: one rsync mirror at ${DOCKER_D1}/pihole-ns01/mirror (docker/backup_lib.sh) of
# etc-pihole/ and etc-dnsmasq.d/ only, without pihole-FTL.db (query history: a live SQLite file,
# not needed to rebuild); only ns01 itself writes it. Restore: from that mirror, into an empty
# data dir (build_host.py's restore phase, before up).
# DHCP guard: PIHOLE_DHCP_ACTIVE is true only when this host is ns01, whatever the environment says;
# compose's FTLCONF_dhcp_active defaults to false. So a copy of this app (a test01 replica, a wrong
# host) never serves DHCP, and verify checks it (dhcp.active, and a udp/67 listener only on ns01).
# ns01 is the LAN's DHCP server: range, router and lease time are pinned in compose.yml; the
# reservations live in pihole.toml and the leases in etc-pihole/dhcp.leases, both in the mirror.
# Admin password: `pihole.sh password` reads it from stdin (never argv) and starts the container once
# with it in the environment (compose.admin-login.yml); Pi-hole keeps only the hash in pihole.toml, so
# every later start, and the restore, keep it. The value lives in OpenBao; the asyla/pihole CNAME
# pipeline needs the same value (GitLab CI variable PIHOLE_API_PASSWORD_NS01).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
PASSWORD_FILE="$SCRIPT_DIR/compose.admin-login.yml"
ALLOWLIST="$SCRIPT_DIR/allowlist"
TREE_HOST="ns01"                 # the host this tree is for; anywhere else it runs as a replica
APP="pihole-ns01"
SELF_FQDN="$TREE_HOST.asyla.org"  # compose.yml's hostname: Pi-hole answers it itself (dns.reply.host)
SCREEN_APP="$APP"                # run_detached_if_interactive's session name

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
. "$HOME/scripts/docker/backup_lib.sh"
# The password reaches Pi-hole only through do_password; never from common.env or the caller.
unset FTLCONF_webserver_api_password PIHOLE_API_PASSWORD

DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"
DOCKER_D2="${DOCKER_D2:-/mnt/nas/data2/docker}"
APP_ROOT="$DOCKER_DL/$APP"
BACKUP_DIR="$DOCKER_D1/$APP/mirror"
NAS_DIR="$DOCKER_D2/pihole"
HOSTS_FILE="$NAS_DIR/hosts"
THIS_HOST="$(hostname -s)"
if [ "$THIS_HOST" = "ns01" ]; then PIHOLE_DHCP_ACTIVE=true; else PIHOLE_DHCP_ACTIVE=false; fi
export DOCKER_DL DOCKER_D1 DOCKER_D2 LOCAL_TZ DOCKER_UID DOCKER_GID PIHOLE_DHCP_ACTIVE

# What the mirror holds: etc-pihole/ (pihole.toml: settings, CNAMEs, reservations; gravity.db:
# lists and groups) and etc-dnsmasq.d/, never the query history or anything else in the data dir.
# Also not cli_pw (a credential FTL makes anew at each start) and logrotate (root-only; the image
# writes it at each start).
BACKUP_FILTER=(--exclude=/etc-pihole/pihole-FTL.db '--exclude=/etc-pihole/pihole-FTL.db-*'
               --exclude=/etc-pihole/cli_pw --exclude=/etc-pihole/logrotate
               '--include=/etc-pihole/***' '--include=/etc-dnsmasq.d/***' '--exclude=*')

run_compose() {
  docker compose -p "$APP" -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

# compose.yml plus compose.admin-login.yml: FTLCONF_webserver_api_password comes from this environment.
run_compose_password() {
  docker compose -p "$APP" -f "$COMPOSE_FILE" -f "$PASSWORD_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

# True when pihole.toml holds a password hash (Pi-hole writes pwhash = "" when there is none).
password_is_set() {
  local toml="$APP_ROOT/etc-pihole/pihole.toml" re='^[[:space:]]*pwhash = "[^"]'
  grep -qE "$re" "$toml" 2>/dev/null || sudo -n grep -qE "$re" "$toml" 2>/dev/null
}

# Waits up to PIHOLE_VERIFY_WAIT_S (120 s) while the container is starting; sets st.
wait_started() {
  local waited=0 wait_s="${PIHOLE_VERIFY_WAIT_S:-120}"
  while :; do
    st=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$APP" 2>/dev/null || echo "absent")
    [ "$st" = "running starting" ] && [ "$waited" -lt "$wait_s" ] || break
    sleep 5; waited=$((waited + 5))
  done
  case "$st" in "running healthy"|"running none") return 0 ;; *) return 1 ;; esac
}

# The domains in ./allowlist, one per line (# comments).
allowlist_domains() {
  grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST" 2>/dev/null | tr -d ' \t' || true
}

remove_stale_container() {
  docker rm -f "$APP" 2>/dev/null || true
}

# The NAS hosts file must be there before the container starts: if the share is not mounted,
# Docker makes a directory at the bind-mount source and the container does not start.
require_nas_hosts() {
  if ! mountpoint -q "$DOCKER_D2" || [ ! -f "$HOSTS_FILE" ]; then
    echo "[ERROR] $HOSTS_FILE is not there (NAS share $DOCKER_D2 not mounted?); not starting Pi-hole" >&2
    return 1
  fi
}

do_up() {
  require_nas_hosts
  mkdir -p "$APP_ROOT/etc-pihole" "$APP_ROOT/etc-dnsmasq.d"
  sudo chown -R "${DOCKER_UID:-1003}:${DOCKER_GID:-1000}" "$APP_ROOT/etc-pihole" "$APP_ROOT/etc-dnsmasq.d" 2>/dev/null || true
  if [ -f "$NAS_DIR/03-lan-dns.conf" ]; then
    echo "[INFO] Copying 03-lan-dns.conf from the NAS"
    cp "$NAS_DIR/03-lan-dns.conf" "$APP_ROOT/etc-dnsmasq.d/" 2>/dev/null \
      || sudo cp "$NAS_DIR/03-lan-dns.conf" "$APP_ROOT/etc-dnsmasq.d/"
  fi
  remove_stale_container
  echo "[INFO] Starting Pi-hole (DHCP: $PIHOLE_DHCP_ACTIVE)"
  if [ "${1:-}" = --password ]; then
    run_compose_password up -d                 # do_password: the new value is in the environment
  elif password_is_set; then
    run_compose up -d
  else
    # No hash yet (a new or restored data dir without one): an empty value keeps it that way. Without
    # it the image would make up a random password and print it to the container log.
    echo "[WARN] no admin password set: set one with pihole.sh password (value on stdin)"
    FTLCONF_webserver_api_password="" run_compose_password up -d
  fi
  apply_allowlist
}

# Adds ./allowlist's domains as exact allows (pihole allow: a no-op for one already there).
apply_allowlist() {
  local domains
  domains=$(allowlist_domains | tr '\n' ' ')
  [ -n "${domains// /}" ] || return 0
  if ! wait_started; then
    echo "[WARN] allowlist not applied: container $APP is '$st'" >&2
    return 0
  fi
  # shellcheck disable=SC2086
  docker exec "$APP" pihole allow -q $domains --comment "asyla-hosts allowlist" >/dev/null \
    && echo "[INFO] allowlist: $(allowlist_domains | grep -c .) domain(s) present" \
    || echo "[WARN] allowlist: pihole allow failed" >&2
}

# password: the admin password (web UI and API) from stdin, never argv. Starts the container once
# with the value in its environment (Pi-hole hashes it into pihole.toml), then again without it, and
# checks that the value logs in. An empty value is refused (it would remove the password).
do_password() {
  local pw="" valid
  if [ -t 0 ]; then
    read -rsp "New Pi-hole admin password: " pw; echo >&2
  else
    IFS= read -r pw || true
  fi
  [ -n "$pw" ] || { echo "[ERROR] password: no value on stdin (an empty one would remove the password)" >&2; return 1; }
  echo "[INFO] password: starting $APP once with the new value; Pi-hole keeps only its hash"
  export FTLCONF_webserver_api_password="$pw"
  do_up --password
  unset FTLCONF_webserver_api_password
  if ! wait_started || ! password_is_set; then
    echo "[ERROR] password: $APP is '$st' and pihole.toml has $(password_is_set && echo a || echo no) password hash" >&2
    return 1
  fi
  echo "[INFO] password: starting $APP again without the value, as every later start does"
  do_up
  wait_started || { echo "[ERROR] password: $APP is '$st' after the second start" >&2; return 1; }
  valid=$(printf '%s\n' "$pw" | docker exec -i "$APP" sh -c \
            'jq -Rc "{password:.}" | curl -s --data-binary @- http://127.0.0.1/api/auth | jq -r .session.valid' 2>/dev/null || true)
  pw=""
  [ "$valid" = true ] || { echo "[ERROR] password: the new value does not log in to the API" >&2; return 1; }
  echo "[OK] password: set; restarts and the restore keep it (only the hash is stored)"
}

do_backup() {
  # A copy of this tree on another host (a replica) must never write ns01's mirror.
  if [ "$THIS_HOST" != "$TREE_HOST" ]; then
    echo "[ERROR] backup: this is $THIS_HOST, not $TREE_HOST; only $TREE_HOST writes $BACKUP_DIR" >&2
    return 1
  fi
  do_rsync_mirror_backup "$APP_ROOT" "$BACKUP_DIR" -- "${BACKUP_FILTER[@]}"
}

do_update() {
  echo "[INFO] Pulling the image (not starting; use up or restart)"
  run_compose pull
}

# verify: the container healthy, the NAS hosts file mounted as its /etc/hosts, local answers (one
# CNAME from Pi-hole's own config, one hosts-file name with its address, its own name with this
# host's address, not 0.0.0.0), an outside name (not on a replica:
# its egress is blocked), dhcp.active as this host should have it and a udp/67 listener
# only where it should be on. Names and records are never printed (the hosts file is a map of the
# network).
do_verify() {
  local bad=0 alias line ip name ans self dhcp l67 d allowed
  fail() { echo "[FAIL] pihole: $1" >&2; bad=1; }
  ask() { docker exec "$APP" dig +short +time=2 +tries=1 "$1" @127.0.0.1 2>/dev/null; }
  wait_started || { echo "[FAIL] pihole: container $APP is '$st'" >&2; return 1; }
  if ! mountpoint -q "$DOCKER_D2" || [ ! -f "$HOSTS_FILE" ]; then
    fail "the NAS hosts file $HOSTS_FILE is not there"
  elif ! docker exec "$APP" cat /etc/hosts 2>/dev/null | cmp -s - "$HOSTS_FILE"; then
    fail "the container's /etc/hosts is not the NAS hosts file"
  fi
  alias=$(docker exec "$APP" pihole-FTL --config dns.cnameRecords 2>/dev/null | tr -d '[]' | sed 's/, /\n/g' \
            | sed 's/^ *//' | grep . | head -1 | cut -d, -f1 || true)
  if [ -z "$alias" ]; then
    fail "no CNAME in Pi-hole's config (dns.cnameRecords is empty: not restored?)"
  elif [ -z "$(ask "$alias")" ]; then
    fail "a CNAME from its config gets no answer"
  fi
  line=$(awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $1 !~ /^127\./ && NF >= 2 {print $1, $2; exit}' "$HOSTS_FILE" 2>/dev/null || true)
  ip=${line%% *}; name=${line#* }
  if [ -z "$line" ]; then
    fail "no IPv4 entry in the NAS hosts file"
  elif ! ask "$name" | grep -qxF "$ip"; then
    fail "a hosts-file name does not answer with its address"
  fi
  # Asked at this host's LAN address, Pi-hole answers its own name with that address; with
  # dns.reply.host.force4 true and no IPv4 it answers 0.0.0.0 (a restored pihole.toml, 2026-10-19).
  self=$(ip -4 -o route get 10.0.0.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' || true)
  if [ -z "$self" ]; then
    fail "no IPv4 source address on this host to ask $SELF_FQDN at"
  else
    ans=$(docker exec "$APP" dig +short +time=2 +tries=1 "$SELF_FQDN" @"$self" 2>/dev/null || true)
    [ "$ans" = "$self" ] || fail "$SELF_FQDN answers '${ans//$'\n'/ }', not this host's address $self (dns.reply.host.force4?)"
  fi
  if [ "$THIS_HOST" = "$TREE_HOST" ]; then
    [ -n "$(ask example.com)" ] || fail "an outside name (example.com) gets no answer"
  else
    echo "[INFO] pihole: replica on $THIS_HOST: outside names not checked (egress blocked)"
  fi
  dhcp=$(docker exec "$APP" pihole-FTL --config dhcp.active 2>/dev/null || true)
  [ "$dhcp" = "$PIHOLE_DHCP_ACTIVE" ] || fail "dhcp.active is '$dhcp', this host should have $PIHOLE_DHCP_ACTIVE"
  # Host network: FTL's DHCP socket is the host's. On ns01 it must listen; anywhere else nothing may.
  if ss -Hlun 2>/dev/null | awk '{print $4}' | grep -qE ':67$'; then l67=true; else l67=false; fi
  [ "$l67" = "$PIHOLE_DHCP_ACTIVE" ] || fail "udp/67 listener $([ "$l67" = true ] && echo present || echo absent), this host should have DHCP $PIHOLE_DHCP_ACTIVE"
  [ "$(ask wpad)" = "255.255.255.255" ] || fail "wpad does not answer 255.255.255.255 (FTLCONF_dns_hosts)"
  allowed=$(docker exec "$APP" pihole-FTL sqlite3 -readonly /etc/pihole/gravity.db \
              "select domain from domainlist where type = 0 and enabled = 1" 2>/dev/null || true)
  for d in $(allowlist_domains); do
    printf '%s\n' "$allowed" | grep -qxF "$d" || fail "allowlist: $d is not an enabled exact allow"
  done
  # A warning, not a failure: a new or restored host has none until pihole.sh password runs. On
  # stdout, before the [OK] line: build_host.py's verify line shows stdout, and stderr arrives apart.
  password_is_set || echo "[WARN] pihole: no admin password set (pihole.sh password)"
  [ "$bad" -eq 0 ] || return 1
  echo "[OK] pihole: $APP $st; NAS hosts file mounted; CNAME, hosts-file and own-name answers$([ "$THIS_HOST" = "$TREE_HOST" ] && echo ", outside answer"); dhcp.active $dhcp, udp/67 $([ "$l67" = true ] && echo listening || echo closed); wpad; allowlist"
}

[ $# -gt 0 ] || { echo "Usage: $0 up|down|restart|backup|restore|verify|password|update|refresh|logs ..." >&2; exit 1; }
for sw in "$@"; do
  case "$sw" in
    up) do_up ;;
    down) run_compose down; remove_stale_container ;;
    restart) run_compose down; remove_stale_container; do_up ;;
    backup) run_detached_if_interactive backup do_backup ;;
    _backup) do_backup ;;
    restore) do_rsync_mirror_restore "$BACKUP_DIR" "$APP_ROOT" ;;
    verify) do_verify ;;
    password) do_password ;;
    update) run_detached_if_interactive update do_update ;;
    _update) do_update ;;
    refresh) do_update; do_up ;;
    logs) run_compose logs --tail 50 ;;
    *) echo "[ERROR] unknown switch: $sw" >&2; exit 1 ;;
  esac
done
