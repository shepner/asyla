#!/bin/sh
# mirror-stage.sh SRC STAGE UID GID: identity-platform.sh backup's readable stage of one theOrg
# backup copy (keycloak-backup's or openldap-backup's /backup). Run as root inside that copy's own
# image (docker run --user 0:0 --network none --pull never), because the copy's files are
# root-owned and owner-only; the host user then mirrors STAGE to the NAS.
# theOrg identity-platform DEPLOY.md at 5dd8de6, "Mirroring /backup" and the directory's mirror
# rule: copy only under `flock -s SRC/.lock` (the shared side of the backup's own lock: it waits for
# a running backup, and a backup started meanwhile is refused and leaves the copy alone); the
# copy's own STATUS removed first, the data files and manifest.sha256, then STATUS last; never
# .work, .prev or .lock. Here: STAGE's STATUS goes first and the rest of STAGE is emptied; then the
# files manifest.sha256 names, manifest.sha256, a sha256sum -c of the staged files, STATUS last;
# then STAGE is chowned to UID:GID. Nothing manifest.sha256 does not name is copied.
# Exit 1 (STAGE left without STATUS) when SRC has no .lock, its STATUS is not OK, its manifest is
# missing or has a line that is not "<64 hex>  <plain file name>", a copy fails or the staged files
# do not match the manifest; 2 for a usage error. SRC is only read.
set -eu

fail() { echo "[ERROR] mirror-stage.sh: $*" >&2; exit 1; }

[ $# -eq 4 ] || { echo "[ERROR] mirror-stage.sh: usage: mirror-stage.sh SRC STAGE UID GID" >&2; exit 2; }
src=$1
stage=$2
uid=$3
gid=$4

[ -f "$src/.lock" ] || fail "$src/.lock is missing (no backup has run there); nothing staged"
exec 9<"$src/.lock"
flock -s -w 1800 9 || fail "could not take $src/.lock shared within 30 minutes (a backup still running?); nothing staged"

rm -f "$stage/STATUS"
find "$stage" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

case "$(head -n 1 "$src/STATUS" 2>/dev/null || true)" in
  OK*) ;;
  *) fail "$src/STATUS is missing or not OK; nothing staged" ;;
esac
[ -s "$src/manifest.sha256" ] || fail "$src/manifest.sha256 is missing or empty; nothing staged"
if grep -vqE '^[0-9a-f]{64} [ *][A-Za-z0-9][A-Za-z0-9._-]*$' "$src/manifest.sha256"; then
  fail "$src/manifest.sha256 has a line that is not '<sha256>  <file name>'; nothing staged"
fi
names=$(sed -E 's/^[0-9a-f]{64} [ *]//' "$src/manifest.sha256")
for n in $names; do
  case "$n" in
    STATUS|manifest.sha256) fail "$src/manifest.sha256 names $n; nothing staged" ;;
  esac
done

for n in $names; do
  cp -p "$src/$n" "$stage/$n"
done
cp -p "$src/manifest.sha256" "$stage/manifest.sha256"
(cd "$stage" && sha256sum -c manifest.sha256 >/dev/null) || fail "the staged files do not match $src/manifest.sha256; no STATUS staged"
cp -p "$src/STATUS" "$stage/STATUS"
chown -R "$uid:$gid" "$stage"
chmod 0700 "$stage"
