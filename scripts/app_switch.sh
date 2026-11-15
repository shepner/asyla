#!/bin/bash
# app_switch.sh HOST APP SWITCH [VAR]: the operator's one-off app command. Runs
# ~/scripts/HOST/apps/APP/APP.sh SWITCH on HOST over one ssh, with ssh's stdin passed straight to
# it. With a VAR, its value is read from this process's environment (the credentials capability
# puts it there) into a shell variable, the variable is unset from the environment before any
# child runs (so neither ssh nor the remote shell inherits it), and bash's builtin printf writes the
# value, one line, to ssh's stdin; the app script reads that line itself (e.g. identity-platform.sh
# leaf-issue). Nothing is exported on the host: the remote command is the script and switch alone.
# A value is never in an argv, the output, a file or any environment past this shell's start.
# With no VAR, ssh's stdin is /dev/null.
#
# Allowlist: HOST/host.toml's [[app]] APP has `switch_env`, a table of SWITCH -> the VAR it takes
# (a list of at most one name), e.g. d05's identity-platform:
# { "leaf-issue" = ["LDAP_PROVISIONER_PASSWORD"], "leaf-renew" = [] }. A switch not in it is
# refused; the VAR given must be exactly that switch's (none when its list is empty). At most one
# VAR, on the command line and in the list. A VAR that is unset, empty or holds a newline is refused
# (one line on stdin). A replica's spec is refused (its apps are another host's tree; build_host.py
# runs those).
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

[ $# -ge 3 ] || refuse "usage: app_switch.sh HOST APP SWITCH [VAR]"
host="$1" app="$2" switch="$3"
shift 3
[ $# -le 1 ] || refuse "at most one VAR (one line on ssh stdin); got $#: $*"
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
unset -v var val
var="" val=""
if [ $# -eq 1 ]; then
  var="$1"
  [[ "$var" =~ $var_re ]] || refuse "VAR $var must match $var_re"
  [[ ! "$var" =~ $reserved_re ]] || refuse "VAR $var is a shell or ssh variable, or this script's own; not sent"
  [[ -n ${!var:-} ]] || refuse "$var is unset or empty in this environment"
  case "${!var}" in *$'\n'*|*$'\r'*) refuse "$var holds a newline; one line on stdin" ;; esac
  val="${!var}"
  unset "$var"
fi

REPO="$(cd "$(dirname "$self")/.." && pwd)"
spec="$REPO/$host/host.toml"
[ -f "$spec" ] || refuse "$host has no host.toml in this repo"

# The switch's VAR from the spec (none: an empty output).
allowed="$(python3 -I - "$spec" "$app" "$switch" <<'PY'
import re, sys, tomllib
path, app, switch = sys.argv[1:4]
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
if not isinstance(names, list) or len(names) > 1 \
        or not all(isinstance(n, str) and re.fullmatch(r"[A-Z_][A-Z0-9_]*", n) for n in names):
    no(f"{path}: [[app]] {app!r} switch_env {switch!r} must be a list of at most one variable name")
print("\n".join(names))
PY
)" || refuse "refused (above)"

if [ "$var" != "$allowed" ]; then
  if [ -n "$var" ] && [ -n "$allowed" ]; then
    refuse "$switch takes $allowed; $var is not listed in $host's switch_env"
  elif [ -n "$var" ]; then
    refuse "$switch takes no VAR; $var is not listed in $host's switch_env"
  else
    refuse "$switch needs exactly: $allowed"
  fi
fi

cmd="~/scripts/$host/apps/$app/$app.sh $switch"
ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$SSH_KEY" "$GUEST_USER@$host" "$cmd")
if [ -n "$var" ]; then
  echo "app_switch: $host $app $switch (over ssh stdin: $var)" >&2
  rc=0
  # `builtin exec` in its own subshell: the ssh program, never a function, and its exit status kept
  # (bash 3.2 exits the shell under set -e when a program run by `builtin command` fails).
  builtin printf '%s\n' "$val" | (builtin exec "${ssh_cmd[@]}") || rc=$?
  val=""
  unset -v val
  exit "$rc"
else
  echo "app_switch: $host $app $switch" >&2
  exec "${ssh_cmd[@]}" </dev/null
fi
