#!/bin/bash
# scripts/app_switch.sh against an ssh stub on PATH: the exact ssh argv (build_host.py's options and
# key; the remote command is build_host.py's app_script and the switch alone, no export and no read),
# stdin carrying the one value on one line (empty with no VAR), the value in no argv, log, output or
# child environment (ssh, python3 and dirname are PATH wrappers that dump their environment), the
# remote exit kept, the value in no trace or child environment however bash is started (bash -x,
# SHELLOPTS=xtrace or allexport, a BASH_ENV setting -x, val/var exported in the incoming
# environment), and every refusal (exit 2, no ssh): a switch not in switch_env, a VAR not listed
# for it, a listed VAR missing, a VAR unset, empty or holding a newline, two VARs to a one-VAR
# switch, more than two in a switch_env list or one named twice, a shell variable or the script's
# own name (GUEST_USER, REPO, SSH_KEY) as VAR, build_host.py's ssh override set,
# an app with no switch_env, an unknown app or host, a replica.
# Plain ARGs (switch_args): the checked ARGs on the remote command, shell-quoted, with or without a
# VAR (d05's fetch-bundle form); refused before ssh: a wrong count, an ARG not matching its pattern
# (a shell-meta character, a trailing newline), ARGs to a switch with none, an upper-case word to a
# switch that takes no VAR, a switch_args switch not in switch_env, an unanchored or broken pattern.
# Two VARs (a switch_env list of two): one ssh, stdin the two values one line each in the list's
# order, with or without an ARG, under every start above and the exported functions; refused: the
# other order, one of the two, none, the same name twice, a third, a VAR after an ARG, a reserved
# name second, and each value unset, empty or holding a newline or carriage return.
# Every value is a plain stand-in word made at run time. Nothing reaches a host.
# Run: bash scripts/tests/test_app_switch_sh.sh
set -uo pipefail
unset LDAP_PROVISIONER_PASSWORD THEORG_REGISTRY_PULL_TOKEN AAA BBB CCC ABC BUILD_HOST_SSH_KEY BUILD_HOST_SSH_KNOWN_HOSTS BUILD_HOST_SSH_BY_ADDRESS

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }

REAL_PY="$(command -v python3)"
REAL_DIRNAME="$(command -v dirname)"
mkdir -p "$T/bin" "$T/home/.ssh"
# ssh: its argv one line each in STUB_LOG, its stdin into STUB_STDIN (read only by the checks), its
# environment into STUB_ENVDUMP; exit STUB_SSH_RC.
cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
echo "SSH" >> "$STUB_LOG"
for a in "$@"; do printf 'ARG %s\n' "$a" >> "$STUB_LOG"; done
cat > "$STUB_STDIN"
env >> "$STUB_ENVDUMP"
exit "${STUB_SSH_RC:-0}"
EOF
printf '#!/bin/bash\nenv >> "$STUB_ENVDUMP"\nexec %q "$@"\n' "$REAL_PY" > "$T/bin/python3"
printf '#!/bin/bash\nenv >> "$STUB_ENVDUMP"\nexec %q "$@"\n' "$REAL_DIRNAME" > "$T/bin/dirname"
chmod +x "$T/bin/ssh" "$T/bin/python3" "$T/bin/dirname"
for s in ssh python3 dirname; do
  [ "$(PATH="$T/bin:$PATH" command -v "$s")" = "$T/bin/$s" ] || { echo "stub $s not runnable in $T/bin" >&2; exit 2; }
done

# A second tree for the cases d05's spec has none of: a two-name list, no switch_env, a replica.
F="$T/repo"
mkdir -p "$F/scripts" "$F/h01" "$F/h02"
cp "$REPO/scripts/app_switch.sh" "$F/scripts/"
cat > "$F/h01/host.toml" <<'EOF'
[[app]]
name = "two"
switch_env = { "pair" = ["AAA", "BBB"], "pair-arg" = ["AAA", "BBB"], "triple" = ["AAA", "BBB", "CCC"], "dup" = ["AAA", "AAA"], "one" = ["AAA"], "none" = [], "fetch" = ["AAA"], "two-args" = [], "quoted" = [] }
switch_args = { "fetch" = ['^m5-[0-9a-f]{12}$'], "pair-arg" = ['^[a-z]+$'], "two-args" = ['^[a-z]+$', '^[0-9]+$'], "quoted" = ['^[a-z ;]+$'] }
[[app]]
name = "plain"
[[app]]
name = "stray"
switch_env = { "x" = [] }
switch_args = { "y" = ['^a$'] }
[[app]]
name = "unanchored"
switch_env = { "x" = [] }
switch_args = { "x" = ['a'] }
[[app]]
name = "broken"
switch_env = { "x" = [] }
switch_args = { "x" = ['^(a$'] }
EOF
printf '[replica]\nof = "h01"\n[[app]]\nname = "two"\nswitch_env = { "none" = [] }\n' > "$F/h02/host.toml"

# A plain stand-in word per run, unlike any real value.
V1="stand-in-value-a-$$" V2="stand-in-value-b-$$" V3="stand-in-value-c-$$"

go() {   # go SCRIPT ARG...: run it with HOME, PATH and the stub files set; env names in $GO_ENV
  : > "$T/log"; : > "$T/stdin"; : > "$T/envdump"
  # GO_ENV as a prefix of this call is exported for its duration: out of the environment first.
  local rc e="${GO_ENV:-}"
  unset GO_ENV
  OUT="$(env $e HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_STDIN="$T/stdin" \
    STUB_ENVDUMP="$T/envdump" bash "$@" 2>&1)"
  rc=$?
  return "$rc"
}
nowhere() {   # no value in the output, the ssh argv log or any child's environment
  local v
  for v in "$V1" "$V2" "$V3"; do
    grep -qF -- "$v" <<< "$OUT" && return 1
    grep -qF -- "$v" "$T/log" "$T/envdump" && return 1
  done
  return 0
}
args() { sed -n 's/^ARG //p' "$T/log"; }   # the ssh argv, one per line
no_ssh() { ! grep -q '^SSH' "$T/log"; }

S="$REPO/scripts/app_switch.sh"
IP="~/scripts/d05/apps/identity-platform/identity-platform.sh"

# --- leaf-issue on d05: one ssh, the exact argv, the value on stdin only ---
GO_ENV="LDAP_PROVISIONER_PASSWORD=$V1" go "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD; rc=$?
remote="$IP leaf-issue"
want="$(printf '%s\n' ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$T/home/.ssh/docker_rsa" docker@d05 "$remote")"
[ "$rc" -eq 0 ] && [ "$(grep -c '^SSH$' "$T/log")" -eq 1 ] && [ "ssh
$(args)" = "$want" ] \
  && ok "leaf-issue: one ssh, build_host.py's options and key, the remote command the script and switch alone" \
  || bad "leaf-issue argv" "rc=$rc; $(args)"
! args | grep -qE 'export|read|bash -c|LDAP_PROVISIONER_PASSWORD' \
  && ok "leaf-issue: the remote command exports nothing, reads nothing and names no VAR" || bad "leaf-issue remote command" "$(args | tail -n 1)"
[ "$(cat "$T/stdin")" = "$V1" ] && [ "$(wc -l < "$T/stdin" | tr -d ' ')" -eq 1 ] \
  && ok "leaf-issue: ssh's stdin carries the value, one line" || bad "leaf-issue stdin" "lines=$(wc -l < "$T/stdin")"
nowhere && ok "leaf-issue: the value in no argv (the remote command line included), output, or ssh/python3/dirname environment" \
  || bad "leaf-issue leaks the value"
! grep -q '^LDAP_PROVISIONER_PASSWORD=' "$T/envdump" \
  && ok "leaf-issue: LDAP_PROVISIONER_PASSWORD unset before any child ran (not even by name in an env dump)" || bad "leaf-issue env name"
grep -q '^PATH=' "$T/envdump" && ok "the environment dumps were taken (the wrappers ran)" || bad "no env dump"
# build_host.py's own app_script gives the same remote command.
bh="$(cd "$REPO/scripts" && "$REAL_PY" -c '
import build_host as b
print(b.app_script("d05", "identity-platform") + " leaf-issue")
print(b.app_script("d05", "identity-platform") + " leaf-schedule-install")')"
[ "$(sed -n 1p <<< "$bh")" = "$remote" ] \
  && ok "the remote command is build_host.py's app_script and the switch, byte for byte" || bad "app_script differs" "$bh"

# --- a switch without a VAR: the script and switch alone, empty stdin ---
go "$S" d05 identity-platform leaf-schedule-install; rc=$?
[ "$rc" -eq 0 ] && [ "$(args | tail -n 1)" = "$IP leaf-schedule-install" ] && [ "$(sed -n 2p <<< "$bh")" = "$IP leaf-schedule-install" ] \
  && [ ! -s "$T/stdin" ] \
  && ok "leaf-schedule-install: remote command the script and switch (no VAR), stdin empty" || bad "no-var switch" "rc=$rc; $(args)"

# --- a VAR on another tree's switch: the same form ---
GO_ENV="AAA=$V1" go "$F/scripts/app_switch.sh" h01 two one AAA; rc=$?
[ "$rc" -eq 0 ] && [ "$(args | tail -n 1)" = "~/scripts/h01/apps/two/two.sh one" ] && [ "$(cat "$T/stdin")" = "$V1" ] && nowhere \
  && ok "one VAR (AAA) on h01: the script and switch alone, stdin its value, none leaked" || bad "one VAR" "rc=$rc; $(args | tail -n 1)"

# --- plain ARGs (switch_args): on the remote command after the switch, shell-quoted ---
GO_ENV="AAA=$V1" go "$F/scripts/app_switch.sh" h01 two fetch AAA m5-0123456789ab; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^SSH$' "$T/log")" -eq 1 ] && [ "$(args | tail -n 1)" = "~/scripts/h01/apps/two/two.sh fetch m5-0123456789ab" ] \
  && [ "$(cat "$T/stdin")" = "$V1" ] && nowhere && ! grep -q '^AAA=' "$T/envdump" \
  && ok "a VAR and an ARG: the ARG on the remote command, the value on stdin alone" || bad "VAR + ARG" "rc=$rc; $(args | tail -n 1)"
go "$F/scripts/app_switch.sh" h01 two two-args abc 42; rc=$?
[ "$rc" -eq 0 ] && [ "$(args | tail -n 1)" = "~/scripts/h01/apps/two/two.sh two-args abc 42" ] && [ ! -s "$T/stdin" ] \
  && ok "two lower-case ARGs to a switch with no VAR: both on the remote command, stdin empty" || bad "two ARGs" "rc=$rc; $(args | tail -n 1)"
go "$F/scripts/app_switch.sh" h01 two quoted 'a b;c'; rc=$?
[ "$rc" -eq 0 ] && [ "$(args | tail -n 1)" = '~/scripts/h01/apps/two/two.sh quoted a\ b\;c' ] \
  && ok "an ARG its pattern lets hold a space and ; goes shell-quoted (printf %q), one word" || bad "quoted ARG" "rc=$rc; $(args | tail -n 1)"
GO_ENV="THEORG_REGISTRY_PULL_TOKEN=$V1" go "$S" d05 identity-platform fetch-bundle THEORG_REGISTRY_PULL_TOKEN m5-0123456789ab; rc=$?
[ "$rc" -eq 0 ] && [ "$(args | tail -n 1)" = "$IP fetch-bundle m5-0123456789ab" ] && [ "$(cat "$T/stdin")" = "$V1" ] && nowhere \
  && ! grep -q '^THEORG_REGISTRY_PULL_TOKEN=' "$T/envdump" \
  && ok "d05 fetch-bundle: the version on the remote command, the value on stdin alone" || bad "d05 fetch-bundle" "rc=$rc; $(args | tail -n 1)"
H1="0123456789ab$(printf '0%.0s' {1..52})" H2="$(printf 'b%.0s' {1..64})" H3="$(printf 'c%.0s' {1..64})"
GO_ENV="IDP_CUTOVER_BUNDLE_IDENTITY=$V1" go "$S" d05 identity-platform unpack-bundle IDP_CUTOVER_BUNDLE_IDENTITY "$H1" "$H2" "$H3"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^SSH$' "$T/log")" -eq 1 ] && [ "$(args | tail -n 1)" = "$IP unpack-bundle $H1 $H2 $H3" ] \
  && [ "$(cat "$T/stdin")" = "$V1" ] && [ "$(wc -l < "$T/stdin" | tr -d ' ')" -eq 1 ] && nowhere \
  && ! grep -q '^IDP_CUTOVER_BUNDLE_IDENTITY=' "$T/envdump" \
  && ok "d05 unpack-bundle: the three sha256 ARGs on the remote command, the value on stdin alone" || bad "d05 unpack-bundle" "rc=$rc; $(args | tail -n 1)"
for sw in reset-cutover cutover-clean restore-openldap count-check cutover-done restore-mirror restore-mirror-accept-age reset-mirror mirror-check; do
  go "$S" d05 identity-platform "$sw"; rc=$?
  [ "$rc" -eq 0 ] && [ "$(args | tail -n 1)" = "$IP $sw" ] && [ ! -s "$T/stdin" ] \
    && ok "d05 $sw: allowed, no VAR, no ARG, stdin empty" || bad "d05 $sw" "rc=$rc; $(args | tail -n 1)"
done
GO_ENV="IDP_KEYCLOAK_DB_PASSWORD=$V1" go "$S" d05 identity-platform restore-keycloak IDP_KEYCLOAK_DB_PASSWORD; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^SSH$' "$T/log")" -eq 1 ] && [ "$(args | tail -n 1)" = "$IP restore-keycloak" ] \
  && [ "$(cat "$T/stdin")" = "$V1" ] && [ "$(wc -l < "$T/stdin" | tr -d ' ')" -eq 1 ] && nowhere \
  && ! grep -q '^IDP_KEYCLOAK_DB_PASSWORD=' "$T/envdump" \
  && ok "d05 restore-keycloak: the switch alone on the remote command, keycloak-db's value on stdin alone" \
  || bad "d05 restore-keycloak" "rc=$rc; $(args | tail -n 1)"
for pair in start-openldap:IDP_LDAP_ADMIN_PASSWORD start-keycloak:IDP_KEYCLOAK_DB_PASSWORD; do
  sw="${pair%%:*}" var="${pair#*:}"
  GO_ENV="$var=$V1" go "$S" d05 identity-platform "$sw" "$var"; rc=$?
  [ "$rc" -eq 0 ] && [ "$(grep -c '^SSH$' "$T/log")" -eq 1 ] && [ "$(args | tail -n 1)" = "$IP $sw" ] \
    && [ "$(cat "$T/stdin")" = "$V1" ] && [ "$(wc -l < "$T/stdin" | tr -d ' ')" -eq 1 ] && nowhere \
    && ! grep -q "^$var=" "$T/envdump" \
    && ok "d05 $sw: the switch alone on the remote command, $var's value on stdin alone" \
    || bad "d05 $sw" "rc=$rc; $(args | tail -n 1)"
done
# (their missing-VAR refusals are below, after refused is defined)
GO_ENV="SHELLOPTS=xtrace AAA=$V1" go "$F/scripts/app_switch.sh" h01 two fetch AAA m5-0123456789ab; rc=$?
grep -q '^+' <<< "$OUT" && [ "$rc" -eq 0 ] && [ "$(cat "$T/stdin")" = "$V1" ] && nowhere \
  && ok "a VAR and an ARG under SHELLOPTS=xtrace: the value in no trace" || bad "VAR + ARG under xtrace" "rc=$rc"
GO_ENV="AAA=$V1" go -x "$F/scripts/app_switch.sh" h01 two fetch AAA m5-0123456789ab; rc=$?
grep -q '^+' <<< "$OUT" && [ "$rc" -eq 0 ] && [ "$(cat "$T/stdin")" = "$V1" ] && nowhere \
  && ok "a VAR and an ARG under bash -x: the value in no trace" || bad "VAR + ARG under bash -x" "rc=$rc"

# --- the remote exit is kept ---
GO_ENV="STUB_SSH_RC=7" go "$S" d05 identity-platform leaf-renew; rc=$?
[ "$rc" -eq 7 ] && ok "the remote command's exit is app_switch's (7, no VAR)" || bad "exit kept" "rc=$rc"
GO_ENV="STUB_SSH_RC=5 LDAP_PROVISIONER_PASSWORD=$V1" go "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD; rc=$?
[ "$rc" -eq 5 ] && nowhere && ok "the remote command's exit is app_switch's (5, with a VAR)" || bad "exit kept with VAR" "rc=$rc"

# --- however the shell is started: tracing and allexport off before the value is read ---
traced() {   # traced LABEL: the last go ran leaf-issue (0), stdin the value, the value nowhere else
  [ "$rc" -eq 0 ] && [ "$(cat "$T/stdin")" = "$V1" ] && nowhere \
    && ok "$1: the value in no trace, output, argv or child environment" || bad "$1 leaks the value" "rc=$rc"
}
GO_ENV="SHELLOPTS=xtrace LDAP_PROVISIONER_PASSWORD=$V1" go "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD; rc=$?
grep -q '^+' <<< "$OUT" && traced "SHELLOPTS=xtrace inherited (tracing was on at start)" || bad "SHELLOPTS=xtrace: no trace seen at start" "$OUT"
GO_ENV="LDAP_PROVISIONER_PASSWORD=$V1" go -x "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD; rc=$?
grep -q '^+' <<< "$OUT" && traced "bash -x" || bad "bash -x: no trace seen at start" "$OUT"
printf 'set -x\n' > "$T/bashenv"
GO_ENV="BASH_ENV=$T/bashenv LDAP_PROVISIONER_PASSWORD=$V1" go "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD; rc=$?
grep -q '^+' <<< "$OUT" && traced "a BASH_ENV that sets -x" || bad "BASH_ENV: no trace seen at start" "$OUT"
GO_ENV="SHELLOPTS=allexport LDAP_PROVISIONER_PASSWORD=$V1" go "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD; rc=$?
traced "SHELLOPTS=allexport inherited"
# A same-named variable exported into the environment keeps its flag on assignment: unset first.
GO_ENV="val=x var=y LDAP_PROVISIONER_PASSWORD=$V1" go "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD; rc=$?
traced "val=x and var=y exported in the incoming environment"
! grep -qE '^(val|var)=' "$T/envdump" && ok "val and var unset before any child ran" || bad "val/var in a child env" "$(grep -E '^(val|var)=' "$T/envdump" | cut -c1-5)"

# --- a function named like a command the value passes through, exported into the incoming
# environment (export -f; bash imports it at start): printf and [ (the value as an argument), ssh
# (the value on its stdin). The script uses bash's builtin printf, [[ ]] and `builtin exec ssh`,
# so none of them runs with the value. [ also runs elsewhere in the script, and printf in the ssh
# stub (a bash child): their record shows the exported function was in force.
for shadow in printf '[' ssh; do
  case "$shadow" in
    printf) printf() { builtin printf 'printf %s\n' "$*" >> "$STUB_SHADOW"; builtin printf "$@"; } ;;
    '[') [() { builtin printf '[ %s\n' "$*" >> "$STUB_SHADOW"; builtin [ "$@"; } ;;
    ssh) ssh() { { builtin printf 'ssh stdin '; cat; } >> "$STUB_SHADOW"; } ;;
  esac
  : > "$T/shadow"
  export -f "$shadow"
  GO_ENV="STUB_SHADOW=$T/shadow LDAP_PROVISIONER_PASSWORD=$V1" go "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD; rc=$?
  unset -f "$shadow"
  inforce=true
  case "$shadow" in printf) grep -q '^printf ' "$T/shadow" || inforce=false ;; '[') grep -q '^\[ ' "$T/shadow" || inforce=false ;; esac
  [ "$rc" -eq 0 ] && [ "$(cat "$T/stdin")" = "$V1" ] && ! grep -qF -- "$V1" "$T/shadow" && $inforce && nowhere \
    && ok "an exported $shadow function: it never sees the value; the ssh program's stdin carries it" \
    || bad "exported $shadow function" "rc=$rc; in-force=$inforce; seen=$(grep -cF -- "$V1" "$T/shadow")"
done
rm -f "$T/shadow"

# --- two VARs (switch_env lists two): one ssh, the remote command the script, switch and ARGs
# alone, ssh's stdin the two values one line each in switch_env's order, neither in any argv,
# output, trace or child environment ---
P="$F/scripts/app_switch.sh"
two_ok() {   # two_ok LABEL REMOTE: the last go ran (0): one ssh, REMOTE, stdin V1 then V2, nothing leaked
  [ "$rc" -eq 0 ] && [ "$(grep -c '^SSH$' "$T/log")" -eq 1 ] && [ "$(args | tail -n 1)" = "$2" ] \
    && [ "$(cat "$T/stdin")" = "$V1
$V2" ] && [ "$(wc -l < "$T/stdin" | tr -d ' ')" -eq 2 ] && nowhere \
    && ! grep -qE '^(AAA|BBB)=' "$T/envdump" \
    && ok "$1" || bad "$1" "rc=$rc; $(args | tail -n 1); stdin lines=$(wc -l < "$T/stdin" | tr -d ' ')"
}
GO_ENV="AAA=$V1 BBB=$V2" go "$P" h01 two pair AAA BBB; rc=$?
two_ok "two VARs (pair AAA BBB): one ssh, the switch alone, stdin AAA's line then BBB's, neither name nor value in a child" "~/scripts/h01/apps/two/two.sh pair"
grep -qF "(over ssh stdin, one line each: AAA, BBB)" <<< "$OUT" && [ "$(args | head -n 1)" = "-o" ] \
  && ok "two VARs: the run line names both, in order; build_host.py's ssh options" || bad "two VARs run line" "$OUT"
GO_ENV="AAA=$V1 BBB=$V2" go "$P" h01 two pair-arg AAA BBB abc; rc=$?
two_ok "two VARs and an ARG (pair-arg AAA BBB abc): the ARG on the remote command, the values on stdin" "~/scripts/h01/apps/two/two.sh pair-arg abc"
GO_ENV="STUB_SSH_RC=6 AAA=$V1 BBB=$V2" go "$P" h01 two pair AAA BBB; rc=$?
[ "$rc" -eq 6 ] && nowhere && ok "the remote command's exit is app_switch's (6, two VARs)" || bad "exit kept with two VARs" "rc=$rc"
for start in "SHELLOPTS=xtrace" "-x" "BASH_ENV=$T/bashenv" "SHELLOPTS=allexport" "val2=x var2=y given=z"; do
  case "$start" in
    -x) GO_ENV="AAA=$V1 BBB=$V2" go -x "$P" h01 two pair AAA BBB; rc=$? ;;
    *) GO_ENV="$start AAA=$V1 BBB=$V2" go "$P" h01 two pair AAA BBB; rc=$? ;;
  esac
  traced_seen=true
  case "$start" in *xtrace|-x|BASH_ENV*) grep -q '^+' <<< "$OUT" || traced_seen=false ;; esac
  $traced_seen && ! grep -qE '^(val2|var2)=' "$T/envdump" \
    && two_ok "two VARs started with $start: the values in no trace, output, argv or child environment" "~/scripts/h01/apps/two/two.sh pair" \
    || bad "two VARs with $start" "trace seen=$traced_seen; $(grep -E '^(val2|var2)=' "$T/envdump" | cut -c1-6)"
done
for shadow in printf '[' ssh; do
  case "$shadow" in
    printf) printf() { builtin printf 'printf %s\n' "$*" >> "$STUB_SHADOW"; builtin printf "$@"; } ;;
    '[') [() { builtin printf '[ %s\n' "$*" >> "$STUB_SHADOW"; builtin [ "$@"; } ;;
    ssh) ssh() { { builtin printf 'ssh stdin '; cat; } >> "$STUB_SHADOW"; } ;;
  esac
  : > "$T/shadow"
  export -f "$shadow"
  GO_ENV="STUB_SHADOW=$T/shadow AAA=$V1 BBB=$V2" go "$P" h01 two pair AAA BBB; rc=$?
  unset -f "$shadow"
  ! grep -qF -e "$V1" -e "$V2" "$T/shadow" \
    && two_ok "two VARs with an exported $shadow function: it never sees either value" "~/scripts/h01/apps/two/two.sh pair" \
    || bad "two VARs, exported $shadow function" "seen=$(grep -cF -e "$V1" -e "$V2" "$T/shadow")"
done
rm -f "$T/shadow"
# Each value refused locally (exit 2, no ssh) when empty or holding a newline or CR: env takes them as words.
rawpair() {   # rawpair NAME=VALUE...: pair AAA BBB with exactly these in the environment
  : > "$T/log"; : > "$T/stdin"; : > "$T/envdump"
  OUT="$(env "$@" HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_STDIN="$T/stdin" \
    STUB_ENVDUMP="$T/envdump" bash "$P" h01 two pair AAA BBB 2>&1)"
}

# --- refusals: exit 2, no ssh, no value in the output ---
refused() {   # refused RC LABEL PATTERN: the last go refused (2) with PATTERN in its output
  local rc="$1" label="$2" pat="$3"
  [ "$rc" -eq 2 ] && no_ssh && grep -qE -- "$pat" <<< "$OUT" && nowhere \
    && ok "refused: $label" || bad "refusal $label" "rc=$rc; $OUT"
}
for pair in start-openldap:IDP_LDAP_ADMIN_PASSWORD start-keycloak:IDP_KEYCLOAK_DB_PASSWORD; do
  sw="${pair%%:*}" var="${pair#*:}"
  go "$S" d05 identity-platform "$sw"; refused $? "a listed VAR missing ($sw with none)" "needs exactly: $var"
done
# d05 configure: two VARs in switch_env's order; one ssh, the switch alone on the remote command,
# ssh's stdin the LDAP admin's value then the Dex client's, one line each, neither in any child.
CONF_VARS="IDP_LDAP_ADMIN_PASSWORD IDP_DEPLOY_DEX_CLIENT_SECRET"
GO_ENV="IDP_LDAP_ADMIN_PASSWORD=$V1 IDP_DEPLOY_DEX_CLIENT_SECRET=$V2" go "$S" d05 identity-platform configure $CONF_VARS; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^SSH$' "$T/log")" -eq 1 ] && [ "$(args | tail -n 1)" = "$IP configure" ] \
  && [ "$(cat "$T/stdin")" = "$V1
$V2" ] && [ "$(wc -l < "$T/stdin" | tr -d ' ')" -eq 2 ] && nowhere \
  && ! grep -qE '^(IDP_LDAP_ADMIN_PASSWORD|IDP_DEPLOY_DEX_CLIENT_SECRET)=' "$T/envdump" \
  && ok "d05 configure: the switch alone on the remote command, the LDAP admin's then the Dex client's value on stdin, one line each" \
  || bad "d05 configure" "rc=$rc; $(args | tail -n 1); stdin lines=$(wc -l < "$T/stdin" | tr -d ' ')"
GO_ENV="IDP_LDAP_ADMIN_PASSWORD=$V1" go "$S" d05 identity-platform configure IDP_LDAP_ADMIN_PASSWORD; refused $? "configure with one of its two VARs" "configure takes $CONF_VARS; IDP_LDAP_ADMIN_PASSWORD is not listed"
go "$S" d05 identity-platform configure; refused $? "configure with neither VAR" "needs exactly: $CONF_VARS"
GO_ENV="IDP_LDAP_ADMIN_PASSWORD=$V1 IDP_DEPLOY_DEX_CLIENT_SECRET=$V2" go "$S" d05 identity-platform configure IDP_DEPLOY_DEX_CLIENT_SECRET IDP_LDAP_ADMIN_PASSWORD
refused $? "configure with its two VARs in the other order" "configure takes $CONF_VARS; IDP_DEPLOY_DEX_CLIENT_SECRET IDP_LDAP_ADMIN_PASSWORD is not listed"
GO_ENV="LDAP_PROVISIONER_PASSWORD=$V1" go "$S" d05 identity-platform up LDAP_PROVISIONER_PASSWORD; refused $? "a switch not in switch_env (up)" "does not allow 'up'"
go "$S" d05 identity-platform verify; refused $? "a switch not in switch_env, no VAR (verify)" "does not allow 'verify'"
GO_ENV="LDAP_PROVISIONER_PASSWORD=$V1" go "$S" d05 identity-platform leaf-renew LDAP_PROVISIONER_PASSWORD; refused $? "a VAR not in switch_env for the switch (leaf-renew)" "not listed"
GO_ENV="AAA=$V1" go "$S" d05 identity-platform leaf-issue AAA; refused $? "a VAR not in switch_env (AAA for leaf-issue)" "takes LDAP_PROVISIONER_PASSWORD; AAA is not listed"
go "$S" d05 identity-platform leaf-issue; refused $? "a listed VAR missing (leaf-issue with none)" "needs exactly: LDAP_PROVISIONER_PASSWORD"
GO_ENV="IDP_KEYCLOAK_DB_PASSWORD=$V1" go "$S" d05 identity-platform restore-openldap IDP_KEYCLOAK_DB_PASSWORD; refused $? "a VAR to a switch that takes none (restore-openldap)" "not listed|takes no"
go "$S" d05 identity-platform restore-keycloak; refused $? "a listed VAR missing (restore-keycloak with none)" "needs exactly: IDP_KEYCLOAK_DB_PASSWORD"
GO_ENV="AAA=$V1 BBB=$V2" go "$F/scripts/app_switch.sh" h01 two one AAA BBB; refused $? "two VARs to a switch that takes one" "takes AAA; AAA BBB is not listed"
GO_ENV="LDAP_PROVISIONER_PASSWORD=$V1 AAA=$V2" go "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD AAA; refused $? "two VARs for leaf-issue" "takes LDAP_PROVISIONER_PASSWORD; LDAP_PROVISIONER_PASSWORD AAA is not listed"
GO_ENV="AAA=$V1 BBB=$V2" go "$F/scripts/app_switch.sh" h01 two triple AAA BBB; refused $? "a switch_env list naming three VARs" "at most two distinct variable names"
GO_ENV="AAA=$V1" go "$F/scripts/app_switch.sh" h01 two dup AAA; refused $? "a switch_env list naming one VAR twice" "at most two distinct variable names"
go "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD; refused $? "a VAR unset" "unset or empty"
GO_ENV="LDAP_PROVISIONER_PASSWORD=" go "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD; refused $? "a VAR empty" "unset or empty"
: > "$T/log"; : > "$T/stdin"; : > "$T/envdump"
OUT="$(LDAP_PROVISIONER_PASSWORD="$V1
$V2" HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_STDIN="$T/stdin" STUB_ENVDUMP="$T/envdump" \
  bash "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD 2>&1)"; refused $? "a VAR holding a newline" "holds a newline"
go "$S" d05 identity-platform leaf-issue PATH; refused $? "a shell variable as VAR (PATH)" "shell or ssh variable"
for own in GUEST_USER REPO SSH_KEY; do
  GO_ENV="$own=$V1" go "$S" d05 identity-platform leaf-issue "$own"; refused $? "the script's own name as VAR ($own)" "shell or ssh variable"
done
GO_ENV="BUILD_HOST_SSH_KEY=$T/k" go "$S" d05 identity-platform leaf-renew; refused $? "build_host.py's ssh override set" "no ssh override"
go "$F/scripts/app_switch.sh" h01 plain none; refused $? "an app with no switch_env" "no switch_env"
go "$S" d05 no-such-app leaf-renew; refused $? "an unknown app" "no \[\[app\]\] 'no-such-app'"
go "$S" nohost identity-platform leaf-renew; refused $? "an unknown host" "no host.toml"
go "$F/scripts/app_switch.sh" h02 two none; refused $? "a replica's spec" "replica"
go "$S" d05 identity-platform; refused $? "too few arguments" "usage"
go "$S" 'd05;x' identity-platform leaf-renew; refused $? "a host name with other characters" "HOST must match"
# Two VARs: names, order, count and each value.
GO_ENV="AAA=$V1 BBB=$V2" go "$P" h01 two pair BBB AAA; refused $? "two VARs in the other order" "takes AAA BBB; BBB AAA is not listed"
GO_ENV="AAA=$V1" go "$P" h01 two pair AAA; refused $? "one VAR of a pair" "takes AAA BBB; AAA is not listed"
GO_ENV="BBB=$V2" go "$P" h01 two pair BBB; refused $? "the pair's second VAR alone" "takes AAA BBB; BBB is not listed"
go "$P" h01 two pair; refused $? "no VAR for a pair" "needs exactly: AAA BBB"
GO_ENV="AAA=$V1" go "$P" h01 two pair AAA AAA; refused $? "the same VAR twice" "VAR AAA given twice"
GO_ENV="AAA=$V1 BBB=$V2 CCC=$V3" go "$P" h01 two pair AAA BBB CCC; refused $? "three VARs" "at most two VARs, given first"
GO_ENV="AAA=$V1 BBB=$V2" go "$P" h01 two none AAA BBB; refused $? "two VARs to a switch that takes none" "takes no VAR; AAA BBB is not listed"
GO_ENV="AAA=$V1" go "$P" h01 two pair AAA PATH; refused $? "a shell variable as VAR2 (PATH)" "VAR PATH is a shell or ssh variable"
GO_ENV="AAA=$V1 SSH_KEY=$V2" go "$P" h01 two pair AAA SSH_KEY; refused $? "the script's own name as VAR2 (SSH_KEY)" "VAR SSH_KEY is a shell or ssh variable"
rawpair AAA="$V1"; refused $? "VAR2 unset" "BBB is unset or empty"
rawpair AAA="$V1" BBB=; refused $? "VAR2 empty" "BBB is unset or empty"
rawpair AAA= BBB="$V2"; refused $? "VAR empty, VAR2 set" "AAA is unset or empty"
rawpair AAA="$V1" BBB="$V2
$V3"; refused $? "VAR2 holding a newline" "BBB holds a newline"
rawpair AAA="$V1" BBB="$V2"$'\r'; refused $? "VAR2 holding a carriage return" "BBB holds a newline"
rawpair AAA="$V1"$'\r' BBB="$V2"; refused $? "VAR holding a carriage return" "AAA holds a newline"
rawpair AAA="$V1
$V3" BBB="$V2"; refused $? "VAR holding a newline" "AAA holds a newline"

# --- ARG refusals: before ssh ---
H="$F/scripts/app_switch.sh"
GO_ENV="AAA=$V1" go "$H" h01 two fetch AAA; refused $? "too few ARGs (none for fetch's one)" "takes exactly 1 ARG"
GO_ENV="AAA=$V1" go "$H" h01 two fetch AAA m5-0123456789ab m5-0123456789ab; refused $? "too many ARGs (two for fetch's one)" "takes exactly 1 ARG"
go "$H" h01 two two-args abc; refused $? "too few ARGs, no VAR (one for two)" "takes exactly 2 ARG"
GO_ENV="AAA=$V1" go "$H" h01 two fetch AAA m5-0123456789AB; refused $? "an ARG not matching its pattern (upper-case hex)" "ARG 1 does not match"
go "$H" h01 two two-args abc x42; refused $? "the second ARG not matching its pattern" "ARG 2 does not match"
GO_ENV="AAA=$V1" go "$H" h01 two fetch AAA 'm5-0123456789ab;id'; refused $? "a shell-meta ARG (;)" "ARG 1 does not match"
GO_ENV="AAA=$V1" go "$H" h01 two fetch AAA '$(id)'; refused $? "a shell-meta ARG (\$(...))" "ARG 1 does not match"
GO_ENV="AAA=$V1" go "$H" h01 two fetch AAA "m5-0123456789ab
"; refused $? "an ARG with a trailing newline (fullmatch, not \$ before a newline)" "ARG 1 does not match"
go "$H" h01 two none abc; refused $? "an ARG to a switch with none" "takes no ARG"
go "$S" d05 identity-platform leaf-renew abc; refused $? "an ARG to a d05 switch with none (leaf-renew)" "takes no ARG"
GO_ENV="LDAP_PROVISIONER_PASSWORD=$V1" go "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD abc; refused $? "an ARG to leaf-issue (VAR, no ARGs)" "takes no ARG"
GO_ENV="ABC=$V1" go "$H" h01 two two-args ABC abc 42; refused $? "an upper-case word to a switch with ARGs and no VAR: a VAR, not an ARG" "takes no VAR"
go "$H" h01 two fetch m5-0123456789ab; refused $? "an ARG without the switch's VAR" "needs exactly: AAA"
GO_ENV="AAA=$V1 BBB=$V2" go "$H" h01 two fetch AAA m5-0123456789ab BBB; refused $? "a second VAR after an ARG (its value in no child environment)" "at most two VARs, given first"
GO_ENV="AAA=$V1 BBB=$V2" go "$H" h01 two pair-arg AAA abc BBB; refused $? "VAR2 after an ARG (its value in no child environment)" "at most two VARs, given first"
go "$H" h01 stray x; refused $? "a switch_args switch not in switch_env" "all in switch_env"
go "$H" h01 unanchored x a; refused $? "an unanchored switch_args pattern" "anchored patterns"
go "$H" h01 broken x a; refused $? "a switch_args pattern that does not compile" "does not compile"

# --- d05's allowlist: each value goes to its one switch alone ---
"$REAL_PY" - "$REPO/d05/host.toml" <<'PY' && ok "d05 switch_env: LDAP_PROVISIONER_PASSWORD for leaf-issue, the pull token for fetch-bundle, the age identity for unpack-bundle, keycloak-db's for restore-keycloak and start-keycloak, the LDAP admin's for start-openldap, the LDAP admin's then the deploy Dex client's for configure, no other VAR (reset-cutover, cutover-clean, restore-openldap, count-check, cutover-done, restore-mirror, restore-mirror-accept-age, reset-mirror and mirror-check none); no up or restore switch listed; build restore false; start_env keycloak-db's then the LDAP admin's; switch_args for fetch-bundle and unpack-bundle alone" || bad "d05 switch_env"
import sys, tomllib
a = [x for x in tomllib.load(open(sys.argv[1], "rb"))["app"] if x["name"] == "identity-platform"][0]
se = a["switch_env"]
want = {"leaf-issue": ["LDAP_PROVISIONER_PASSWORD"], "fetch-bundle": ["THEORG_REGISTRY_PULL_TOKEN"],
        "unpack-bundle": ["IDP_CUTOVER_BUNDLE_IDENTITY"], "restore-keycloak": ["IDP_KEYCLOAK_DB_PASSWORD"],
        "start-openldap": ["IDP_LDAP_ADMIN_PASSWORD"], "start-keycloak": ["IDP_KEYCLOAK_DB_PASSWORD"],
        "configure": ["IDP_LDAP_ADMIN_PASSWORD", "IDP_DEPLOY_DEX_CLIENT_SECRET"]}
assert all(se[k] == v for k, v in want.items()), se
assert all(v == [] for k, v in se.items() if k not in want), se
assert set(se) == {"leaf-issue", "leaf-renew", "leaf-schedule-install", "leaf-schedule-status", "leaf-schedule-remove",
                   "fetch-bundle", "unpack-bundle", "reset-cutover", "cutover-clean",
                   "restore-keycloak", "restore-openldap", "start-openldap", "start-keycloak", "configure",
                   "count-check", "cutover-done", "restore-mirror", "restore-mirror-accept-age", "reset-mirror", "mirror-check"}, sorted(se)
assert not {"up", "pull", "images", "verify", "down", "restore"} & set(se), se
assert a["restore"] is False, a["restore"]
assert a["start_env"] == ["IDP_KEYCLOAK_DB_PASSWORD", "IDP_LDAP_ADMIN_PASSWORD"], a["start_env"]
assert a["switch_args"] == {"fetch-bundle": ["^m5-[0-9a-f]{12}$"],
                            "unpack-bundle": ["^[0-9a-f]{64}$"] * 3}, a["switch_args"]
PY

[ "$fail" -eq 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
