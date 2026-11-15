#!/bin/bash
# scripts/app_switch.sh against an ssh stub on PATH: the exact ssh argv (build_host.py's options and
# key; the remote command is build_host.py's app_script and the switch alone, no export and no read),
# stdin carrying the one value on one line (empty with no VAR), the value in no argv, log, output or
# child environment (ssh, python3 and dirname are PATH wrappers that dump their environment), the
# remote exit kept, the value in no trace or child environment however bash is started (bash -x,
# SHELLOPTS=xtrace or allexport, a BASH_ENV setting -x, val/var exported in the incoming
# environment), and every refusal (exit 2, no ssh): a switch not in switch_env, a VAR not listed
# for it, a listed VAR missing, a VAR unset, empty or holding a newline, more than one VAR (on the
# command line or in a switch_env list), a shell variable or the script's own name (GUEST_USER, REPO,
# SSH_KEY) as VAR, build_host.py's ssh override set,
# an app with no switch_env, an unknown app or host, a replica.
# Every value is a plain stand-in word made at run time. Nothing reaches a host.
# Run: bash scripts/tests/test_app_switch_sh.sh
set -uo pipefail
unset LDAP_PROVISIONER_PASSWORD AAA BBB CCC BUILD_HOST_SSH_KEY BUILD_HOST_SSH_KNOWN_HOSTS BUILD_HOST_SSH_BY_ADDRESS

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
switch_env = { "pair" = ["AAA", "BBB"], "one" = ["AAA"], "none" = [] }
[[app]]
name = "plain"
EOF
printf '[replica]\nof = "h01"\n[[app]]\nname = "two"\nswitch_env = { "none" = [] }\n' > "$F/h02/host.toml"

# A plain stand-in word per run, unlike any real value.
V1="stand-in-value-a-$$" V2="stand-in-value-b-$$"

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
  for v in "$V1" "$V2"; do
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

# --- refusals: exit 2, no ssh, no value in the output ---
refused() {   # refused RC LABEL PATTERN: the last go refused (2) with PATTERN in its output
  local rc="$1" label="$2" pat="$3"
  [ "$rc" -eq 2 ] && no_ssh && grep -qE -- "$pat" <<< "$OUT" && nowhere \
    && ok "refused: $label" || bad "refusal $label" "rc=$rc; $OUT"
}
GO_ENV="LDAP_PROVISIONER_PASSWORD=$V1" go "$S" d05 identity-platform up LDAP_PROVISIONER_PASSWORD; refused $? "a switch not in switch_env (up)" "does not allow 'up'"
go "$S" d05 identity-platform verify; refused $? "a switch not in switch_env, no VAR (verify)" "does not allow 'verify'"
GO_ENV="LDAP_PROVISIONER_PASSWORD=$V1" go "$S" d05 identity-platform leaf-renew LDAP_PROVISIONER_PASSWORD; refused $? "a VAR not in switch_env for the switch (leaf-renew)" "not listed"
GO_ENV="AAA=$V1" go "$S" d05 identity-platform leaf-issue AAA; refused $? "a VAR not in switch_env (AAA for leaf-issue)" "takes LDAP_PROVISIONER_PASSWORD; AAA is not listed"
go "$S" d05 identity-platform leaf-issue; refused $? "a listed VAR missing (leaf-issue with none)" "needs exactly: LDAP_PROVISIONER_PASSWORD"
GO_ENV="AAA=$V1 BBB=$V2" go "$F/scripts/app_switch.sh" h01 two pair AAA BBB; refused $? "more than one VAR on the command line" "at most one VAR"
GO_ENV="LDAP_PROVISIONER_PASSWORD=$V1 AAA=$V2" go "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD AAA; refused $? "more than one VAR for leaf-issue" "at most one VAR"
GO_ENV="AAA=$V1" go "$F/scripts/app_switch.sh" h01 two pair AAA; refused $? "a switch_env list naming two VARs" "at most one variable name"
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

# --- d05's allowlist: the value goes to leaf-issue alone ---
"$REAL_PY" - "$REPO/d05/host.toml" <<'PY' && ok "d05 switch_env: LDAP_PROVISIONER_PASSWORD for leaf-issue alone; no start switch listed" || bad "d05 switch_env"
import sys, tomllib
a = [x for x in tomllib.load(open(sys.argv[1], "rb"))["app"] if x["name"] == "identity-platform"][0]
se = a["switch_env"]
assert se["leaf-issue"] == ["LDAP_PROVISIONER_PASSWORD"], se
assert all(v == [] for k, v in se.items() if k != "leaf-issue"), se
assert not {"up", "pull", "images", "verify", "down"} & set(se), se
PY

[ "$fail" -eq 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
