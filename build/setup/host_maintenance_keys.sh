#!/bin/bash
# host-maintenance's SSH key set on a host that carries its runner (gap G11), from the host's
# spec ([host_maintenance] in HOST/host.toml). Run as root by the build (build_host.py, setup
# phase, after the secrets phase has installed the private key as a [[secret]]); never kept on
# the host. The key set is what /home/docker/.config/host-maintenance/ssh held on d03
# (asyla/host-maintenance setup/setup-runner-d03.sh), mounted into the jobs as /maint-ssh:ro:
#   IDENTITY            the private key ([[secret]]; this script only sets its owner and 0600)
#   IDENTITY.pub        from `ssh-keygen -y`, comment kept (0644)
#   known_hosts         the spec's pinned host keys, in spec order (0644); then each pinned
#                       address is scanned from here (ssh-keyscan -t ed25519) and the step fails
#                       when a host does not answer or offers another key: the pins decide what
#                       is trusted, the scan only checks them
#   the key directory   0700; owner of all four: the [[secret]]'s owner (default docker:docker)
# and USER's ~/.ssh/authorized_keys gets the .pub line once, marked MARK at its end: lines with
# the marker or the same key are replaced, every other line is kept. Idempotent.
#
# Never prints the private key; prints the public key's fingerprint.
#
# HOST_SPEC: this host's host.toml, which the build sends with this script.
# HOST_MAINTENANCE_HOME: USER's home directory, for the offline test only
# (scripts/tests/test_build_host_maintenance_keys.py); it also lifts the root check.
set -euo pipefail

MARK="asyla-build:host-maintenance"
log() { echo "[INFO] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

SPEC="${HOST_SPEC:?HOST_SPEC must name the host.toml of this host}"
[ -f "$SPEC" ] || die "HOST_SPEC $SPEC is not a file"
TEST_HOME="${HOST_MAINTENANCE_HOME:-}"
[ "$EUID" -eq 0 ] || [ -n "$TEST_HOME" ] || die "run as root"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The table, as build_host.py's load_spec() has checked it: line 1 the identity, 2 the user,
# 3 the owner (of the identity's [[secret]]); the pinned lines go to $WORK/pinned.
python3 - "$SPEC" "$WORK/pinned" > "$WORK/table" <<'PY'
import re, sys, tomllib
spec = tomllib.load(open(sys.argv[1], "rb"))
hm = spec.get("host_maintenance")
if not isinstance(hm, dict):
    sys.exit("no [host_maintenance] table in the spec")
ident, user, pins = hm.get("identity", ""), hm.get("user", ""), hm.get("known_hosts", [])
owner = next((s.get("owner", "docker:docker") for s in spec.get("secret", []) if s.get("path") == ident), None)
line = re.compile(r"[A-Za-z0-9.:-]+ ssh-ed25519 [A-Za-z0-9+/]+={0,2}")
if not re.fullmatch(r"/[A-Za-z0-9_./-]+", ident) or owner is None:
    sys.exit("[host_maintenance].identity must be the path of a [[secret]]")
if not re.fullmatch(r"[a-z_][a-z0-9_-]*", user) or not re.fullmatch(r"[a-z_][a-z0-9_-]*:[a-z_][a-z0-9_-]*", owner):
    sys.exit("[host_maintenance].user, or the secret's owner, is not a plain name")
if not pins or not all(isinstance(p, str) and line.fullmatch(p) for p in pins):
    sys.exit("[host_maintenance].known_hosts must list ADDRESS ssh-ed25519 KEY lines")
open(sys.argv[2], "w").write("".join(p + "\n" for p in pins))
print(ident, user, owner, sep="\n")
PY
{ read -r IDENTITY; read -r USER_NAME; read -r OWNER; } < "$WORK/table"
DIR=$(dirname "$IDENTITY")
O_USER=${OWNER%%:*}
O_GROUP=${OWNER#*:}

[ -f "$IDENTITY" ] || die "$IDENTITY is missing: the secrets phase installs it from its [[secret]]"
if [ -n "$TEST_HOME" ]; then
    HOME_DIR="$TEST_HOME"
else
    HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
fi
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || die "no home directory for user $USER_NAME"
U_GROUP=$(id -gn "$USER_NAME")

# The key directory 0700, and its parents inside the owner's home owned by the owner (the
# secrets phase's `install -d` makes missing parents as root).
install -d -m 700 -o "$O_USER" -g "$O_GROUP" "$DIR"
chown "$O_USER:$O_GROUP" "$DIR"
chmod 700 "$DIR"
p="$DIR"
while p=$(dirname "$p"); [ "$p" != "/" ] && [ "${p#"$HOME_DIR"/}" != "$p" ]; do
    chown "$O_USER:$O_GROUP" "$p"
done
chown "$O_USER:$O_GROUP" "$IDENTITY"
chmod 600 "$IDENTITY"

# The public key, from the private one (the comment comes with it).
ssh-keygen -y -f "$IDENTITY" > "$WORK/pub" || die "ssh-keygen -y could not read $IDENTITY"
read -r KTYPE BLOB _ < "$WORK/pub"
[ -n "$BLOB" ] || die "ssh-keygen -y gave no public key for $IDENTITY"
install -m 644 -o "$O_USER" -g "$O_GROUP" "$WORK/pub" "$IDENTITY.pub"
log "$IDENTITY.pub: $(ssh-keygen -l -f "$IDENTITY.pub")"

# The pinned host keys.
install -m 644 -o "$O_USER" -g "$O_GROUP" "$WORK/pinned" "$DIR/known_hosts"
log "$DIR/known_hosts: $(wc -l < "$DIR/known_hosts" | tr -d ' ') pinned host key(s)"

# USER's authorized_keys: one marked line for this key; every other line kept.
SSH_DIR="$HOME_DIR/.ssh"
AUTH="$SSH_DIR/authorized_keys"
install -d -m 700 -o "$USER_NAME" -g "$U_GROUP" "$SSH_DIR"
touch "$AUTH"
{ grep -vF -e " $MARK" -e " $BLOB" "$AUTH" || true; } > "$WORK/auth"
printf '%s %s\n' "$(cat "$WORK/pub")" "$MARK" >> "$WORK/auth"
install -m 600 -o "$USER_NAME" -g "$U_GROUP" "$WORK/auth" "$AUTH"
log "$AUTH: the key's line, marked $MARK ($(grep -cF " $BLOB" "$AUTH") line)"

# Check the pins against what each address offers now. A host that does not answer fails too:
# an unchecked pin is not a checked one.
bad=0
while read -r addr ktype key; do
    got=$({ ssh-keyscan -T 5 -t ed25519 "$addr" 2>/dev/null || true; } \
          | awk -v a="$addr" '$1 == a && $2 == "ssh-ed25519" { print $3 }' | sort -u)
    if [ -z "$got" ]; then
        echo "[ERROR] $addr: no ed25519 host key (no answer); its pin is unchecked" >&2
        bad=1
    elif [ "$got" != "$key" ]; then
        echo "[ERROR] $addr offers another host key (...${got: -8}) than its pin (...${key: -8})" >&2
        bad=1
    else
        log "$addr: host key matches its pin (...${key: -8})"
    fi
done < "$DIR/known_hosts"
[ "$bad" -eq 0 ] || die "a pinned host key does not match what its host offers; nothing trusts the scan"
log "host-maintenance key set ready in $DIR"
