#!/bin/bash
# Pi-hole DNS server on ns02. Usage: pihole.sh [switch ...]  (up|down|restart|backup|restore|verify|update|refresh|logs)
# Switches can be combined (e.g. down backup up). Loads ~/scripts/docker/common.env.
#
# Data: ${DOCKER_DL}/pihole-ns02/{etc-pihole,etc-dnsmasq.d}. From the NAS, by design (central,
# snapshotted, reachable when all else is down; never in a repo): ${DOCKER_D2}/pihole/hosts,
# mounted as the container's /etc/hosts, and 03-lan-dns.conf, copied into etc-dnsmasq.d at up.
# Backup: one rsync mirror at ${DOCKER_D1}/pihole-ns02/mirror (docker/backup_lib.sh) of
# etc-pihole/ and etc-dnsmasq.d/ only, without pihole-FTL.db (query history: a live SQLite file,
# not needed to rebuild); only ns02 itself writes it. Restore: from that mirror, into an empty
# data dir (build_host.py's restore phase, before up).
# DHCP guard: PIHOLE_DHCP_ACTIVE is true only when this host is ns01, whatever the environment says;
# compose's FTLCONF_dhcp_active defaults to false. So a copy of this app (a test01 replica, a wrong
# host) never serves DHCP, and verify checks it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
TREE_HOST="ns02"                 # the host this tree is for; anywhere else it runs as a replica
APP="pihole-ns02"
SCREEN_APP="$APP"                # run_detached_if_interactive's session name

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
. "$HOME/scripts/docker/backup_lib.sh"

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
BACKUP_FILTER=(--exclude=/etc-pihole/pihole-FTL.db '--exclude=/etc-pihole/pihole-FTL.db-*'
               '--include=/etc-pihole/***' '--include=/etc-dnsmasq.d/***' '--exclude=*')

run_compose() {
  docker compose -p "$APP" -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
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
  run_compose up -d
}

do_backup() {
  # A copy of this tree on another host (a replica) must never write ns02's mirror.
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
# CNAME from Pi-hole's own config, one hosts-file name with its address), an outside name (not on a
# replica: its egress is blocked), and dhcp.active as this host should have it. Names and records
# are never printed (the hosts file is a map of the network).
do_verify() {
  local bad=0 st waited=0 wait_s="${PIHOLE_VERIFY_WAIT_S:-120}" alias line ip name ans dhcp
  fail() { echo "[FAIL] pihole: $1" >&2; bad=1; }
  ask() { docker exec "$APP" dig +short +time=2 +tries=1 "$1" @127.0.0.1 2>/dev/null; }
  while :; do
    st=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$APP" 2>/dev/null || echo "absent")
    [ "$st" = "running starting" ] && [ "$waited" -lt "$wait_s" ] || break
    sleep 5; waited=$((waited + 5))
  done
  case "$st" in
    "running healthy"|"running none") ;;
    *) echo "[FAIL] pihole: container $APP is '$st'" >&2; return 1 ;;
  esac
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
  if [ "$THIS_HOST" = "$TREE_HOST" ]; then
    [ -n "$(ask example.com)" ] || fail "an outside name (example.com) gets no answer"
  else
    echo "[INFO] pihole: replica on $THIS_HOST: outside names not checked (egress blocked)"
  fi
  dhcp=$(docker exec "$APP" pihole-FTL --config dhcp.active 2>/dev/null || true)
  [ "$dhcp" = "$PIHOLE_DHCP_ACTIVE" ] || fail "dhcp.active is '$dhcp', this host should have $PIHOLE_DHCP_ACTIVE"
  [ "$bad" -eq 0 ] || return 1
  echo "[OK] pihole: $APP $st; NAS hosts file mounted; CNAME and hosts-file answers$([ "$THIS_HOST" = "$TREE_HOST" ] && echo ", outside answer"); dhcp.active $dhcp"
}

[ $# -gt 0 ] || { echo "Usage: $0 up|down|restart|backup|restore|verify|update|refresh|logs ..." >&2; exit 1; }
for sw in "$@"; do
  case "$sw" in
    up) do_up ;;
    down) run_compose down; remove_stale_container ;;
    restart) run_compose down; remove_stale_container; do_up ;;
    backup) run_detached_if_interactive backup do_backup ;;
    _backup) do_backup ;;
    restore) do_rsync_mirror_restore "$BACKUP_DIR" "$APP_ROOT" ;;
    verify) do_verify ;;
    update) run_detached_if_interactive update do_update ;;
    _update) do_update ;;
    refresh) do_update; do_up ;;
    logs) run_compose logs --tail 50 ;;
    *) echo "[ERROR] unknown switch: $sw" >&2; exit 1 ;;
  esac
done
