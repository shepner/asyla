#!/bin/bash
# hello on d04: the build test app. Usage: hello.sh [switch ...]  (up|down|restart|backup|restore|verify|logs)
# Data: ${DOCKER_DL}/hello/www (index.html with a marker the first `up` writes). Secret: .env
# HELLO_GREETING (GitLab variable D04_HELLO_ENV), shown in the page. Backup: one rsync mirror at
# ${DOCKER_D1}/hello-d04/mirror.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
[ -f "$HOME/scripts/docker/common.env" ] && . "$HOME/scripts/docker/common.env"
. "$HOME/scripts/docker/backup_lib.sh"

DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"
APP_ROOT="$DOCKER_DL/hello"
BACKUP_DIR="$DOCKER_D1/hello-d04/mirror"
export DOCKER_DL DOCKER_UID DOCKER_GID

env_value() { sed -n "s/^$1=//p" "$SCRIPT_DIR/.env" 2>/dev/null | tail -1; }

run_compose() { docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"; }

do_up() {
  local greeting
  greeting=$(env_value HELLO_GREETING)
  [ -n "$greeting" ] || { echo "[ERROR] $SCRIPT_DIR/.env has no HELLO_GREETING (secrets not installed?)" >&2; return 1; }
  mkdir -p "$APP_ROOT/www"
  # The marker is data: written once, then only ever restored, so verify can tell a restore from a fresh start.
  [ -f "$APP_ROOT/www/marker" ] || echo "created $(date -Is) on $(hostname -s)" > "$APP_ROOT/www/marker"
  printf '<p>%s</p>\n<p>%s</p>\n' "$greeting" "$(cat "$APP_ROOT/www/marker")" > "$APP_ROOT/www/index.html"
  run_compose up -d
}

do_verify() {
  local page
  page=$(curl -fsS --max-time 10 http://127.0.0.1:8099/) || { echo "[FAIL] hello: no answer on :8099" >&2; return 1; }
  grep -qF "$(env_value HELLO_GREETING)" <<<"$page" || { echo "[FAIL] hello: page lacks the .env greeting" >&2; return 1; }
  grep -qF "$(cat "$APP_ROOT/www/marker")" <<<"$page" || { echo "[FAIL] hello: page lacks the data marker" >&2; return 1; }
  echo "[OK] hello: serving; marker: $(cat "$APP_ROOT/www/marker")"
}

[ $# -gt 0 ] || { echo "Usage: $0 up|down|restart|backup|restore|verify|logs ..." >&2; exit 1; }
for sw in "$@"; do
  case "$sw" in
    up) do_up ;;
    down) run_compose down ;;
    restart) run_compose down; do_up ;;
    backup) do_rsync_mirror_backup "$APP_ROOT" "$BACKUP_DIR" ;;
    restore) do_rsync_mirror_restore "$BACKUP_DIR" "$APP_ROOT" ;;
    verify) do_verify ;;
    logs) run_compose logs --tail 50 ;;
    *) echo "[ERROR] unknown switch: $sw" >&2; exit 1 ;;
  esac
done
