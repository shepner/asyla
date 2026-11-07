#!/bin/bash
# Offline test of `gitea.sh cron-config` (d04/apps/gitea/gitea.sh): it sets app.ini's
# [cron.cleanup_packages] RUN_AT_START = false and SCHEDULE = 30 1 * * * (README, Registry
# retention), changes no other byte, keeps a backup beside it, keeps app.ini's owner, group and
# mode, and never prints app.ini's other lines (the real one holds Gitea's secrets). Touches no
# host and no real Gitea: app.ini is a fixture (GITEA_APP_INI) with placeholder values, `docker`
# is a stub on PATH that only logs its calls, and HOME's scripts/ is this checkout. Needs bash and
# python3. Run from anywhere:
#
#   scripts/tests/test_gitea_cron_config.sh
#
# Exit 0 when every case passes.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GITEA_SH="$REPO/d04/apps/gitea/gitea.sh"
T="$(mktemp -d)"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

# gitea.sh loads ~/scripts/docker/{common.env,backup_lib.sh}: give it a HOME whose scripts/ is
# this checkout.
mkdir -p "$T/home" "$T/bin"
ln -s "$REPO" "$T/home/scripts"

# Every docker call is logged; cron-config must never stop, start or restart Gitea.
cat > "$T/bin/docker" <<STUB
#!/bin/bash
echo "\$*" >> "$T/docker.log"
exit 0
STUB
chmod +x "$T/bin/docker"
: > "$T/docker.log"
: > "$T/all.out"

CONF="$T/conf"
INI="$CONF/app.ini"

# The shape of d04's app.ini: placeholder values where Gitea keeps its secrets, and its one cron
# section, [cron.update_checker].
base_ini() {
  cat <<'EOF'
APP_NAME = Gitea
RUN_MODE = prod

[server]
ROOT_URL = https://gitea.asyla.org/
HTTP_PORT = 3000

[security]
INSTALL_LOCK = true
SECRET_KEY = placeholder
INTERNAL_TOKEN = placeholder

[cron.update_checker]
ENABLED = false
EOF
}
# The section as cron-config appends it.
SECTION=$'[cron.cleanup_packages]\nRUN_AT_START = false\nSCHEDULE = 30 1 * * *\n'

fresh() {  # an empty conf dir, as d04's (2775)
  chmod -R u+w "$CONF" 2>/dev/null
  rm -rf "$CONF"
  mkdir -p "$CONF"
  chmod 2775 "$CONF"
}

# run_gitea [switch ...]: runs gitea.sh against the fixture; sets RC and OUT (stdout and stderr).
run_gitea() {
  OUT="$(HOME="$T/home" PATH="$T/bin:$PATH" GITEA_APP_INI="$INI" bash "$GITEA_SH" "$@" 2>&1 </dev/null)"
  RC=$?
  printf '%s\n' "$OUT" >> "$T/all.out"
}

backups() { find "$CONF" -maxdepth 1 -name 'app.ini.bak-*' | wc -l | tr -d ' '; }
# Anything in the conf dir besides app.ini and its backups (a leftover temp file).
strays() { ls -A "$CONF" | grep -vxE 'app\.ini(\.bak-[0-9]{8}T[0-9]{6}Z)?' || true; }
# uid gid mode inode mtime of a file.
meta() { python3 -c 'import os, sys; s = os.stat(sys.argv[1]); print(s.st_uid, s.st_gid, oct(s.st_mode & 0o7777), s.st_ino, s.st_mtime_ns)' "$1"; }

fails=0
check() {  # check <name> <condition as a string>
  if eval "$2"; then
    echo "ok    $1 (exit $RC)"
  else
    echo "FAIL  $1 (exit $RC): expected $2"
    echo "$OUT" | sed 's/^/        /'
    fails=$((fails + 1))
  fi
}

# 1. No [cron.cleanup_packages] (d04 today): the section is appended after a blank line; the
#    original bytes are the file's prefix; one backup, identical to the original.
fresh
base_ini > "$INI"
cp "$INI" "$T/orig"
{ cat "$T/orig"; printf '\n%s' "$SECTION"; } > "$T/want"
run_gitea cron-config
check "no section: appended, original is the prefix, one identical backup" \
  '[ "$RC" -eq 0 ] && head -c "$(wc -c < "$T/orig")" "$INI" | cmp -s - "$T/orig" && cmp -s "$INI" "$T/want" && [ "$(backups)" = 1 ] && cmp -s "$CONF"/app.ini.bak-* "$T/orig" && grep -qF "RUN_AT_START: unset (Gitea'"'"'s default true) -> '"'"'false'"'"'" <<<"$OUT" && grep -qF "SCHEDULE: unset (Gitea'"'"'s default @midnight) -> '"'"'30 1 * * *'"'"'" <<<"$OUT" && grep -qF "applies at Gitea'"'"'s next start" <<<"$OUT" && [ -z "$(strays)" ]'

# 2. Run again: nothing to do, the file is not rewritten and no second backup is made.
before="$(meta "$INI")"
run_gitea cron-config
check "re-run: already set, file untouched, no new backup" \
  '[ "$RC" -eq 0 ] && grep -qF "already set" <<<"$OUT" && grep -qF "nothing changed, Gitea not restarted" <<<"$OUT" && cmp -s "$INI" "$T/want" && [ "$(meta "$INI")" = "$before" ] && [ "$(backups)" = 1 ] && ! grep -q "Backup of" <<<"$OUT"'

# 3. The section at Gitea's defaults, between two other sections: only the two managed lines
#    change; ENABLED, OLDER_THAN, the comment and every other section stay byte for byte.
fresh
{ base_ini; printf '\n[cron.cleanup_packages]\n; set by hand\nENABLED = true\nRUN_AT_START = true\nSCHEDULE=@midnight\nOLDER_THAN = 48h\n\n[log]\nLEVEL = Info\n'; } > "$INI"
{ base_ini; printf '\n[cron.cleanup_packages]\n; set by hand\nENABLED = true\nRUN_AT_START = false\nSCHEDULE = 30 1 * * *\nOLDER_THAN = 48h\n\n[log]\nLEVEL = Info\n'; } > "$T/want"
run_gitea cron-config
check "section at the defaults: the two keys corrected, the rest byte-identical" \
  '[ "$RC" -eq 0 ] && cmp -s "$INI" "$T/want" && grep -qF "RUN_AT_START: '"'"'true'"'"' -> '"'"'false'"'"'" <<<"$OUT" && grep -qF "SCHEDULE: '"'"'@midnight'"'"' -> '"'"'30 1 * * *'"'"'" <<<"$OUT" && [ "$(backups)" = 1 ] && ! grep -q "WARN" <<<"$OUT"'

# 4. The section holds only OLDER_THAN: the two keys go in after it, before the blank line.
fresh
{ base_ini; printf '\n[cron.cleanup_packages]\nOLDER_THAN = 48h\n\n[log]\nLEVEL = Info\n'; } > "$INI"
{ base_ini; printf '\n[cron.cleanup_packages]\nOLDER_THAN = 48h\nRUN_AT_START = false\nSCHEDULE = 30 1 * * *\n\n[log]\nLEVEL = Info\n'; } > "$T/want"
run_gitea cron-config
check "section with other keys only: the two keys inserted after its last key" \
  '[ "$RC" -eq 0 ] && cmp -s "$INI" "$T/want" && [ "$(backups)" = 1 ]'

# 5. No trailing newline, with no section and with the section last.
fresh
printf '%s' "$(base_ini)" > "$INI"
cp "$INI" "$T/orig"
{ cat "$T/orig"; printf '\n\n%s' "$SECTION"; } > "$T/want"
run_gitea cron-config
check "no trailing newline, no section: newline added, section appended" \
  '[ "$RC" -eq 0 ] && cmp -s "$INI" "$T/want" && cmp -s "$CONF"/app.ini.bak-* "$T/orig"'

fresh
{ base_ini; printf '\n[cron.cleanup_packages]\nOLDER_THAN = 48h'; } > "$INI"
{ base_ini; printf '\n[cron.cleanup_packages]\nOLDER_THAN = 48h\nRUN_AT_START = false\nSCHEDULE = 30 1 * * *\n'; } > "$T/want"
run_gitea cron-config
check "no trailing newline, section last: keys inserted after its last line" \
  '[ "$RC" -eq 0 ] && cmp -s "$INI" "$T/want"'

# 6. Owner, group and mode kept (664 as on d04, a secondary group when this user has one), the
#    file replaced (new inode), the backup with the original's owner, group, mode and mtime, and
#    no temp file left.
fresh
base_ini > "$INI"
chmod 664 "$INI"
touch -t 202601010000 "$INI"
alt_gid=""
for g in $(id -G); do
  [ "$g" != "$(id -g)" ] && { alt_gid="$g"; break; }
done
if [ -n "$alt_gid" ] && chgrp "$alt_gid" "$INI" 2>/dev/null; then
  touch -t 202601010000 "$INI"
  grp_note="group $alt_gid (secondary)"
else
  grp_note="group $(id -g) (no secondary group to test)"
fi
read -r o_uid o_gid o_mode o_ino o_mtime <<<"$(meta "$INI")"
run_gitea cron-config
read -r n_uid n_gid n_mode n_ino _ <<<"$(meta "$INI")"
read -r b_uid b_gid b_mode _ b_mtime <<<"$(meta "$(ls "$CONF"/app.ini.bak-*)")"
check "owner, $grp_note and mode $o_mode kept; new inode; backup alike; no temp file" \
  '[ "$RC" -eq 0 ] && [ "$n_uid:$n_gid:$n_mode" = "$o_uid:$o_gid:$o_mode" ] && [ "$o_mode" = 0o664 ] && [ "$n_ino" != "$o_ino" ] && [ "$b_uid:$b_gid:$b_mode:$b_mtime" = "$o_uid:$o_gid:$o_mode:$o_mtime" ] && [ -z "$(strays)" ]'

# 7. No app.ini: exit 1, nothing created.
fresh
run_gitea cron-config
check "no app.ini: exit 1, nothing created" \
  '[ "$RC" -eq 1 ] && grep -qF "[ERROR] Could not read $INI" <<<"$OUT" && [ -z "$(ls -A "$CONF")" ]'

# 8. The conf dir is not writable: exit 1, app.ini unchanged, no backup, no temp file.
fresh
base_ini > "$INI"
cp "$INI" "$T/orig"
chmod 555 "$CONF"
run_gitea cron-config
chmod 2775 "$CONF"
check "conf dir not writable: exit 1, app.ini not changed" \
  '[ "$RC" -eq 1 ] && grep -qF "app.ini not changed" <<<"$OUT" && cmp -s "$INI" "$T/orig" && [ "$(backups)" = 0 ] && [ -z "$(strays)" ]'

# 9. ENABLED = false in the section: the two keys set, ENABLED left as it is, and a warning.
fresh
{ base_ini; printf '\n[cron.cleanup_packages]\nENABLED = false\n'; } > "$INI"
{ base_ini; printf '\n[cron.cleanup_packages]\nENABLED = false\n%s' "${SECTION#*$'\n'}"; } > "$T/want"
run_gitea cron-config
check "ENABLED = false: keys set, ENABLED not changed, warned" \
  '[ "$RC" -eq 0 ] && cmp -s "$INI" "$T/want" && grep -qF "[WARN] app.ini [cron.cleanup_packages] ENABLED is '"'"'false'"'"'" <<<"$OUT"'

# 10. The piped form the operator runs before the 02:30 install
#     (ssh ... 'bash -s -- cron-config' < gitea.sh), from a directory with no compose.yml.
fresh
base_ini > "$INI"
{ base_ini; printf '\n%s' "$SECTION"; } > "$T/want"
mkdir -p "$T/cwd"
OUT="$(cd "$T/cwd" && HOME="$T/home" PATH="$T/bin:$PATH" GITEA_APP_INI="$INI" bash -s -- cron-config < "$GITEA_SH" 2>&1)"
RC=$?
printf '%s\n' "$OUT" >> "$T/all.out"
check "piped: bash -s -- cron-config < gitea.sh" \
  '[ "$RC" -eq 0 ] && cmp -s "$INI" "$T/want" && [ "$(backups)" = 1 ]'

# 11. Across every run above: no app.ini line besides the managed keys was printed, and Gitea was
#     never stopped, started or restarted.
OUT="$(cat "$T/docker.log")"
RC=0
check "no run printed a placeholder value; docker never asked to stop, start or restart" \
  '! grep -q "placeholder" "$T/all.out" && ! grep -qwE "restart|stop|start|up|down|kill|rm" "$T/docker.log"'

if [ "$fails" -eq 0 ]; then
  echo "all cases passed"
else
  echo "$fails case(s) failed"
  exit 1
fi
