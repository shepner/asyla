#!/bin/bash
# Offline test of the backup guard in d03/apps/gitea/gitea.sh and d04/apps/gitea/gitea.sh:
# `backup` and `_backup` refuse (exit 1, [ERROR]) unless gitea.asyla.org resolves to one of this
# host's addresses; restore, verify and up never check. Touches no host and no NAS: `getent`,
# `hostname` and `docker` are stubs on PATH, and each run uses a copy of gitea.sh whose do_backup,
# do_verify and do_rsync_mirror_restore only print a marker. Needs bash. Run from anywhere:
#
#   scripts/tests/test_gitea_backup_guard.sh
#
# Exit 0 when every case passes.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# gitea.sh loads ~/scripts/docker/{common.env,backup_lib.sh}: give it a HOME whose scripts/ is
# this checkout.
mkdir -p "$T/home" "$T/bin"
ln -s "$REPO" "$T/home/scripts"

# getent ahostsv4 NAME prints FAKE_RESOLVES the way glibc does (one line per socket type), or
# exits 2 (not found) when it is empty. Every call is logged.
cat > "$T/bin/getent" <<STUB
#!/bin/bash
echo "\$*" >> "$T/getent.log"
[ -n "\${FAKE_RESOLVES:-}" ] || exit 2
for a in \$FAKE_RESOLVES; do
  printf '%-15s STREAM %s\n%-15s DGRAM\n%-15s RAW\n' "\$a" "\$2" "\$a" "\$a"
done
STUB
# hostname -I prints FAKE_OWN with glibc's trailing space.
cat > "$T/bin/hostname" <<STUB
#!/bin/bash
[ "\${1:-}" = "-I" ] && { echo "\${FAKE_OWN} "; exit 0; }
echo testhost
STUB
printf '#!/bin/bash\nexit 0\n' > "$T/bin/docker"
chmod +x "$T/bin/getent" "$T/bin/hostname" "$T/bin/docker"

# A copy of each gitea.sh with the work stubbed, defined just before the dispatcher so they
# replace the real ones (and backup_lib's restore).
for h in d03 d04; do
  mkdir -p "$T/$h"
  awk '/^run_cmd\(\) \{/ {
         print "do_backup() { echo \"STUB do_backup ran\"; }"
         print "do_verify() { echo \"STUB do_verify ran\"; }"
         print "do_rsync_mirror_restore() { echo \"STUB restore ran\"; }"
       } { print }' "$REPO/$h/apps/gitea/gitea.sh" > "$T/$h/gitea.sh"
  grep -q '^do_backup() { echo "STUB' "$T/$h/gitea.sh" || { echo "FAIL  could not stub $h's gitea.sh"; exit 1; }
done

# run_gitea <host> <resolves to> <own addresses> <switch ...>: sets RC, OUT and CALLS (getent calls).
run_gitea() {
  local h="$1" resolves="$2" own="$3"
  shift 3
  : > "$T/getent.log"
  OUT="$(HOME="$T/home" PATH="$T/bin:$PATH" MAINT_FOREGROUND=1 FAKE_RESOLVES="$resolves" \
    FAKE_OWN="$own" bash "$T/$h/gitea.sh" "$@" 2>&1 </dev/null)"
  RC=$?
  CALLS="$(wc -l < "$T/getent.log" | tr -d ' ')"
}

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

OWN="10.0.0.62 172.17.0.1 172.18.0.1"
for h in d03 d04; do
  for sw in backup _backup; do
    # 1. The name resolves to one of this host's addresses: the backup runs.
    run_gitea "$h" "10.0.0.62" "$OWN" "$sw"
    check "$h $sw, name resolves to this host: runs" \
      '[ "$RC" -eq 0 ] && grep -q "STUB do_backup ran" <<<"$OUT"'

    # 2. The name resolves to another host: refused before any backup work.
    run_gitea "$h" "10.0.0.63" "$OWN" "$sw"
    check "$h $sw, name resolves elsewhere: refused" \
      '[ "$RC" -eq 1 ] && grep -q "^\[ERROR\].*resolves to 10.0.0.63" <<<"$OUT" && ! grep -q "STUB do_backup" <<<"$OUT" && ! grep -q "Usage" <<<"$OUT"'

    # 3. The name does not resolve: refused.
    run_gitea "$h" "" "$OWN" "$sw"
    check "$h $sw, name does not resolve: refused" \
      '[ "$RC" -eq 1 ] && grep -q "^\[ERROR\].*does not resolve" <<<"$OUT" && ! grep -q "STUB do_backup" <<<"$OUT"'
  done

  # 4. An address that is a prefix of one of ours is not ours (10.0.0.6 vs 10.0.0.62).
  run_gitea "$h" "10.0.0.6" "$OWN" backup
  check "$h backup, name resolves to a prefix of an own address: refused" \
    '[ "$RC" -eq 1 ] && ! grep -q "STUB do_backup" <<<"$OUT"'

  # 5. A refused backup stops the switches after it (e.g. `backup up`).
  run_gitea "$h" "10.0.0.63" "$OWN" backup verify
  check "$h backup verify, refused: verify does not run" \
    '[ "$RC" -eq 1 ] && ! grep -q "STUB do_verify" <<<"$OUT"'

  # 6. restore, up and verify never look the name up, and run where it does not resolve.
  run_gitea "$h" "" "$OWN" restore up verify
  check "$h restore up verify: no guard" \
    '[ "$RC" -eq 0 ] && [ "$CALLS" -eq 0 ] && grep -q "STUB restore ran" <<<"$OUT" && grep -q "STUB do_verify ran" <<<"$OUT"'
done

if [ "$fails" -eq 0 ]; then
  echo "all cases passed"
else
  echo "$fails case(s) failed"
  exit 1
fi
