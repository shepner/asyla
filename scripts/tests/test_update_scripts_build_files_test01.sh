#!/bin/bash
# Test of d03/update_scripts.sh on test01 only (the disposable build host), run as if on d03: the
# updater must remove the build files (build_host.py build_only_paths: d03/setup/, d03/host.toml,
# docker/setup/) and keep everything else the repo tracks or ignores. d03's old updater copied the
# whole tree, so the rebuilt d03's verify failed "no build files on the host" (2026-10-17); a
# test01 build runs test01's updater and could not see it.
#
# It sends this checkout's d03/, docker/ and .gitignore files to a temp dir on test01, commits them
# to a local git repo there (the updater clones it over file://, so no token and no GitLab), and
# runs a copy of d03/update_scripts.sh as root with three lines changed, each checked to match
# once: TARGET_HOME and DEPLOY_ENV point into the temp dir, and `hostname` on PATH answers d03.
# The temp home starts as the old updater left d03 (the whole tree, plus a d03/setup/ file, a
# stray app, an app .env, a foreign internal-access/ folder and ~/setup_manual.sh). Cases: a dry
# run changes nothing; a run removes exactly the build files and the stray app; a second run finds
# nothing to delete. Nothing outside the temp dir is touched.
#
#   scripts/tests/test_update_scripts_build_files_test01.sh     # from the workstation; ssh docker@test01
#
# Refuses to run anywhere but test01. Exit 0 when every case passes.

set -uo pipefail
ME=scripts/tests/test_update_scripts_build_files_test01.sh

if [ "${1:-}" != "--on-host" ]; then
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  { git -C "$REPO" ls-files -z -- d03 docker .gitignore; printf '%s\0' "$ME"; } |
    COPYFILE_DISABLE=1 tar -C "$REPO" --null -T - -cf - |
    ssh -o BatchMode=yes -o ConnectTimeout=10 -i ~/.ssh/docker_rsa docker@test01 '
      set -e
      [ "$(hostname -s)" = test01 ] || { echo "not test01: refusing" >&2; exit 2; }
      D=$(mktemp -d /tmp/updater-test.XXXXXX)
      mkdir "$D/src"
      tar -C "$D/src" -xf - 2>/dev/null
      exec sudo -n bash "$D/src/'"$ME"'" --on-host "$D"'
  exit $?
fi

# ---- on test01, as root ----
D="$2"
[ "$(hostname -s)" = test01 ] || { echo "not test01: refusing" >&2; exit 2; }
case "$D" in /tmp/updater-test.*) ;; *) echo "unexpected dir $D: refusing" >&2; exit 2 ;; esac
[ "$EUID" -eq 0 ] || { echo "not root: refusing" >&2; exit 2; }
trap 'rm -rf "$D"; echo "cleanup: $D exists: $([ -e "$D" ] && echo yes || echo no)"' EXIT

SRC="$D/src" H="$D/home" S="$D/home/scripts"
U="$D/update_scripts.sh"

fails=0
case_ok() {   # case_ok <name> <condition result 0/1>
  if [ "$2" -eq 0 ]; then echo "ok    $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi
}

# The source repo, branch master, as the updater expects GitLab's.
git -C "$SRC" init -q -b master
git -C "$SRC" add -A
git -C "$SRC" -c user.name=test -c user.email=test@test01 commit -q -m "updater test"
git -C "$SRC" config uploadpack.allowFilter true

# The updater, pointed into $D. Each changed line must match exactly once.
cp "$SRC/d03/update_scripts.sh" "$U"
for line in 'TARGET_HOME="/home/$TARGET_USER"' 'DEPLOY_ENV="/etc/asyla/asyla-hosts.env"'; do
  n=$(grep -cxF -- "$line" "$U")
  [ "$n" -eq 1 ] || { echo "expected one line '$line' in d03/update_scripts.sh, found $n: refusing" >&2; exit 2; }
done
sed -i -e "s|^TARGET_HOME=\"/home/\$TARGET_USER\"\$|TARGET_HOME=\"$H\"|" \
       -e "s|^DEPLOY_ENV=\"/etc/asyla/asyla-hosts.env\"\$|DEPLOY_ENV=\"$D/deploy.env\"|" "$U"
left=$(grep -v '^[[:space:]]*#' "$U" | grep -nE '/home/|/etc/asyla' || true)
[ -z "$left" ] || { echo "the updater copy still names a real path: $left" >&2; exit 2; }
printf 'ASYLA_HOSTS_DEPLOY_USER=test\nASYLA_HOSTS_DEPLOY_TOKEN=unused-file-clone\n' > "$D/deploy.env"
chmod 600 "$D/deploy.env"
mkdir -p "$D/bin"
printf '#!/bin/sh\necho d03\n' > "$D/bin/hostname"
chmod 755 "$D/bin/hostname"

# The home as d03's old updater left it.
mkdir -p "$S"
cp -r "$SRC/d03" "$SRC/docker" "$S/"
mkdir -p "$S/d03/setup" "$S/d03/apps/old-app" "$S/d03/apps/internal-access"
echo old > "$S/d03/setup/old_step.sh"
echo stray > "$S/d03/apps/old-app/old-app.sh"
echo 'X=1' > "$S/d03/apps/tc-datalogger/.env"
echo caddy > "$S/d03/apps/internal-access/Caddyfile"
ln -s "$S/d03/setup/old_step.sh" "$H/setup_manual.sh"

run_updater() {   # sets RC and OUT
  OUT=$(env PATH="$D/bin:$PATH" ASYLA_HOSTS_REPO_URL="file://$SRC" bash "$U" "$@" 2>&1)
  RC=$?
}
gone() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
BUILD=("$S/d03/setup" "$S/d03/host.toml" "$S/docker/setup" "$H/setup_manual.sh")

run_updater --dry-run
case_ok "dry run: exit 0 (got $RC)" "$([ "$RC" -eq 0 ]; echo $?)"
case_ok "dry run: the stray app would be deleted" "$(grep -qF "would delete: $S/d03/apps/old-app/old-app.sh" <<<"$OUT"; echo $?)"
case_ok "dry run: the app .env is preserved" "$(grep -qF "preserve (gitignored): $S/d03/apps/tc-datalogger/.env" <<<"$OUT"; echo $?)"
case_ok "dry run: nothing changed" "$([ -f "$S/d03/host.toml" ] && [ -f "$S/d03/apps/old-app/old-app.sh" ]; echo $?)"
[ "$fails" -eq 0 ] || echo "$OUT" | tail -20

run_updater
case_ok "run: exit 0 (got $RC)" "$([ "$RC" -eq 0 ]; echo $?)"
[ "$RC" -eq 0 ] || echo "$OUT" | tail -20
for p in "${BUILD[@]}"; do
  case_ok "run: build file gone: ${p#$D/}" "$(gone "$p"; echo $?)"
done
case_ok "run: the stray app is deleted" "$(gone "$S/d03/apps/old-app"; echo $?)"
case_ok "run: the app .env is kept" "$([ "$(cat "$S/d03/apps/tc-datalogger/.env" 2>/dev/null)" = X=1 ]; echo $?)"
case_ok "run: the foreign internal-access/ is kept" "$([ -f "$S/d03/apps/internal-access/Caddyfile" ]; echo $?)"
case_ok "run: ~/update_scripts.sh is d03's" "$(cmp -s "$H/update_scripts.sh" "$SRC/d03/update_scripts.sh"; echo $?)"
# Every other tracked file is installed, as the repo has it (verify's ~/scripts drift check).
differ=$(cd "$SRC" && git ls-files -- d03 docker | grep -vE '^(d03/setup/|d03/host\.toml$|docker/setup/)' |
         while IFS= read -r f; do cmp -s "$f" "$S/$f" || echo "$f"; done)
case_ok "run: every other tracked d03/ and docker/ file is installed${differ:+ (differ: $(echo $differ | head -c 200))}" \
  "$([ -z "$differ" ]; echo $?)"

run_updater
case_ok "second run: exit 0 (got $RC)" "$([ "$RC" -eq 0 ]; echo $?)"
case_ok "second run: nothing to delete" \
  "$(grep -qF "$S/d03: 0 path(s) not in repo" <<<"$OUT" && grep -qF "$S/docker: 0 path(s) not in repo" <<<"$OUT"; echo $?)"
still=""; for p in "${BUILD[@]}"; do gone "$p" || still="$still $p"; done
case_ok "second run: build files still gone" "$([ -z "$still" ]; echo $?)"

if [ "$fails" -eq 0 ]; then echo "all cases passed"; else echo "$fails case(s) failed"; fi
exit $(( fails > 0 ))
