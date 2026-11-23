#!/bin/bash
# breeding-research on d03. Usage: breeding-research.sh [build|backup|restore|update|refresh|up|down|restart|verify|logs|dbrestore [FILE]|dbcheck [FILE]|dbmigrate|dbstatus|dbload]
# Image: gitea.asyla.org/personal/breeding-research:latest (its CI publishes it from main and
# rebuilds it weekly). up and restart pull it only when it is not on this host, so a running app
# never moves to a new image by itself (host-maintenance's rollback re-tags the old image, then runs
# up); update and refresh pull. BREEDING_RESEARCH_PULL_OVERRIDE=0: a local build from source instead.
# Postgres (breeding-research-postgres, the central breed DB): its password is
# BREEDING_RESEARCH_PG_PASSWORD, from OpenBao at deploy (d03/host.toml start_env, sent by
# build_host.py over SSH stdin), else the running container's own (pg_password); up, restart,
# rebuild and refresh refuse without one. backup pg_dumps it into pgdump/ (the live pg-data/ never
# goes into the mirror); dbrestore loads a dump, dbcheck restore-tests one in a throwaway container.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="breeding-research"
# shellcheck source=lib/docker-native-build.sh
. "$SCRIPT_DIR/lib/docker-native-build.sh"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
# shellcheck source=/dev/null
. "$HOME/scripts/docker/backup_lib.sh"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/.env"
  set +a
fi

DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"
APP_NAME="breeding-research"
APP_ROOT="$DOCKER_DL/$APP_NAME"
BACKUP_DIR="$DOCKER_D1/$APP_NAME/mirror"
# The script owns the image choice (asyla backlog 2026-11-03-hosts-apps-follow-latest-redeployed-weekly):
# the registry's `latest`, pulled; by hand, BREEDING_RESEARCH_IMAGE_OVERRIDE=<ref> pins another, and
# BREEDING_RESEARCH_PULL_OVERRIDE=0 builds from source (breeding-research:local unless an image
# override is given). The .env's BREEDING_RESEARCH_IMAGE and BREEDING_RESEARCH_PULL (from GitLab
# variable D03_BREEDING_RESEARCH_ENV) are no longer read.
REGISTRY_IMAGE="gitea.asyla.org/personal/breeding-research:latest"
LOCAL_IMAGE="breeding-research:local"
BREEDING_RESEARCH_PULL="${BREEDING_RESEARCH_PULL_OVERRIDE:-1}"
if [ "$BREEDING_RESEARCH_PULL" = 1 ]; then
  BREEDING_RESEARCH_IMAGE="${BREEDING_RESEARCH_IMAGE_OVERRIDE:-$REGISTRY_IMAGE}"
else
  BREEDING_RESEARCH_IMAGE="${BREEDING_RESEARCH_IMAGE_OVERRIDE:-$LOCAL_IMAGE}"
fi

export DOCKER_DL DOCKER_D1 BREEDING_RESEARCH_IMAGE

PG_SERVICE="postgres"
PG_CONTAINER="breeding-research-postgres"
PG_DB="breeding_research"
PG_USER="breeding_research"
PG_DATA="$APP_ROOT/pg-data"
PG_DUMP_DIR="$APP_ROOT/pgdump"
PG_DUMP="$PG_DUMP_DIR/$PG_DB.dump"
PG_WAIT_S="${BREEDING_RESEARCH_PG_WAIT_S:-120}"
# The user tables, as pg_dump names them (quote_ident), for dbrestore's refusal and dbcheck.
PG_TABLES_SQL="SELECT format('%I.%I', schemaname, tablename) FROM pg_catalog.pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1"

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

resolve_source_dir() {
  local d
  if [ -n "${BREEDING_RESEARCH_SRC:-}" ] && [ -f "${BREEDING_RESEARCH_SRC}/Dockerfile" ]; then
    printf '%s' "$BREEDING_RESEARCH_SRC"
    return 0
  fi
  d="$SCRIPT_DIR/.src/breeding-research"
  if [ -f "$d/Dockerfile" ]; then
    printf '%s' "$d"
    return 0
  fi
  echo "[ERROR] breeding-research source not found. Set BREEDING_RESEARCH_SRC or clone https://gitea.asyla.org/personal/breeding-research.git to $d" >&2
  return 1
}

image_exists_locally() {
  docker image inspect "$BREEDING_RESEARCH_IMAGE" &>/dev/null
}

use_registry_pull() {
  [ "${BREEDING_RESEARCH_PULL:-0}" = "1" ] && [[ "$BREEDING_RESEARCH_IMAGE" == */*:* ]]
}

do_build() {
  local src
  src="$(resolve_source_dir)" || return
  docker_native_build "$BREEDING_RESEARCH_IMAGE" "$src" "$@"
}

# up and restart: pull only when the image is not on this host (update and refresh pull a newer one).
ensure_image() {
  if use_registry_pull; then
    if image_exists_locally; then
      echo "[INFO] Using $BREEDING_RESEARCH_IMAGE on this host (update or refresh pulls a newer one)"
      return 0
    fi
    echo "[INFO] Pulling $BREEDING_RESEARCH_IMAGE (not on this host)"
    run_compose pull
    return
  fi
  if image_exists_locally; then
    echo "[INFO] Using local image $BREEDING_RESEARCH_IMAGE"
    return 0
  fi
  echo "[INFO] Building $BREEDING_RESEARCH_IMAGE for this host"
  do_build
}

# The Postgres password: this process's BREEDING_RESEARCH_PG_PASSWORD (a deploy sends it: d03/host.toml
# start_env, from OpenBao on the workstation), else the running breeding-research-postgres's own
# POSTGRES_PASSWORD, since host-maintenance's weekly refresh and its rollback's up run on this host
# with no OpenBao (as d06 communications.sh's pg_password). docker inspect's template matches that
# one key and emits nothing else; the value stays in this process (never printed, never on argv).
# The docker group can read it there already (dockerd's config.v2.json), so nothing new is exposed.
# Refused: no value and no running container; a value with a character outside A-Za-z0-9._~- (RFC
# 3986 unreserved: DATABASE_URL then needs no encoding); a value other than the running container's
# (Postgres reads POSTGRES_PASSWORD only when it initialises an empty pg-data, so a new one would
# reach the app's DATABASE_URL and not the database: README.md, Password). Sets and exports
# POSTGRES_PASSWORD (compose gives it to the postgres service) and DATABASE_URL (to the app).
pg_password() {
  local id v
  id="$(run_compose ps -q --status running "$PG_SERVICE" 2>/dev/null </dev/null)" || id=""
  id="${id%%$'\n'*}"
  if [ -n "$id" ]; then
    v="$(docker inspect -f '{{range .Config.Env}}{{if eq (index (split . "=") 0) "POSTGRES_PASSWORD"}}{{.}}{{end}}{{end}}' "$id" 2>/dev/null </dev/null)" || v=""
    v="${v#POSTGRES_PASSWORD=}"
  else
    v=""
  fi
  if [ -z "${BREEDING_RESEARCH_PG_PASSWORD:-}" ]; then
    if [ -z "$id" ]; then
      echo "[ERROR] BREEDING_RESEARCH_PG_PASSWORD is not in this process's environment and $PG_CONTAINER is not running to take it from: the workstation resolves it from OpenBao at deploy (build_host.py start_env); not starting" >&2
      return 1
    fi
    if [ -z "$v" ]; then
      echo "[ERROR] BREEDING_RESEARCH_PG_PASSWORD is not in this process's environment and the running $PG_CONTAINER has no POSTGRES_PASSWORD to take" >&2
      return 1
    fi
    BREEDING_RESEARCH_PG_PASSWORD="$v"
    echo "[INFO] BREEDING_RESEARCH_PG_PASSWORD taken from the running $PG_CONTAINER container (not printed)"
  elif [ -n "$v" ] && [ "$v" != "$BREEDING_RESEARCH_PG_PASSWORD" ]; then
    v=""
    echo "[ERROR] BREEDING_RESEARCH_PG_PASSWORD differs from the running $PG_CONTAINER's POSTGRES_PASSWORD; the database keeps the one it was initialised with (README.md, Password: ALTER ROLE first); not starting" >&2
    return 1
  fi
  v=""
  case "$BREEDING_RESEARCH_PG_PASSWORD" in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-]*)
      echo "[ERROR] BREEDING_RESEARCH_PG_PASSWORD has a character outside A-Za-z0-9._~- (DATABASE_URL would need encoding); not starting" >&2
      return 1 ;;
  esac
  POSTGRES_PASSWORD="$BREEDING_RESEARCH_PG_PASSWORD"
  DATABASE_URL="postgresql://$PG_USER:$POSTGRES_PASSWORD@$PG_CONTAINER:5432/$PG_DB"
  export BREEDING_RESEARCH_PG_PASSWORD POSTGRES_PASSWORD DATABASE_URL
}

pg_running() {
  local id
  id="$(run_compose ps -q --status running "$PG_SERVICE" 2>/dev/null </dev/null)" || id=""
  [ -n "$id" ]
}

# SQL in the running breeding-research-postgres, as its superuser over the container's local socket
# (the image's pg_hba.conf trusts local connections: no password); unaligned, tuples only.
pg_sql() {
  run_compose exec -T "$PG_SERVICE" psql -X -v ON_ERROR_STOP=1 -At -U "$PG_USER" -d "$PG_DB" -c "$1" </dev/null
}

# pg-data holds no database: absent, or empty and listable. One this user cannot list is the
# container's (Postgres made it 0700), so it is initialised.
pg_data_empty() {
  [ ! -e "$PG_DATA" ] && return 0
  [ -r "$PG_DATA" ] && [ -x "$PG_DATA" ] && [ -z "$(ls -A "$PG_DATA" 2>/dev/null)" ]
}

# A custom-format dump pg_restore can read (its table of contents), checked in the running container.
pg_dump_readable() {
  run_compose exec -T "$PG_SERVICE" pg_restore --list <"$1" >/dev/null
}

# The database's consistent copy: pg_dump -Fc in the running breeding-research-postgres (one
# snapshot; local socket, no password) into pgdump/breeding_research.dump.partial (owner-only),
# checked with pg_restore --list, then moved into place. One dump is kept: the NAS's ZFS snapshots of
# the mirror hold its history. A failure removes the .partial and leaves the last good dump.
do_pg_dump() {
  local part="$PG_DUMP.partial"
  if ! pg_running; then
    echo "[ERROR] $PG_CONTAINER is not running; no pg_dump (start it: up)" >&2
    return 1
  fi
  (umask 077 && mkdir -p "$PG_DUMP_DIR") || return 1
  rm -f "$part"
  if ! (umask 077 && run_compose exec -T "$PG_SERVICE" pg_dump -U "$PG_USER" -d "$PG_DB" -Fc </dev/null >"$part"); then
    rm -f "$part"
    echo "[ERROR] pg_dump of $PG_DB failed; $PG_DUMP is the last good one" >&2
    return 1
  fi
  if [ ! -s "$part" ] || ! pg_dump_readable "$part"; then
    rm -f "$part"
    echo "[ERROR] the new dump of $PG_DB does not read back (pg_restore --list); $PG_DUMP is the last good one" >&2
    return 1
  fi
  mv -f "$part" "$PG_DUMP" || return 1
  echo "[INFO] pg_dump of $PG_DB read back (pg_restore --list) -> $PG_DUMP ($(wc -c <"$PG_DUMP" | tr -d ' ') bytes)"
}

# The dump first (once pg-data exists), then the mirror of APP_ROOT without the live pg-data/ (as
# tc-datalogger's mirror skips doltgres/) or a .partial. When the dump fails the mirror keeps the
# last good one (an excluded path is not deleted) and backup exits 1.
do_backup() {
  local rc=0 excl=(--exclude=/pg-data/ --exclude=/pgdump/*.partial)
  if [ -e "$PG_DATA" ]; then
    do_pg_dump || { rc=1; excl+=(--exclude=/pgdump/); }
  fi
  do_rsync_mirror_backup "$APP_ROOT" "$BACKUP_DIR" -- "${excl[@]}" || rc=$?
  return "$rc"
}

# dbrestore [FILE]: a dump (default pgdump/breeding_research.dump, which restore brings back from the
# mirror) into the running breeding-research-postgres, in one transaction, stopping at the first
# error (pg_restore --single-transaction --exit-on-error): a failed restore changes nothing.
# Refused while the database has a user table, unless RESTORE_FORCE=1, which replaces them (--clean
# --if-exists; the NAS snapshots keep older dumps). The app is stopped meanwhile and started again
# if it was running. Needs no password (local socket).
do_dbrestore() {
  local file="${1:-$PG_DUMP}" n app_id rc=0 clean=()
  if [ ! -s "$file" ]; then
    echo "[ERROR] dbrestore: no dump at $file" >&2
    return 1
  fi
  if ! pg_running; then
    echo "[ERROR] dbrestore: $PG_CONTAINER is not running (start it: up)" >&2
    return 1
  fi
  pg_dump_readable "$file" || { echo "[ERROR] dbrestore: $file is not a dump pg_restore can read; nothing changed" >&2; return 1; }
  n="$(pg_sql "SELECT count(*) FROM ($PG_TABLES_SQL) t")" || return 1
  if [ "$n" != 0 ]; then
    if [ "${RESTORE_FORCE:-0}" != 1 ]; then
      echo "[ERROR] dbrestore: $PG_DB has $n user table(s); refusing to restore over them (RESTORE_FORCE=1 replaces them)" >&2
      return 1
    fi
    clean=(--clean --if-exists)
  fi
  app_id="$(run_compose ps -q --status running breeding-research 2>/dev/null </dev/null)" || app_id=""
  if [ -n "$app_id" ]; then run_compose stop breeding-research </dev/null || return 1; fi
  echo "[INFO] dbrestore: $file -> $PG_DB${clean[0]:+ (RESTORE_FORCE=1: replacing $n table(s))}"
  run_compose exec -T "$PG_SERVICE" pg_restore -U "$PG_USER" -d "$PG_DB" --single-transaction --exit-on-error \
    ${clean[@]+"${clean[@]}"} <"$file" || rc=$?
  if [ -n "$app_id" ]; then run_compose start breeding-research </dev/null || rc=1; fi
  if [ "$rc" -ne 0 ]; then
    echo "[ERROR] dbrestore: pg_restore failed (exit $rc); the transaction rolled back, $PG_DB is as it was" >&2
    return 1
  fi
  echo "[INFO] dbrestore: done, $(pg_sql "SELECT count(*) FROM ($PG_TABLES_SQL) t") user table(s)"
}

# The expected table list and row counts, from the dump itself: pg_restore's SQL script has one
# CREATE [UNLOGGED] TABLE per table and one COPY ... FROM stdin block per table's data, one line per
# row (COPY text escapes newlines) up to "\.". Prints "schema.table<TAB>rows", sorted.
dump_table_counts() {
  awk '
    incopy { if ($0 == "\\.") { incopy = 0 } else { rows[t]++ } ; next }
    /^CREATE (UNLOGGED )?TABLE / {
      n = $0; sub(/^CREATE (UNLOGGED )?TABLE /, "", n); sub(/ \($/, "", n); sub(/ (PARTITION )?OF .*$/, "", n)
      if (!(n in rows)) rows[n] = 0; next
    }
    /^COPY .* FROM stdin;$/ {
      t = $0; sub(/^COPY /, "", t); sub(/ (\(.*\) )?FROM stdin;$/, "", t)
      if (!(t in rows)) rows[t] = 0; incopy = 1; next
    }
    END { for (t in rows) printf "%s\t%d\n", t, rows[t] }
  ' | LC_ALL=C sort
}

# dbcheck [FILE]: the restore test. The dump (default pgdump/breeding_research.dump) is restored into
# a throwaway container of the same image (--network none, --pull never, trust auth: it has no
# network and no password; no bind mount, removed with its volume afterwards), then its tables and
# each one's row count (SELECT count(*) FROM ONLY) are compared with what the dump holds. Exit 1 on
# any difference or failure. Never touches the live database; a table the live one has and the dump
# lacks (a dump older than the schema) is a warning.
do_dbcheck() {
  local file="${1:-$PG_DUMP}" image name want got rc=0 i live
  if [ ! -s "$file" ]; then
    echo "[ERROR] dbcheck: no dump at $file" >&2
    return 1
  fi
  image="$(run_compose config --images 2>/dev/null </dev/null | grep -m1 '^postgres:')" || image=""
  if [ -z "$image" ] || ! docker image inspect "$image" >/dev/null 2>&1 </dev/null; then
    echo "[ERROR] dbcheck: the postgres image of compose.yml (${image:-none}) is not on this host (update pulls it)" >&2
    return 1
  fi
  name="breeding-research-dbcheck-$$"
  docker run -d --name "$name" --network none --pull never --cpus 1 --memory 1g \
    -e POSTGRES_USER="$PG_USER" -e POSTGRES_DB="$PG_DB" -e POSTGRES_HOST_AUTH_METHOD=trust \
    "$image" </dev/null >/dev/null || { echo "[ERROR] dbcheck: could not start $name" >&2; return 1; }
  # Ready on 127.0.0.1: the image's first-start server listens on the socket only.
  for ((i = 0; i < PG_WAIT_S; i += 2)); do
    docker exec "$name" pg_isready -q -h 127.0.0.1 -U "$PG_USER" -d "$PG_DB" </dev/null && break
    sleep 2
  done
  if ! docker exec "$name" pg_isready -q -h 127.0.0.1 -U "$PG_USER" -d "$PG_DB" </dev/null; then
    echo "[ERROR] dbcheck: $name was not ready in ${PG_WAIT_S}s" >&2; rc=1
  elif ! docker exec -i "$name" pg_restore -U "$PG_USER" -d "$PG_DB" --single-transaction --exit-on-error <"$file"; then
    echo "[ERROR] dbcheck: $file does not restore" >&2; rc=1
  elif ! want="$(docker exec -i "$name" pg_restore -f - <"$file" | dump_table_counts)"; then
    echo "[ERROR] dbcheck: could not read the tables and rows $file holds" >&2; rc=1
  elif ! got="$(docker exec "$name" psql -X -v ON_ERROR_STOP=1 -At -F $'\t' -U "$PG_USER" -d "$PG_DB" -c \
      "SELECT t, (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM ONLY %s', t), false, true, '')))[1]::text FROM ($PG_TABLES_SQL) s(t)" </dev/null | LC_ALL=C sort)"; then
    echo "[ERROR] dbcheck: could not count the restored tables" >&2; rc=1
  elif [ "$want" != "$got" ]; then
    echo "[ERROR] dbcheck: the restored database differs from the dump (< dump, > restored):" >&2
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
    rc=1
  else
    echo "[INFO] dbcheck: $file restores: $(printf '%s\n' "$got" | grep -c . || true) table(s), $(printf '%s\n' "$got" | awk -F'\t' '{s += $2} END {print s + 0}') row(s), each table's count as in the dump"
  fi
  docker rm -f -v "$name" </dev/null >/dev/null || { echo "[ERROR] dbcheck: could not remove $name" >&2; rc=1; }
  if [ "$rc" -eq 0 ] && pg_running; then
    live="$(pg_sql "$PG_TABLES_SQL")" || live=""
    for i in $(LC_ALL=C comm -23 <(printf '%s\n' "$live" | LC_ALL=C sort) <(printf '%s\n' "$got" | cut -f1)); do
      echo "[WARN] dbcheck: the live $PG_DB has $i, which the dump lacks (a dump older than the schema: backup makes a new one)" >&2
    done
  fi
  return "$rc"
}

# The app image's own database tools (breeding-research repo scripts/, central breed DB milestone
# 3), run in the running app container (/app, user nobody), which has DATABASE_URL in its
# environment already (compose): nothing here reads or passes the password. An image older than
# those scripts is refused before anything runs, with the step that fixes it.
APP_SERVICE="breeding-research"
app_tool_ready() {
  local script="$1" id
  id="$(run_compose ps -q --status running "$APP_SERVICE" 2>/dev/null </dev/null)" || id=""
  if [ -z "$id" ]; then
    echo "[ERROR] the $APP_SERVICE container is not running (start it: up)" >&2
    return 1
  fi
  if ! run_compose exec -T "$APP_SERVICE" test -f "/app/$script" </dev/null; then
    echo "[ERROR] the running $APP_SERVICE image has no /app/$script: update the app image first (refresh pulls :latest, which must be built from a breeding-research commit that ships it)" >&2
    return 1
  fi
}

# dbmigrate: apply the pending schema migrations (db_migrate.py; exit 0 when none are left).
# dbstatus: list them, changing nothing. Neither reads this script's stdin, so `dbmigrate dbload`
# leaves the tar for dbload.
do_dbmigrate() {
  app_tool_ready scripts/db_migrate.py || return
  echo "[INFO] dbmigrate: scripts/db_migrate.py in $APP_SERVICE"
  run_compose exec -T -w /app "$APP_SERVICE" python scripts/db_migrate.py </dev/null
}
do_dbstatus() {
  app_tool_ready scripts/db_migrate.py || return
  run_compose exec -T -w /app "$APP_SERVICE" python scripts/db_migrate.py --status </dev/null
}

# dbload: a tar of one export directory (manifest.json and <table>.jsonl, from breeding-research
# scripts/bq_export.py) on this script's stdin, loaded by pg_load.py --tar -, which prints each
# table's export-vs-Postgres count and checksums and exits nonzero on any mismatch. Refused when
# stdin is a terminal. Re-running the same export adds nothing (pg_load.py skips rows already
# there). From the workstation: dbload_from_workstation.sh EXPORT_DIR (it runs dbmigrate first).
do_dbload() {
  if [ -t 0 ]; then
    echo "[ERROR] dbload reads a tar of an export directory on stdin (dbload_from_workstation.sh EXPORT_DIR sends one); stdin is a terminal" >&2
    return 1
  fi
  app_tool_ready scripts/pg_load.py || return
  echo "[INFO] dbload: stdin -> scripts/pg_load.py --tar - in $APP_SERVICE"
  run_compose exec -T -w /app "$APP_SERVICE" python scripts/pg_load.py --tar -
}

do_update() {
  if use_registry_pull; then
    echo "[INFO] Pulling $BREEDING_RESEARCH_IMAGE"
    run_compose pull
    return
  fi
  local src
  src="$(resolve_source_dir)" || return
  if [ -d "$src/.git" ]; then
    git -C "$src" pull --ff-only || return
  fi
  do_build
}

do_verify() {
  if curl -sf http://127.0.0.1:8080/healthz >/dev/null; then
    echo "[INFO] Local /healthz OK"
  else
    echo "[ERROR] Local /healthz failed" >&2
    return 1
  fi
  if curl -sfk -o /dev/null --max-time 20 https://breeding-research.asyla.org/healthz; then
    echo "[INFO] https://breeding-research.asyla.org/healthz OK"
  else
    echo "[ERROR] Public healthz failed" >&2
    return 1
  fi
}

# A restored host (pg-data empty, a dump in pgdump/ from the mirror): postgres starts alone and the
# dump is loaded before the app starts, so the app never starts on an empty database.
do_up() {
  pg_password || return
  ensure_image || return
  if [ -s "$PG_DUMP" ] && pg_data_empty; then
    echo "[INFO] $PG_DATA is empty and $PG_DUMP exists: starting postgres alone and loading the dump first"
    run_compose up -d --wait --wait-timeout "$PG_WAIT_S" "$PG_SERVICE" || return
    do_dbrestore "$PG_DUMP" || return
  fi
  run_compose up -d
}

# Every step checks the one before it: run_cmd runs under `||`, where bash ignores set -e.
run_cmd() {
  case "$1" in
    build) do_build ;;
    rebuild) pg_password && do_build --no-cache && run_compose up -d --force-recreate ;;
    backup) run_detached_if_interactive backup do_backup ;;
    _backup) do_backup ;;
    # Rebuilt host only: refuses unless APP_ROOT is empty and the mirror's last backup is OK.
    restore) do_rsync_mirror_restore "$BACKUP_DIR" "$APP_ROOT" ;;
    update) run_detached_if_interactive update do_update ;;
    _update) do_update ;;
    refresh) pg_password && do_update && do_up ;;
    up) do_up ;;
    down) run_compose down ;;
    restart) pg_password && run_compose down && do_up ;;
    verify) do_verify ;;
    # dbrestore and dbcheck take the dump in pgdump/; a FILE only as `$0 dbrestore|dbcheck FILE`.
    dbrestore) do_dbrestore ;;
    dbcheck) do_dbcheck ;;
    # The app image's database tools; dbload reads a tar of an export directory on stdin.
    dbmigrate) do_dbmigrate ;;
    dbstatus) do_dbstatus ;;
    dbload) do_dbload ;;
    logs) run_compose logs -f ;;
    *) echo "[ERROR] Unknown: $1" >&2; usage; return 2 ;;
  esac
}

usage() {
  echo "Usage: $0 build|rebuild|backup|restore|update|refresh|up|down|restart|verify|logs|dbrestore|dbcheck|dbmigrate|dbstatus|dbload ..." >&2
  echo "       $0 dbrestore FILE | dbcheck FILE   (a dump other than $PG_DUMP; RESTORE_FORCE=1 dbrestore replaces existing tables)" >&2
  echo "       $0 dbmigrate | dbstatus   (apply | list the app image's schema migrations)" >&2
  echo "       $0 dbload < EXPORT.tar    (load a tar of an export directory; dbload_from_workstation.sh EXPORT_DIR sends one)" >&2
}

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

if { [ "$1" = dbrestore ] || [ "$1" = dbcheck ]; } && [ $# -eq 2 ]; then
  rc=0
  "do_$1" "$2" || rc=$?
  exit "$rc"
fi

# A switch that fails exits with its own status (an unknown one: 2, after the usage).
for cmd in "$@"; do
  rc=0
  run_cmd "$cmd" || rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
done
