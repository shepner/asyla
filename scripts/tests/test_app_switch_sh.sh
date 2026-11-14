#!/bin/bash
# scripts/app_switch.sh against an ssh stub on PATH: the exact ssh argv (build_host.py's options and
# key, and its env_command's remote command, compared with build_host.py's own), stdin carrying each
# value on its own line in the order given, the value in no argv, log, output or child environment
# (ssh, python3 and dirname are PATH wrappers that dump their environment), the remote exit kept,
# and every refusal (exit 2, no ssh): a switch not in switch_env, a VAR not listed for it, a listed
# VAR missing, a VAR unset, empty or holding a newline, a VAR named twice, a shell variable as VAR,
# build_host.py's ssh override set, an app with no switch_env, an unknown app or host, a replica.
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

# A second tree for the cases d05's spec has none of: two VARs, no switch_env, a replica.
F="$T/repo"
mkdir -p "$F/scripts" "$F/h01" "$F/h02" "$F/h03"
cp "$REPO/scripts/app_switch.sh" "$F/scripts/"
cat > "$F/h01/host.toml" <<'EOF'
[[app]]
name = "two"
switch_env = { "pair" = ["AAA", "BBB"], "none" = [] }
[[app]]
name = "plain"
EOF
printf '[replica]\nof = "h01"\n[[app]]\nname = "two"\nswitch_env = { "none" = [] }\n' > "$F/h02/host.toml"
printf '[[app]]\nname = "two"\nswitch_env = { "pair" = ["AAA", "AAA"] }\n' > "$F/h03/host.toml"

# A plain stand-in word per run, unlike any real value.
V1="switch-standin-a-$$" V2="switch-standin-b-$$"

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
remote="bash -c 'IFS= read -r LDAP_PROVISIONER_PASSWORD && export LDAP_PROVISIONER_PASSWORD && $IP leaf-issue'"
want="$(printf '%s\n' ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$T/home/.ssh/docker_rsa" docker@d05 "$remote")"
[ "$rc" -eq 0 ] && [ "$(grep -c '^SSH$' "$T/log")" -eq 1 ] && [ "ssh
$(args)" = "$want" ] \
  && ok "leaf-issue: one ssh, build_host.py's options and key, the exact remote command" \
  || bad "leaf-issue argv" "rc=$rc; $(args)"
[ "$(cat "$T/stdin")" = "$V1" ] && [ "$(wc -l < "$T/stdin" | tr -d ' ')" -eq 1 ] \
  && ok "leaf-issue: stdin carries the value, one line" || bad "leaf-issue stdin" "lines=$(wc -l < "$T/stdin")"
nowhere && ok "leaf-issue: the value in no argv, ssh log, output, or ssh/python3/dirname environment" \
  || bad "leaf-issue leaks the value"
grep -q '^PATH=' "$T/envdump" && ok "the environment dumps were taken (the wrappers ran)" || bad "no env dump"
# build_host.py's own env_command and app_script give the same remote command and stdin.
bh="$(cd "$REPO/scripts" && "$REAL_PY" -c '
import build_host as b
cmd, stdin = b.env_command([("LDAP_PROVISIONER_PASSWORD", "x")], b.app_script("d05", "identity-platform") + " leaf-issue")
print(cmd); print(repr(stdin))
none, nin = b.env_command([], b.app_script("d05", "identity-platform") + " leaf-schedule-install")
print(none); print(repr(nin))')"
[ "$(sed -n 1p <<< "$bh")" = "$remote" ] && [ "$(sed -n 2p <<< "$bh")" = "'x\\n'" ] \
  && ok "the remote command is build_host.py's env_command, byte for byte (stdin: value and newline)" \
  || bad "env_command differs" "$bh"

# --- a switch without VARs: the script and switch alone, empty stdin ---
go "$S" d05 identity-platform leaf-schedule-install; rc=$?
[ "$rc" -eq 0 ] && [ "$(args | tail -n 1)" = "$IP leaf-schedule-install" ] && [ "$(sed -n 3p <<< "$bh")" = "$IP leaf-schedule-install" ] \
  && [ ! -s "$T/stdin" ] \
  && ok "leaf-schedule-install: remote command is env_command's (no VAR), stdin empty" || bad "no-var switch" "rc=$rc; $(args)"

# --- two VARs: read and sent in the order given ---
GO_ENV="AAA=$V1 BBB=$V2" go "$F/scripts/app_switch.sh" h01 two pair AAA BBB; rc=$?
[ "$rc" -eq 0 ] && [ "$(args | tail -n 1)" = "bash -c 'IFS= read -r AAA && IFS= read -r BBB && export AAA BBB && ~/scripts/h01/apps/two/two.sh pair'" ] \
  && [ "$(cat "$T/stdin")" = "$V1
$V2" ] && nowhere \
  && ok "two VARs (AAA BBB): reads in that order, stdin the values in that order, none leaked" || bad "two VARs" "rc=$rc; $(args | tail -n 1)"
GO_ENV="AAA=$V1 BBB=$V2" go "$F/scripts/app_switch.sh" h01 two pair BBB AAA; rc=$?
[ "$rc" -eq 0 ] && [ "$(args | tail -n 1)" = "bash -c 'IFS= read -r BBB && IFS= read -r AAA && export BBB AAA && ~/scripts/h01/apps/two/two.sh pair'" ] \
  && [ "$(cat "$T/stdin")" = "$V2
$V1" ] \
  && ok "two VARs (BBB AAA): each read matches its stdin line" || bad "two VARs reversed" "rc=$rc; $(args | tail -n 1)"

# --- the remote exit is kept ---
GO_ENV="STUB_SSH_RC=7" go "$S" d05 identity-platform leaf-renew; rc=$?
[ "$rc" -eq 7 ] && ok "the remote command's exit is app_switch's (7)" || bad "exit kept" "rc=$rc"

# --- refusals: exit 2, no ssh, no value in the output ---
refused() {   # refused RC LABEL PATTERN: the last go refused (2) with PATTERN in its output
  local rc="$1" label="$2" pat="$3"
  [ "$rc" -eq 2 ] && no_ssh && grep -qE -- "$pat" <<< "$OUT" && nowhere \
    && ok "refused: $label" || bad "refusal $label" "rc=$rc; $OUT"
}
GO_ENV="LDAP_PROVISIONER_PASSWORD=$V1" go "$S" d05 identity-platform up LDAP_PROVISIONER_PASSWORD; refused $? "a switch not in switch_env (up)" "does not allow 'up'"
go "$S" d05 identity-platform verify; refused $? "a switch not in switch_env, no VAR (verify)" "does not allow 'verify'"
GO_ENV="LDAP_PROVISIONER_PASSWORD=$V1" go "$S" d05 identity-platform leaf-renew LDAP_PROVISIONER_PASSWORD; refused $? "a VAR not listed for the switch (leaf-renew)" "not listed"
go "$S" d05 identity-platform leaf-issue; refused $? "a listed VAR missing (leaf-issue with none)" "needs exactly: LDAP_PROVISIONER_PASSWORD"
GO_ENV="AAA=$V1" go "$F/scripts/app_switch.sh" h01 two pair AAA; refused $? "one of two listed VARs missing" "needs exactly: AAA BBB"
go "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD; refused $? "a VAR unset" "unset or empty"
GO_ENV="LDAP_PROVISIONER_PASSWORD=" go "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD; refused $? "a VAR empty" "unset or empty"
: > "$T/log"; : > "$T/stdin"; : > "$T/envdump"
OUT="$(LDAP_PROVISIONER_PASSWORD="$V1
$V2" HOME="$T/home" PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_STDIN="$T/stdin" STUB_ENVDUMP="$T/envdump" \
  bash "$S" d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD 2>&1)"; refused $? "a VAR holding a newline" "holds a newline"
GO_ENV="AAA=$V1" go "$F/scripts/app_switch.sh" h01 two pair AAA AAA; refused $? "a VAR named twice" "named twice"
go "$S" d05 identity-platform leaf-issue PATH; refused $? "a shell variable as VAR (PATH)" "shell or ssh variable"
GO_ENV="BUILD_HOST_SSH_KEY=$T/k" go "$S" d05 identity-platform leaf-renew; refused $? "build_host.py's ssh override set" "no ssh override"
go "$F/scripts/app_switch.sh" h01 plain none; refused $? "an app with no switch_env" "no switch_env"
go "$S" d05 no-such-app leaf-renew; refused $? "an unknown app" "no \[\[app\]\] 'no-such-app'"
go "$S" nohost identity-platform leaf-renew; refused $? "an unknown host" "no host.toml"
go "$F/scripts/app_switch.sh" h02 two none; refused $? "a replica's spec" "replica"
GO_ENV="AAA=$V1" go "$F/scripts/app_switch.sh" h03 two pair AAA; refused $? "a switch_env list naming a VAR twice" "distinct"
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
