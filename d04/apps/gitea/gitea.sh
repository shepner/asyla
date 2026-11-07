#!/bin/bash
# Gitea on d04 (copied from d03/apps/gitea at the move; verify differs). Usage: gitea.sh [switch ...] e.g. backup|restore|update|refresh|up|down|restart|verify|cron-config|logs
# Switches can be combined (e.g. down backup up). Run from anywhere; loads ~/scripts/docker/common.env.
# Data under /mnt/docker/Gitea; backup mirrors it to /mnt/nas/data1/docker/Gitea/mirror (Gitea briefly stopped).

set -euo pipefail

# ${BASH_SOURCE[0]:-$0}: also runs when piped (`ssh ... 'bash -s -- cron-config' < gitea.sh`), where
# BASH_SOURCE is empty. SCRIPT_DIR is then the cwd, so compose switches need the installed copy.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
SCREEN_APP="gitea"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
# shellcheck source=/dev/null
. "$HOME/scripts/docker/backup_lib.sh"
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
DOCKER_D1="${DOCKER_D1:-/mnt/nas/data1/docker}"

APP_NAME="Gitea"
APP_ROOT="$DOCKER_DL/Gitea"
BACKUP_DIR="$DOCKER_D1/Gitea/mirror"
# Gitea's config on the host (/data/gitea/conf/app.ini in the container). A variable so
# scripts/tests/test_gitea_cron_config.sh and test_gitea_verify.sh can point at a fixture.
GITEA_APP_INI="${GITEA_APP_INI:-$APP_ROOT/data/gitea/conf/app.ini}"

export DOCKER_DL
export DOCKER_D1
export LOCAL_TZ

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

# Not backed up:
# - data/ssh/: host keys for Gitea's built-in sshd, root:root 0600 (unreadable here). Nothing
#   reaches that sshd (only :3000 is published; clients use HTTPS), and the container
#   regenerates missing keys at start.
# - gitea.db-journal: exists only mid-transaction. Next to a good gitea.db, SQLite would treat
#   it as a hot journal and roll it into the DB on open.
BACKUP_EXCLUDES=(--exclude=/data/ssh/ --exclude=/data/gitea/gitea.db-journal)
# Longest wait for running Gitea Actions jobs before stopping Gitea. theOrg's nightly
# deploy-all (01:00 CDT) polls Gitea for up to ~80 min; it must not lose Gitea mid-run.
BACKUP_QUIET_WAIT_MIN="${BACKUP_QUIET_WAIT_MIN:-60}"

gitea_sql() {
  docker exec -u git gitea sqlite3 /data/gitea/gitea.db "$1"
}

# Returns 0 once no Gitea Actions task is running (action_task.status 6), 1 on timeout.
wait_actions_idle() {
  local deadline n
  deadline=$(( $(date +%s) + BACKUP_QUIET_WAIT_MIN * 60 ))
  while :; do
    n=$(gitea_sql "select count(*) from action_task where status = 6;") || return 1
    [ "$n" = "0" ] && return 0
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "[WARN] $n Gitea Actions job(s) still running after ${BACKUP_QUIET_WAIT_MIN} min" >&2
      return 1
    fi
    echo "[INFO] Waiting for $n running Gitea Actions job(s) before stopping Gitea"
    sleep 30
  done
}

check_mirror_db() {
  python3 - "$BACKUP_DIR/data/gitea/gitea.db" <<'PY'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro&immutable=1", uri=True)
res = db.execute("PRAGMA integrity_check").fetchone()[0]
repos = db.execute("select count(*) from repository").fetchone()[0]
print(f"[INFO] Backed-up gitea.db integrity_check: {res}; {repos} repositories")
sys.exit(0 if res == "ok" else 1)
PY
}

start_gitea() {
  run_compose start
  local i
  for i in $(seq 1 24); do
    curl -sf -o /dev/null --max-time 5 http://127.0.0.1:3000/ && { echo "[INFO] Gitea is back up"; return 0; }
    sleep 5
  done
  echo "[ERROR] Gitea not answering on :3000 two minutes after start" >&2
  return 1
}

# Gitea's docs say to stop it for a consistent backup. Pass 1 mirrors while it runs; pass 2
# copies only what changed since, with Gitea stopped, so it is down for seconds, not the
# whole copy. Every step checks its exit code: the dispatcher calls this under `if !`, where
# set -e does not apply.
do_backup() {
  local rc=0 t0
  rm -f "$APP_ROOT/data/gitea/gitea.db.snapshot"
  echo "[INFO] Pass 1 of 2: mirror while Gitea runs"
  do_rsync_mirror_backup "$APP_ROOT" "$BACKUP_DIR" -- "${BACKUP_EXCLUDES[@]}" || return
  if [ "$(docker inspect -f '{{.State.Running}}' gitea 2>/dev/null)" != "true" ]; then
    echo "[INFO] Gitea is not running, so pass 1 is already consistent"
  elif wait_actions_idle; then
    trap 'start_gitea' EXIT          # never leave Gitea stopped
    trap 'exit 143' TERM INT HUP     # turn signals into exit so the EXIT trap runs
    echo "[INFO] Pass 2 of 2: stopping Gitea"
    t0=$SECONDS
    run_compose stop || rc=$?
    [ "$rc" -eq 0 ] && { do_rsync_mirror_backup "$APP_ROOT" "$BACKUP_DIR" -- "${BACKUP_EXCLUDES[@]}" || rc=$?; }
    trap - EXIT TERM INT HUP
    start_gitea || { [ "$rc" -eq 0 ] && rc=1; }
    echo "[INFO] Gitea was stopped for $((SECONDS - t0))s"
    [ "$rc" -eq 0 ] || return "$rc"
  else
    # Busy: leave Gitea up. The DB comes from an online snapshot so it is still consistent,
    # but the repos were copied live, so report a failure for the digest to show.
    echo "[WARN] Not stopping Gitea; backing up an online DB snapshot instead" >&2
    gitea_sql ".backup /data/gitea/gitea.db.snapshot" || return
    rsync -a "$APP_ROOT/data/gitea/gitea.db.snapshot" "$BACKUP_DIR/data/gitea/gitea.db" || return
    rm -f "$APP_ROOT/data/gitea/gitea.db.snapshot"
    check_mirror_db || return
    return 3
  fi
  check_mirror_db
}

# Backup refuses on a host that does not serve gitea.asyla.org. Every host's gitea.sh backs up to
# the same $BACKUP_DIR, so a copy that is not the live Gitea (d04 before the cutover, d03 after it,
# a replica) would overwrite the live Gitea's backup with its own data. The serving host is the one
# the name resolves to (d03: 10.0.0.62, its own address, 2026-10-15). Exits: the dispatcher would
# take a return 1 for an unknown switch and print the usage.
GITEA_SERVED_NAME="gitea.asyla.org"
require_serving_host() {
  local addrs mine a m
  addrs="$(getent ahostsv4 "$GITEA_SERVED_NAME" 2>/dev/null | awk '{print $1}' | sort -u)" || addrs=""
  if [ -z "$addrs" ]; then
    echo "[ERROR] $GITEA_SERVED_NAME does not resolve here; not backing up (only the host that serves it backs up to $BACKUP_DIR)" >&2
    exit 1
  fi
  mine="$(hostname -I 2>/dev/null)" || mine=""
  for a in $addrs; do
    for m in $mine; do
      [ "$a" = "$m" ] && return 0
    done
  done
  echo "[ERROR] $GITEA_SERVED_NAME resolves to ${addrs//$'\n'/ }, not to this host (${mine:-no address}); not backing up: $BACKUP_DIR belongs to the host that serves it" >&2
  exit 1
}

do_update() {
  echo "[INFO] Pulling latest images (not starting app; use up or restart to start)"
  run_compose pull
}

# verify waits this long for Gitea to answer before it reports. Right after up or restart the
# container is running but Gitea is not serving yet: on 2026-10-10 `restart verify` exited 1 on a
# healthy restart. A Gitea that already answers costs one request; one that never answers fails
# as before, this much later. The URLs are variables so scripts/tests/test_gitea_verify.sh can
# point verify at a stand-in.
GITEA_VERIFY_WAIT_S="${GITEA_VERIFY_WAIT_S:-120}"
GITEA_LOCAL_URL="${GITEA_LOCAL_URL:-http://127.0.0.1:3000}"
GITEA_PUBLIC_URL="${GITEA_PUBLIC_URL:-https://gitea.asyla.org}"

# Returns 0 once /api/healthz answers 200 (Gitea's own readiness check), 1 on timeout.
wait_ready() {
  local deadline waited=false
  deadline=$(( $(date +%s) + GITEA_VERIFY_WAIT_S ))
  until curl -sf -o /dev/null --max-time 5 "$GITEA_LOCAL_URL/api/healthz"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "[WARN] $GITEA_LOCAL_URL/api/healthz not passing after ${GITEA_VERIFY_WAIT_S}s" >&2
      return 1
    fi
    $waited || echo "[INFO] Waiting up to ${GITEA_VERIFY_WAIT_S}s for Gitea to answer"
    waited=true
    sleep 2
  done
}

# Unlike d03's copy, a local failure is fatal: until the cutover the public URL reaches d03's
# Gitea, so it alone would pass with d04's Gitea down (operator, 2026-10-15: "Fatal local check").
do_verify() {
  local rc=0
  echo "[INFO] Health check local :3000 (fatal) and $GITEA_PUBLIC_URL/ (via proxy)"
  wait_ready || true                 # the checks below decide; this only gives Gitea time
  if curl -sf -o /dev/null --max-time 15 "$GITEA_LOCAL_URL/api/healthz"; then
    echo "[INFO] Local :3000 OK"
  else
    echo "[ERROR] Local :3000 check failed ($GITEA_LOCAL_URL/api/healthz)" >&2
    rc=1
  fi
  if curl -sfk -o /dev/null -w "%{http_code}" --max-time 20 "$GITEA_PUBLIC_URL/" | grep -qE '^(200|302)$'; then
    echo "[INFO] $GITEA_PUBLIC_URL OK"
  else
    echo "[ERROR] $GITEA_PUBLIC_URL check failed" >&2
    rc=1
  fi
  check_cleanup_rules
  check_cron_config
  return "$rc"
}

# Registry retention (README): one container cleanup rule per owner, set in the web UI only (Gitea
# 1.27.3 has no API for rules). verify prints them from the DB, opened read-only, and warns when one
# is missing or differs. A warning, not a failure: verify is Gitea's health check (`restart verify`,
# build_host.py verify, the empty Gitea of test_gitea_verify_test01.sh), and a failed verify after an
# applied update rolls the image back (host-maintenance), which would not fix a rule.
GITEA_CLEANUP_OWNERS="theOrg asyla personal"

gitea_sql_ro() {
  docker exec -u git gitea sqlite3 -readonly -cmd ".timeout 5000" /data/gitea/gitea.db "$1"
}

check_cleanup_rules() {
  local rules good owner missing=""
  if ! rules="$(gitea_sql_ro "select r.id, u.name, r.enabled, r.type, r.keep_count, r.remove_days, quote(r.keep_pattern), quote(r.remove_pattern) from package_cleanup_rule r join user u on u.id = r.owner_id order by r.id;" 2>&1)"; then
    echo "[WARN] Could not read the package cleanup rules: ${rules##*$'\n'}" >&2
    return 0
  fi
  echo "[INFO] Package cleanup rules (id|owner|enabled|type|keep_count|remove_days|keep_pattern|remove_pattern):"
  if [ -n "$rules" ]; then
    printf '%s\n' "$rules" | sed 's/^/         /'
  else
    echo "         (none)"
  fi
  # The owners whose rule is as the README's table has it.
  good="$(gitea_sql_ro "select u.name from package_cleanup_rule r join user u on u.id = r.owner_id where r.enabled = 1 and r.type = 'container' and r.keep_count = 0 and r.remove_days = 7 and r.keep_pattern = '' and r.remove_pattern = '';" 2>/dev/null)" || good=""
  for owner in $GITEA_CLEANUP_OWNERS; do
    grep -qxF "$owner" <<<"$good" || missing="$missing $owner"
  done
  if [ -n "$missing" ]; then
    echo "[WARN] No enabled container cleanup rule with keep_count 0, remove_days 7 and no pattern for:$missing (README, Registry retention)" >&2
  else
    echo "[INFO] Cleanup rules for ${GITEA_CLEANUP_OWNERS// /, } as in the README"
  fi
}

# Registry retention, when (README): Gitea's cleanup_packages job runs once a night at 01:30 local
# time (the container's /etc/localtime, America/Chicago) and never at start (operator, 2026-11-06).
# Gitea's defaults are @midnight and at every start, and each run held the sqlite database for 6-15
# min, 2-4 times a night (asyla hub backlog 2026-11-06-hosts-gitea-nightly-package-cleanup-locks-
# the-forge). Gitea 1.27.3 reads [cron.cleanup_packages] RUN_AT_START and SCHEDULE; a 5-field
# SCHEDULE is a standard crontab, minute first. Gitea reads app.ini only at start, so the change
# applies at its next start (the nightly backup's stop and start); cron-config never restarts it.
# ENABLED is not managed: its default is true, and verify warns if the section turns it off.
GITEA_CRON_SECTION="cron.cleanup_packages"
GITEA_CRON_SETTINGS=("RUN_AT_START=false" "SCHEDULE=30 1 * * *")

# cron_ini check|apply [container StartedAt]: check prints the managed keys' values and warns on
# drift (always exit 0); apply sets them, changing no other line: a timestamped backup beside
# app.ini first (same owner, mode and times), then a temp file in the same directory renamed over
# it, with app.ini's owner, group and mode. Prints only the managed keys' values, never any other
# app.ini content (it holds Gitea's secrets).
cron_ini() {
  python3 - "$1" "$GITEA_APP_INI" "$GITEA_CRON_SECTION" "${2:-}" "${GITEA_CRON_SETTINGS[@]}" <<'PY'
import datetime, os, re, sys, tempfile, time

mode, path, section, started = sys.argv[1:5]
want = dict(a.split("=", 1) for a in sys.argv[5:])
# Gitea's defaults for this job (services/cron/tasks_basic.go, registerCleanupPackages).
DEFAULTS = {"ENABLED": "true", "RUN_AT_START": "true", "SCHEDULE": "@midnight"}
TRUE = {"1", "t", "true", "y", "yes", "on"}   # go-ini's Bool() true words, lower-cased
HEADER = re.compile(r"^\s*\[\s*([^\]]*?)\s*\]\s*$")
KEYLINE = re.compile(r"^\s*([^=:\s;#\[][^=:]*?)\s*[=:]\s*(.*?)\s*$")
where = f"app.ini [{section}]"

def show(k, v):
    return repr(v) if v is not None else f"unset (Gitea's default {DEFAULTS.get(k, '?')})"

def fail(msg):
    level = "WARN" if mode == "check" else "ERROR"
    print(f"[{level}] {msg}", file=sys.stderr)
    sys.exit(0 if mode == "check" else 1)

try:
    with open(path, "rb") as f:
        st = os.fstat(f.fileno())
        raw = f.read()
except OSError as e:
    fail(f"Could not read {path}: {e.strerror}; nothing changed" if mode == "apply"
         else f"Could not read {path}: {e.strerror}")

# Lines end at \n only, as go-ini reads them (str.splitlines would also split at \f, \x1c, U+2028).
lines = re.findall(r"[^\n]*\n|[^\n]+\Z", raw.decode("utf-8", "surrogateescape"))
nl = "\r\n" if lines and lines[0].endswith("\r\n") else "\n"

# The section's key lines, wherever it appears; go-ini merges repeats and the last value wins.
found, keylines, first, last_in_first = {}, [], None, None
cur, in_first = None, False
for i, line in enumerate(lines):
    s = line.rstrip("\r\n")
    m = HEADER.match(s)
    if m:
        cur = m.group(1)
        in_first = cur == section and first is None
        if in_first:
            first = last_in_first = i
        continue
    if cur != section:
        continue
    m = KEYLINE.match(s)
    if not m:
        continue
    found[m.group(1)] = m.group(2)
    keylines.append((i, m.group(1), m.group(2)))
    if in_first:
        last_in_first = i

drift = [k for k, v in want.items() if found.get(k) != v]
enabled = found.get("ENABLED")
enabled_off = enabled is not None and enabled.lower() not in TRUE

if mode == "check":
    if drift:
        print(f"[WARN] {where} differs from the README (Registry retention): "
              + "; ".join(f"{k} is {show(k, found.get(k))}, want {want[k]!r}" for k in drift)
              + "; gitea.sh cron-config sets it", file=sys.stderr)
    else:
        print(f"[INFO] {where}: " + ", ".join(f"{k} = {v}" for k, v in want.items())
              + " as in the README")
        if started:
            try:
                t = datetime.datetime.strptime(started[:19], "%Y-%m-%dT%H:%M:%S")
                t = t.replace(tzinfo=datetime.timezone.utc).timestamp()
            except ValueError:
                t = None
            if t is not None and st.st_mtime > t:
                print(f"[INFO] app.ini changed after Gitea started ({started[:19]}Z): "
                      "the running Gitea has the old schedule until its next start")
    if enabled_off:
        print(f"[WARN] {where} ENABLED is {enabled!r}: the cleanup job does not run, so the "
              "registry is not pruned", file=sys.stderr)
    sys.exit(0)

# apply
new = list(lines)
for i, k, v in keylines:
    if k in want and v != want[k]:
        eol = lines[i][len(lines[i].rstrip("\r\n")):]
        new[i] = f"{k} = {want[k]}{eol or nl}"
missing = [k for k in want if k not in found]
if first is None:
    if new and not new[-1].endswith("\n"):
        new[-1] += nl
    if new and new[-1].strip():
        new.append(nl)
    new.append(f"[{section}]{nl}")
    new += [f"{k} = {want[k]}{nl}" for k in want]
elif missing:
    if not new[last_in_first].endswith("\n"):
        new[last_in_first] += nl
    new[last_in_first + 1:last_in_first + 1] = [f"{k} = {want[k]}{nl}" for k in missing]

if new == lines:
    print(f"[INFO] {where} already set: " + ", ".join(f"{k} = {v}" for k, v in want.items())
          + "; nothing changed, Gitea not restarted")
else:
    data = "".join(new).encode("utf-8", "surrogateescape")
    d = os.path.dirname(os.path.abspath(path))
    perm = st.st_mode & 0o7777
    tmp = bak = None
    try:
        # The temp file first: if this user cannot give it app.ini's owner, stop before any write.
        fd, tmp = tempfile.mkstemp(prefix=".app.ini.", suffix=".tmp", dir=d)
        with os.fdopen(fd, "wb") as f:
            os.fchown(f.fileno(), st.st_uid, st.st_gid)
            os.fchmod(f.fileno(), perm)
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        bak = f"{path}.bak-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
        fd = os.open(bak, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            os.fchown(f.fileno(), st.st_uid, st.st_gid)
            os.fchmod(f.fileno(), perm)
            f.write(raw)
            f.flush()
            os.fsync(f.fileno())
        os.utime(bak, ns=(st.st_atime_ns, st.st_mtime_ns))
        now = os.stat(path)
        if (now.st_ino, now.st_size, now.st_mtime_ns) != (st.st_ino, st.st_size, st.st_mtime_ns):
            raise RuntimeError("app.ini changed while this ran")
        os.replace(tmp, path)
        tmp = None
    except (OSError, RuntimeError) as e:
        for p in (tmp, bak):
            if p:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        why = f"{e.strerror} ({e.filename})" if isinstance(e, OSError) and e.strerror else str(e)
        fail(f"Could not write {path}: {why}; app.ini not changed")
    try:   # make the rename durable; app.ini is already replaced either way
        dfd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass
    for k in want:
        if found.get(k) != want[k]:
            print(f"[INFO] {where} {k}: {show(k, found.get(k))} -> {want[k]!r}")
    print(f"[INFO] Backup of the previous app.ini: {bak}")
    print("[INFO] Gitea reads app.ini at start: this applies at Gitea's next start (gitea.sh "
          "backup stops and starts it nightly). Gitea was not restarted.")
if enabled_off:
    print(f"[WARN] {where} ENABLED is {enabled!r}: the cleanup job does not run; not changed "
          "(set it to true by hand if that was not intended)", file=sys.stderr)
PY
}

check_cron_config() {
  local started
  started="$(docker inspect -f '{{.State.StartedAt}}' gitea 2>/dev/null)" || started=""
  cron_ini check "$started" || echo "[WARN] Could not check $GITEA_APP_INI [$GITEA_CRON_SECTION]" >&2
}

run_cmd() {
  local cmd="$1"
  case "$cmd" in
    backup)
      require_serving_host
      run_detached_if_interactive backup do_backup
      ;;
    _backup)
      require_serving_host
      do_backup
      ;;
    # Rebuilt host only: refuses unless APP_ROOT is empty and the mirror's last backup is OK.
    restore)
      do_rsync_mirror_restore "$BACKUP_DIR" "$APP_ROOT"
      ;;
    update)
      run_detached_if_interactive update do_update
      ;;
    _update)
      do_update
      ;;
    refresh)
      echo "[INFO] Pulling latest images and starting"
      run_compose pull
      run_compose up -d
      ;;
    up)
      run_compose up -d
      ;;
    down)
      run_compose down
      ;;
    restart)
      run_compose down
      run_compose up -d
      ;;
    verify)
      do_verify
      ;;
    # Exits on failure: the dispatcher would print the usage for a return 1.
    cron-config)
      cron_ini apply || exit 1
      ;;
    logs)
      run_compose logs -f
      ;;
    *)
      return 1
      ;;
  esac
}

if [ $# -eq 0 ]; then
  echo "Usage: $0 [switch ...]" >&2
  echo "  Switches can be combined, e.g. down backup up" >&2
  echo "" >&2
  echo "  backup   - rsync mirror of $APP_ROOT to $BACKUP_DIR; history: nas01 ZFS snapshots (screen if interactive);" >&2
  echo "             refused unless $GITEA_SERVED_NAME resolves to this host" >&2
  echo "  restore  - rsync $BACKUP_DIR back to an empty $APP_ROOT (rebuilt host; Gitea stopped)" >&2
  echo "  update   - Pull latest images (screen if interactive); use up/restart to start" >&2
  echo "  refresh  - Pull latest images + start (inline)" >&2
  echo "  up       - Start containers only" >&2
  echo "  down     - Stop and remove containers" >&2
  echo "  restart  - Down then up" >&2
  echo "  verify   - curl local :3000 /api/healthz (fatal) and https://gitea.asyla.org;" >&2
  echo "             print the package cleanup rules and app.ini's [cron.cleanup_packages] (read-only; warns on drift)" >&2
  echo "  cron-config - set app.ini [cron.cleanup_packages] RUN_AT_START = false, SCHEDULE = 30 1 * * * (01:30 local);" >&2
  echo "             backup beside it first; applies at Gitea's next start, never restarts Gitea" >&2
  echo "  logs     - Follow logs (optionally for one service)" >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "Usage: $0 backup|restore|update|refresh|up|down|restart|verify|cron-config|logs [ ... ]" >&2
    exit 1
  fi
done
