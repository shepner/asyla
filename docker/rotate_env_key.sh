#!/bin/bash
# Give one KEY in an app's .env a new random value, on the host, without the value ever being
# printed, logged or put on a command line. For a credential the app itself checks (a basic-auth
# password, a shared secret): not for a token another system issues.
#
#   rotate_env_key.sh rotate <env-file> <KEY>     # new 48-hex-character value for KEY, in place
#   rotate_env_key.sh basic-auth-check <env-file> <USER_KEY> <PASS_KEY> <url>
#   rotate_env_key.sh finish <env-file>           # remove the kept old file
#   rotate_env_key.sh rollback <env-file>         # put the old file back
#   rotate_env_key.sh --selftest                  # offline, in a temp dir
#
# rotate keeps the old file beside the new one as <env-file>.pre-rotate (same owner and mode) and
# refuses when one is already there: finish or roll back the rotation in progress first. It
# rewrites the file in place (same inode, owner and mode) and changes only the KEY line. It
# refuses unless KEY is set exactly once, unquoted.
#
# basic-auth-check prints three HTTP codes for <url>: with no credentials, with the file's, and
# with the kept old file's when there is one. After a rotation and a restart of the app:
# 401, 200, 401. Credentials go to curl on stdin.
#
# Order: rotate; recreate the app's container (<app>.sh up) so it takes the value;
# basic-auth-check (or the app's own check); finish. Then update whatever stores a copy
# (build_host.py HOST secrets push --apply VAR), and tell whoever uses the credential where to
# read it. Run from the workstation without waiting for the host's nightly pull:
#   ssh HOST bash -s -- rotate '<env-file>' KEY < docker/rotate_env_key.sh
# marker: rotate-env-key-v2

set -uo pipefail
SELF="${BASH_SOURCE[0]:-$0}"   # the selftest calls this file again, wherever it was started from

die() { echo "rotate_env_key: $*" >&2; exit 2; }

key_ok() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "not a variable name: $1"; }

# Value of KEY in FILE, on stdout. Only ever used inside $( ) or a pipe to curl.
value_of() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) printf '%s' "${line#*=}"; return 0 ;; esac
  done < "$1"
  return 1
}

do_rotate() {
  local f="$1" key="$2" old="$1.pre-rotate" tmp="$1.rotating" new line n
  key_ok "$key"
  [ -f "$f" ] || die "no such file: $f"
  [ ! -e "$old" ] || die "$old exists: a rotation is in progress (finish or rollback first)"
  n=$(grep -c "^$key=" "$f")
  [ "$n" = 1 ] || die "$key is set $n times in $f (need exactly 1)"
  if grep -q "^$key=[\"']" "$f"; then die "$key is quoted in $f: not handled"; fi
  new="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  [ "${#new}" = 48 ] || die "could not make a random value"
  cp -p "$f" "$old" || die "could not keep $old"
  ( umask 077
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "$key="*) printf '%s=%s\n' "$key" "$new" ;; *) printf '%s\n' "$line" ;; esac
    done < "$old" > "$tmp" ) || { rm -f "$tmp"; die "could not write $tmp"; }
  # Everything but the KEY line must be unchanged, and the KEY line must have changed.
  if ! diff -q <(grep -v "^$key=" "$old") <(grep -v "^$key=" "$tmp") >/dev/null ||
     [ "$(wc -l < "$old")" != "$(wc -l < "$tmp")" ] ||
     [ "$(value_of "$old" "$key")" = "$(value_of "$tmp" "$key")" ]; then
    rm -f "$tmp" "$old"
    die "the rewrite did not come out as expected; $f is untouched"
  fi
  cat "$tmp" > "$f" || { rm -f "$tmp"; die "could not write $f (old file kept as $old)"; }
  rm -f "$tmp"
  echo "rotated $key in $f ($(wc -l < "$f" | tr -d ' ') lines, 1 changed); old file kept as $old"
}

http_code() {  # http_code <url> [<file> <user-key> <pass-key>]
  if [ $# -eq 1 ]; then
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$1"
  else
    printf 'user = "%s:%s"\n' "$(value_of "$2" "$3")" "$(value_of "$2" "$4")" |
      curl -s -o /dev/null -w '%{http_code}' --max-time 15 -K - "$1"
  fi
}

do_basic_auth_check() {
  local f="$1" ukey="$2" pkey="$3" url="$4"
  key_ok "$ukey"; key_ok "$pkey"
  [ -f "$f" ] || die "no such file: $f"
  echo "no credentials: $(http_code "$url")"
  echo "the file's credentials: $(http_code "$url" "$f" "$ukey" "$pkey")"
  if [ -f "$f.pre-rotate" ]; then
    echo "the old file's credentials: $(http_code "$url" "$f.pre-rotate" "$ukey" "$pkey")"
  else
    echo "the old file's credentials: no $f.pre-rotate"
  fi
}

do_finish() {
  [ -f "$1.pre-rotate" ] || die "no $1.pre-rotate: nothing to finish"
  rm -f "$1.pre-rotate" && echo "removed $1.pre-rotate"
}

do_rollback() {
  [ -f "$1.pre-rotate" ] || die "no $1.pre-rotate: nothing to roll back"
  cat "$1.pre-rotate" > "$1" && rm -f "$1.pre-rotate" && echo "restored $1 from its kept old file"
}

selftest() {
  local d f out fails=0 before inode
  d="$(mktemp -d)"; f="$d/.env"
  trap 'rm -rf "$d"' RETURN
  ok() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi; }
  printf 'A=1\nSVC_USER=someone\nSVC_PASS=old-placeholder\n# a comment\nB="two words"\n' > "$f"
  chmod 600 "$f"; inode=$(ls -i "$f" | awk '{print $1}')
  out="$(bash "$SELF" rotate "$f" SVC_PASS 2>&1)"
  ok "rotate exits 0" '[ $? -eq 0 ]'
  ok "the value changed, to 48 hex characters" '[[ "$(value_of "$f" SVC_PASS)" =~ ^[0-9a-f]{48}$ ]]'
  ok "every other line is as it was" '[ "$(grep -v "^SVC_PASS=" "$f")" = "$(printf "A=1\nSVC_USER=someone\n# a comment\nB=\"two words\"")" ]'
  ok "same inode and mode" '[ "$(ls -i "$f" | awk "{print \$1}")" = "$inode" ] && [ "$(ls -l "$f" | cut -c1-10)" = "-rw-------" ]'
  ok "the old file is kept, mode 600" '[ "$(value_of "$f.pre-rotate" SVC_PASS)" = old-placeholder ] && [ "$(ls -l "$f.pre-rotate" | cut -c1-10)" = "-rw-------" ]'
  ok "no value in the output" '! grep -q -e old-placeholder -e "$(value_of "$f" SVC_PASS)" <<<"$out"'
  ok "no temp file left" '[ ! -e "$f.rotating" ]'
  before="$(cat "$f")"
  bash "$SELF" rotate "$f" SVC_PASS >/dev/null 2>&1
  ok "a second rotate is refused while one is in progress, file untouched" '[ $? -eq 2 ] && [ "$(cat "$f")" = "$before" ]'
  bash "$SELF" rollback "$f" >/dev/null 2>&1
  ok "rollback restores the old value and removes the kept file" '[ "$(value_of "$f" SVC_PASS)" = old-placeholder ] && [ ! -e "$f.pre-rotate" ]'
  bash "$SELF" rotate "$f" SVC_PASS >/dev/null 2>&1; bash "$SELF" finish "$f" >/dev/null 2>&1
  ok "finish removes the kept file and keeps the new value" '[ ! -e "$f.pre-rotate" ] && [ "$(value_of "$f" SVC_PASS)" != old-placeholder ]'
  before="$(cat "$f")"
  bash "$SELF" rotate "$f" MISSING >/dev/null 2>&1
  ok "a key that is not set is refused" '[ $? -eq 2 ] && [ "$(cat "$f")" = "$before" ] && [ ! -e "$f.pre-rotate" ]'
  bash "$SELF" rotate "$f" B >/dev/null 2>&1
  ok "a quoted value is refused" '[ $? -eq 2 ] && [ "$(cat "$f")" = "$before" ] && [ ! -e "$f.pre-rotate" ]'
  printf 'A=2\n' >> "$f"; before="$(cat "$f")"
  bash "$SELF" rotate "$f" A >/dev/null 2>&1
  ok "a key set twice is refused" '[ $? -eq 2 ] && [ "$(cat "$f")" = "$before" ]'
  bash "$SELF" rotate "$d/none" A >/dev/null 2>&1
  ok "a missing file is refused" '[ $? -eq 2 ]'
  bash "$SELF" rotate "$f" 'A;B' >/dev/null 2>&1
  ok "a bad key name is refused" '[ $? -eq 2 ]'
  bash "$SELF" finish "$f" >/dev/null 2>&1
  ok "finish with nothing kept is refused" '[ $? -eq 2 ]'
  [ "$fails" -eq 0 ] && echo "selftest: pass" || { echo "selftest: $fails FAILED"; return 1; }
}

case "${1:-}" in
  rotate)           [ $# -eq 3 ] || die "usage: rotate <env-file> <KEY>"; do_rotate "$2" "$3" ;;
  basic-auth-check) [ $# -eq 5 ] || die "usage: basic-auth-check <env-file> <USER_KEY> <PASS_KEY> <url>"
                    do_basic_auth_check "$2" "$3" "$4" "$5" ;;
  finish)           [ $# -eq 2 ] || die "usage: finish <env-file>"; do_finish "$2" ;;
  rollback)         [ $# -eq 2 ] || die "usage: rollback <env-file>"; do_rollback "$2" ;;
  --selftest)       selftest ;;
  *)                die "usage: rotate|basic-auth-check|finish|rollback ... | --selftest (see the header)" ;;
esac
