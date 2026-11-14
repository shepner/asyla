#!/bin/bash
# app_switch.sh HOST APP SWITCH [VAR...]: the operator's one-off app command. Runs
# ~/scripts/HOST/apps/APP/APP.sh SWITCH on HOST over one ssh, as build_host.py's env_command does
# for a start: each VAR's value is read from this process's environment (the credentials
# capability puts it there) and sent over ssh stdin, one line each; on the host
# `IFS= read -r VAR` reads it and it is exported for that one command alone. A value is never in an
# argv, the output or a file, and ssh's own environment does not carry it (unset here first).
#
# Allowlist: HOST/host.toml's [[app]] APP has `switch_env`, a table of SWITCH -> the VARs it takes,
# e.g. d05's identity-platform: { "leaf-issue" = ["LDAP_PROVISIONER_PASSWORD"], "leaf-renew" = [] }.
# A switch not in it is refused; the VARs given must be exactly that switch's list. A VAR that is
# unset, empty or holds a newline is refused (one line each on stdin). A replica's spec is refused
# (its apps are another host's tree; build_host.py runs those).
#
# ssh as build_host.py's ssh_argv without its override: ssh -o BatchMode=yes -o ConnectTimeout=10
# -i ~/.ssh/docker_rsa docker@HOST; the remote command is env_command's, byte for byte (no VAR: the
# script and switch alone; else bash -c 'IFS= read -r A && ... && export A ... && SCRIPT SWITCH').
# The override (BUILD_HOST_SSH_KEY, BUILD_HOST_SSH_KNOWN_HOSTS, BUILD_HOST_SSH_BY_ADDRESS) is not
# implemented here, so it is refused rather than ignored. A shell variable of bash's own (PATH, HOME,
# IFS, BASH*, ...) is refused as a VAR: it is unset here before anything runs.
# Exit: the remote command's, or 2 for a refusal here.
#
# From ~/local/asyla, e.g.:
#   python3 core/tools/credentials.py exec LDAP_PROVISIONER_PASSWORD -- \
#     projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD
set -euo pipefail

SSH_KEY="${HOME}/.ssh/docker_rsa"
GUEST_USER="docker"

refuse() { echo "app_switch: $*" >&2; exit 2; }

[ $# -ge 3 ] || refuse "usage: app_switch.sh HOST APP SWITCH [VAR...]"
host="$1" app="$2" switch="$3"
shift 3
name_re='^[a-z][a-z0-9-]*$'
var_re='^[A-Z_][A-Z0-9_]*$'
reserved_re='^(PATH|HOME|IFS|PWD|OLDPWD|SHELL|USER|LOGNAME|TERM|TMPDIR|LANG|LC_[A-Z_]*|UID|EUID|PPID|SHELLOPTS|BASH[A-Z0-9_]*|SSH_[A-Z0-9_]*|BUILD_HOST_[A-Z0-9_]*)$'
for o in BUILD_HOST_SSH_KEY BUILD_HOST_SSH_KNOWN_HOSTS BUILD_HOST_SSH_BY_ADDRESS; do
  [ -z "${!o+x}" ] || refuse "$o is set; this tool has no ssh override (build_host.py's), unset it"
done
[[ "$host" =~ $name_re ]] || refuse "HOST must match $name_re"
[[ "$app" =~ $name_re ]] || refuse "APP must match $name_re"
[[ "$switch" =~ $name_re ]] || refuse "SWITCH must match $name_re"
# Each VAR's value into this shell alone, then out of the environment, before any child runs
# (dirname, python3, ssh): no other process carries it.
vars=() vals=()
for v in "$@"; do
  [[ "$v" =~ $var_re ]] || refuse "VAR $v must match $var_re"
  [[ ! "$v" =~ $reserved_re ]] || refuse "VAR $v is a shell or ssh variable; not sent"
  for w in ${vars[@]+"${vars[@]}"}; do
    [ "$w" != "$v" ] || refuse "VAR $v named twice"
  done
  [ -n "${!v:-}" ] || refuse "$v is unset or empty in this environment"
  case "${!v}" in *$'\n'*|*$'\r'*) refuse "$v holds a newline; one line each on stdin" ;; esac
  vars+=("$v")
  vals+=("${!v}")
  unset "$v"
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spec="$REPO/$host/host.toml"
[ -f "$spec" ] || refuse "$host has no host.toml in this repo"

# The switch's VARs from the spec, one per line (none: an empty line-less output).
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
if not isinstance(names, list) or len(set(names)) != len(names) \
        or not all(isinstance(n, str) and re.fullmatch(r"[A-Z_][A-Z0-9_]*", n) for n in names):
    no(f"{path}: [[app]] {app!r} switch_env {switch!r} must be a list of distinct variable names")
print("\n".join(names))
PY
)" || refuse "refused (above)"

want=()
while IFS= read -r v; do
  [ -n "$v" ] && want+=("$v")
done <<< "$allowed"

for v in ${vars[@]+"${vars[@]}"}; do
  ok=false
  for w in ${want[@]+"${want[@]}"}; do
    [ "$w" != "$v" ] || ok=true
  done
  $ok || refuse "$switch takes ${want[*]:-no VAR}; $v is not listed in $host's switch_env"
done
[ "${#vars[@]}" -eq "${#want[@]}" ] || refuse "$switch needs exactly: ${want[*]:-no VAR}"

cmd="~/scripts/$host/apps/$app/$app.sh $switch"
if [ "${#vars[@]}" -gt 0 ]; then
  reads=""
  for v in "${vars[@]}"; do reads="${reads}IFS= read -r $v && "; done
  inner="${reads}export ${vars[*]} && $cmd"
  cmd="bash -c '$inner'"
  echo "app_switch: $host $app $switch (over ssh stdin: ${vars[*]})" >&2
else
  echo "app_switch: $host $app $switch" >&2
fi

ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$SSH_KEY" "$GUEST_USER@$host" "$cmd")
if [ "${#vals[@]}" -gt 0 ]; then
  printf '%s\n' "${vals[@]}" | "${ssh_cmd[@]}"
else
  "${ssh_cmd[@]}" </dev/null
fi
