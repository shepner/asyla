#!/bin/bash
# GitLab runners of a Docker host, from its spec ([gitlab_runner] in HOST/host.toml), for
# scripts/build_host.py (the runner phase). The build sends this file from GitLab master inside the
# SSH command and runs it as root from a folder that is removed afterwards, so nothing of it stays
# on the host. What stays: the gitlab-runner package with its apt source and key (the same files
# GitLab's own install script writes, as on d03), /etc/gitlab-runner/config.toml and the
# package's systemd unit.
#
# Usage (root):
#   gitlab-runner.sh install                   GitLab's apt repository, the package, its unit started
#   gitlab-runner.sh register NAME [ARG ...]   the runner's token on stdin (one line); a local entry
#                                              named NAME is removed first; ARGs go to
#                                              `gitlab-runner register --non-interactive --name NAME`
#   gitlab-runner.sh finish NAME ...           local entries not named are removed; concurrent = the
#                                              number of names
#
# The token reaches gitlab-runner as CI_SERVER_TOKEN in its environment: never in argv, never
# printed (a failed register's output is shown with token fragments redacted).
set -euo pipefail

# GITLAB_RUNNER_CONFIG: another config file, for the offline test only
# (scripts/tests/test_build_host_gitlab_runner.py); it also lifts the root check.
CONFIG="${GITLAB_RUNNER_CONFIG:-/etc/gitlab-runner/config.toml}"
KEYRING=/etc/apt/keyrings/runner_gitlab-runner-archive-keyring.gpg
SOURCE=/etc/apt/sources.list.d/runner_gitlab-runner.list
REPO_URL=https://packages.gitlab.com/runner/gitlab-runner/debian
KEY_URL=https://packages.gitlab.com/gpgkey/gpg.key

if [ "$EUID" -ne 0 ] && [ -z "${GITLAB_RUNNER_CONFIG:-}" ]; then
    echo "gitlab-runner.sh: run as root" >&2
    exit 1
fi

# entries drop|keep NAME...: remove the [[runners]] entries named (drop), or all others (keep,
# which also sets concurrent to the number of names).
entries() {
    python3 - "$CONFIG" "$@" <<'PY'
import re, sys
path, mode, names = sys.argv[1], sys.argv[2], set(sys.argv[3:])
try:
    text = open(path).read()
except FileNotFoundError:
    sys.exit(0)
blocks = re.split(r"(?m)^(?=\[\[runners\]\])", text)
out, removed = [blocks[0]], []
for b in blocks[1:]:
    m = re.search(r'(?m)^\s*name\s*=\s*"([^"]*)"', b)
    name = m.group(1) if m else ""
    if (name in names) == (mode == "drop"):
        removed.append(name or "(no name)")
    else:
        out.append(b)
if mode == "keep":                   # finish: concurrent = the number of runners kept
    out[0] = re.sub(r"(?m)^concurrent = .*$", f"concurrent = {len(names)}", out[0])
new = "".join(out)
if new != text:
    with open(path, "w") as f:      # an existing file keeps its owner and mode (root 0600)
        f.write(new)
if removed:
    print(f"removed local runner entries: {', '.join(removed)}")
PY
}

install_runner() {
    apt-get install -y -qq ca-certificates curl gnupg >/dev/null
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "$KEY_URL" | gpg --batch --yes --dearmor -o "$KEYRING"
    chmod 0644 "$KEYRING"
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    echo "deb [signed-by=$KEYRING] $REPO_URL $codename main" > "$SOURCE"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gitlab-runner >/dev/null
    systemctl enable --now gitlab-runner >/dev/null 2>&1
    echo "gitlab-runner $(dpkg-query -W -f='${Version}' gitlab-runner) installed; unit $(systemctl is-active gitlab-runner)"
}

register_runner() {
    local name="$1" token="" out rc=0
    shift
    IFS= read -r token || true
    if [ -z "$token" ]; then
        echo "register $name: no runner token on stdin" >&2
        exit 1
    fi
    entries drop "$name"
    out=$(CI_SERVER_TOKEN="$token" gitlab-runner register --non-interactive --name "$name" "$@" 2>&1) || rc=$?
    token=""
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$out" | sed -E 's/glrt-[A-Za-z0-9_.-]+/glrt-(redacted)/g; s/(runner|token)=[^ ]+/\1=(redacted)/g' >&2
        echo "register $name: exit $rc" >&2
        exit "$rc"
    fi
    echo "registered $name"
}

finish() {
    if [ "$#" -eq 0 ]; then
        echo "finish: name the runners to keep" >&2
        exit 1
    fi
    entries keep "$@"
    if ! grep -qx "concurrent = $#" "$CONFIG"; then
        echo "finish: no concurrent line in $CONFIG" >&2
        exit 1
    fi
    echo "concurrent = $# ($*)"
}

case "${1:-}" in
    install) install_runner ;;
    register) shift; [ "$#" -ge 1 ] || { echo "register needs NAME" >&2; exit 2; }; register_runner "$@" ;;
    finish) shift; finish "$@" ;;
    *) sed -n '9,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
