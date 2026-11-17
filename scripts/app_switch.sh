#!/bin/bash
# app_switch.sh HOST APP SWITCH [VAR [VAR2]] [ARG...]: the operator's one-off app command. Runs
# ~/scripts/HOST/apps/APP/APP.sh SWITCH [ARG...] on HOST over one ssh, with ssh's stdin passed
# straight to it. With a VAR, its value is read from this process's environment (the credentials
# capability puts it there) into a shell variable, the variable is unset from the environment
# before any child runs (so neither ssh nor the remote shell inherits it), and bash's builtin printf
# writes the value, one line, to ssh's stdin; the app script reads that line itself (e.g.
# identity-platform.sh leaf-issue). With two VARs, both values go the same way, one line each, in
# the order given (VAR's line first); the app script reads exactly two lines (identity-platform.sh
# configure). Nothing is exported on the host: the remote command is the script, the switch and its
# checked ARGs alone. A value is never in an argv, the output, a file or any environment past this
# shell's start. With no VAR, ssh's stdin is /dev/null.
#
# VAR or ARG: each of the first two words after SWITCH is a VAR when it is an upper-case name
# (^[A-Z_][A-Z0-9_]*$; the second only when the first is one); every other word is an ARG. So VARs
# always come first, and an upper-case name is never taken as an ARG: given to a switch that takes
# no VAR, it is refused ("takes no VAR"), never passed on, and one anywhere after the VARs (a third,
# or one after an ARG) is refused ("at most two VARs, given first") before any child runs. The same
# name twice is refused.
#
# Allowlist: HOST/host.toml's [[app]] APP has `switch_env`, a table of SWITCH -> the VARs it takes
# (a list of at most two distinct names, in the order they go on stdin), e.g. d05's
# identity-platform: { "leaf-issue" = ["LDAP_PROVISIONER_PASSWORD"], "leaf-renew" = [] }. A switch
# not in it is refused; the VARs given must be exactly that switch's, in its order (none when its
# list is empty). At most two VARs, on the command line and in the list. A VAR that is unset, empty
# or holds a newline or a carriage return is refused (one line each on stdin). A replica's spec is
# refused (its apps are another host's tree; build_host.py runs those).
# ARGs: the [[app]]'s optional `switch_args`, a table of SWITCH -> a list of patterns, one per
# argument, e.g. { "fetch-bundle" = ['^m5-[0-9a-f]{12}$'] }. A switch in switch_args takes exactly
# that many ARGs, each fully matching its pattern (Python re.fullmatch; each pattern anchored ^...$);
# a switch not in it takes none. Every switch in switch_args must also be in switch_env. A wrong
# count or an ARG that does not match is refused here, before ssh. ARGs are plain values and go on
# the remote command line, each shell-quoted (printf %q).
#
# ssh as build_host.py's ssh_argv without its override: ssh -o BatchMode=yes -o ConnectTimeout=10
# -i ~/.ssh/docker_rsa docker@HOST '~/scripts/HOST/apps/APP/APP.sh SWITCH'. The override
# (BUILD_HOST_SSH_KEY, BUILD_HOST_SSH_KNOWN_HOSTS, BUILD_HOST_SSH_BY_ADDRESS) is not implemented
# here, so it is refused rather than ignored. A shell variable of bash's own (PATH, HOME, IFS,
# BASH*, ...), ssh's (SSH_*) or this script's own (SSH_KEY, GUEST_USER, REPO) is refused as a VAR:
# it is unset here before anything runs. Tracing and allexport are turned off first, however this
# shell was started (bash -x, SHELLOPTS, BASH_ENV). The value passes only through builtins, keywords
# ([[ ]], case) and the ssh program (`builtin exec ssh`), never a function: a printf, [ or ssh
# function brought in by the environment (export -f) or BASH_ENV is never called with it.
# Exit: the remote command's, or 2 for a refusal here.
#
# From ~/local/asyla, e.g.:
#   python3 core/tools/credentials.py exec LDAP_PROVISIONER_PASSWORD -- \
#     projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD
#   projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform leaf-schedule-install
# and, a VAR with an ARG (once identity-platform.sh implements fetch-bundle; asyla #654):
#   python3 core/tools/credentials.py exec THEORG_REGISTRY_PULL_TOKEN -- \
#     projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform fetch-bundle THEORG_REGISTRY_PULL_TOKEN m5-<12 hex>
# and two VARs (once switch_env lists two for the switch):
#   python3 core/tools/credentials.py exec VAR VAR2 -- \
#     projects/asyla-hosts/scripts/app_switch.sh HOST APP SWITCH VAR VAR2
# This script's path, before any command runs: bash 3.2 (ws01's /bin/bash) loses BASH_SOURCE once
# a function imported from the environment has been called (an exported [, say).
self="${BASH_SOURCE[0]}"
set -euo pipefail
# No tracing and no allexport, whatever started this shell (`bash -x`, SHELLOPTS=xtrace or
# allexport in the environment, a BASH_ENV that sets either): a trace would print the value.
{ set +x; } 2>/dev/null
set +a

SSH_KEY="${HOME}/.ssh/docker_rsa"
GUEST_USER="docker"

refuse() { echo "app_switch: $*" >&2; exit 2; }

[ $# -ge 3 ] || refuse "usage: app_switch.sh HOST APP SWITCH [VAR [VAR2]] [ARG...]"
host="$1" app="$2" switch="$3"
shift 3
name_re='^[a-z][a-z0-9-]*$'
var_re='^[A-Z_][A-Z0-9_]*$'
# Bash's own and ssh's names, and this script's own uppercase ones (SSH_KEY, GUEST_USER, REPO): one
# of those as VAR would send this script's value, or be overwritten by it.
reserved_re='^(PATH|HOME|IFS|PWD|OLDPWD|SHELL|USER|LOGNAME|TERM|TMPDIR|LANG|LC_[A-Z_]*|UID|EUID|PPID|SHELLOPTS|BASH[A-Z0-9_]*|SSH_[A-Z0-9_]*|BUILD_HOST_[A-Z0-9_]*|SSH_KEY|GUEST_USER|REPO)$'
for o in BUILD_HOST_SSH_KEY BUILD_HOST_SSH_KNOWN_HOSTS BUILD_HOST_SSH_BY_ADDRESS; do
  [ -z "${!o+x}" ] || refuse "$o is set; this tool has no ssh override (build_host.py's), unset it"
done
[[ "$host" =~ $name_re ]] || refuse "HOST must match $name_re"
[[ "$app" =~ $name_re ]] || refuse "APP must match $name_re"
[[ "$switch" =~ $name_re ]] || refuse "SWITCH must match $name_re"
# The VAR's value into this shell alone (never exported), then out of the environment, before any
# child runs (dirname, python3, ssh): no other process carries it. Unset first: an assignment keeps
# the export flag of a same-named variable the environment brought in (val=x exported would hand
# the value to every child).
unset -v var val var2 val2 given
var="" val="" var2="" val2=""
# The first word is the VAR when it is an upper-case name (the header), and the word after it VAR2
# when it is one too; the rest are ARGs. Each value is checked, copied, then its name unset.
if [ $# -ge 1 ] && [[ "$1" =~ $var_re ]]; then
  var="$1"
  shift
  [[ ! "$var" =~ $reserved_re ]] || refuse "VAR $var is a shell or ssh variable, or this script's own; not sent"
  [[ -n ${!var:-} ]] || refuse "$var is unset or empty in this environment"
  case "${!var}" in *$'\n'*|*$'\r'*) refuse "$var holds a newline; one line on stdin" ;; esac
  val="${!var}"
  unset "$var"
  if [ $# -ge 1 ] && [[ "$1" =~ $var_re ]]; then
    var2="$1"
    shift
    [[ "$var2" != "$var" ]] || refuse "VAR $var given twice; two VARs are two names"
    [[ ! "$var2" =~ $reserved_re ]] || refuse "VAR $var2 is a shell or ssh variable, or this script's own; not sent"
    [[ -n ${!var2:-} ]] || refuse "$var2 is unset or empty in this environment"
    case "${!var2}" in *$'\n'*|*$'\r'*) refuse "$var2 holds a newline; one line on stdin" ;; esac
    val2="${!var2}"
    unset "$var2"
  fi
fi
# An upper-case name is never an ARG: one after the VARs is a third VAR, or a VAR after an ARG,
# refused before any child runs (its value would still be in this environment).
for a in ${1+"$@"}; do
  [[ ! "$a" =~ $var_re ]] || refuse "at most two VARs, given first (one line each on ssh stdin); $a is an upper-case name, not an ARG"
done
given="$var${var2:+ $var2}"

REPO="$(cd "$(dirname "$self")/.." && pwd)"
spec="$REPO/$host/host.toml"
[ -f "$spec" ] || refuse "$host has no host.toml in this repo"

# The switch's VARs from the spec, space-separated in order (none: an empty output), once its ARGs are checked against
# switch_args (ARGs are plain values, so they go in python3's argv).
allowed="$(python3 -I - "$spec" "$app" "$switch" ${1+"$@"} <<'PY'
import re, sys, tomllib
path, app, switch = sys.argv[1:4]
given = sys.argv[4:]
spec = tomllib.load(open(path, "rb"))
def no(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)
if "replica" in spec:
    no(f"{path} is a replica's spec; its apps are another host's (build_host.py runs those)")
apps = [a for a in spec.get("app", []) if a.get("name") == app]
if len(apps) != 1:
    no(f"{path}: no [[app]] {app!r}")
table = apps[0].get("switch_env")
if not isinstance(table, dict) or not table:
    no(f"{path}: [[app]] {app!r} has no switch_env table; no switch is allowed")
if switch not in table:
    no(f"{path}: [[app]] {app!r} switch_env does not allow {switch!r} (allowed: {', '.join(sorted(table))})")
names = table[switch]
if not isinstance(names, list) or len(names) > 2 or len(set(map(str, names))) != len(names) \
        or not all(isinstance(n, str) and re.fullmatch(r"[A-Z_][A-Z0-9_]*", n) for n in names):
    no(f"{path}: [[app]] {app!r} switch_env {switch!r} must be a list of at most two distinct variable names")
args = apps[0].get("switch_args", {})
if not isinstance(args, dict) or not set(args) <= set(table):
    no(f"{path}: [[app]] {app!r} switch_args must be a table whose switches are all in switch_env")
pats = args.get(switch, [])
if not isinstance(pats, list) or not all(
        isinstance(p, str) and p.startswith("^") and p.endswith("$") for p in pats):
    no(f"{path}: [[app]] {app!r} switch_args {switch!r} must be a list of anchored patterns (^...$)")
try:
    rx = [re.compile(p) for p in pats]
except re.error as e:
    no(f"{path}: [[app]] {app!r} switch_args {switch!r}: a pattern does not compile ({e})")
if not rx and given:
    no(f"{switch} takes no ARG (not in {app!r} switch_args); got {len(given)}")
if len(given) != len(rx):
    no(f"{switch} takes exactly {len(rx)} ARG(s) (switch_args); got {len(given)}")
for i, (r, a) in enumerate(zip(rx, given), 1):
    if not r.fullmatch(a):
        no(f"{switch}: ARG {i} does not match {r.pattern}")
print(" ".join(names))
PY
)" || refuse "refused (above)"

if [ "$given" != "$allowed" ]; then
  if [ -n "$given" ] && [ -n "$allowed" ]; then
    refuse "$switch takes $allowed; $given is not listed in $host's switch_env (the names and their order)"
  elif [ -n "$given" ]; then
    refuse "$switch takes no VAR; $given is not listed in $host's switch_env"
  else
    refuse "$switch needs exactly: $allowed"
  fi
fi

cmd="~/scripts/$host/apps/$app/$app.sh $switch"
for a in ${1+"$@"}; do
  cmd="$cmd $(builtin printf '%q' "$a")"
done
ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$SSH_KEY" "$GUEST_USER@$host" "$cmd")
shown="$switch${1+ $*}"
if [ -n "$var2" ]; then
  echo "app_switch: $host $app $shown (over ssh stdin, one line each: $var, $var2)" >&2
  rc=0
  # As below, both values in one builtin printf: VAR's line, then VAR2's.
  builtin printf '%s\n' "$val" "$val2" | (builtin exec "${ssh_cmd[@]}") || rc=$?
  val="" val2=""
  unset -v val val2
  exit "$rc"
elif [ -n "$var" ]; then
  echo "app_switch: $host $app $shown (over ssh stdin: $var)" >&2
  rc=0
  # `builtin exec` in its own subshell: the ssh program, never a function, and its exit status kept
  # (bash 3.2 exits the shell under set -e when a program run by `builtin command` fails).
  builtin printf '%s\n' "$val" | (builtin exec "${ssh_cmd[@]}") || rc=$?
  val=""
  unset -v val
  exit "$rc"
else
  echo "app_switch: $host $app $shown" >&2
  exec "${ssh_cmd[@]}" </dev/null
fi
