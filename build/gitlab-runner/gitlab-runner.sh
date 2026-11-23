#!/bin/bash
# GitLab runners of a Docker host, from its spec ([gitlab_runner] in HOST/host.toml), for
# scripts/build_host.py (the runner phase). The build sends this file from GitLab master inside the
# SSH command and runs it as root from a folder that is removed afterwards, so nothing of it stays
# on the host. What stays: the gitlab-runner package with its apt source and key (the same files
# GitLab's own install script writes, as on d03), /etc/gitlab-runner/config.toml, the
# package's systemd unit and, with [gitlab_runner] user, the drop-in DROPIN (and logout_aside's move).
#
# Usage (root):
#   gitlab-runner.sh install                   GitLab's apt repository, the package, its unit started
#   gitlab-runner.sh user NAME|-               jobs run as NAME (a unit drop-in; working directory
#                                              ~NAME/.gitlab-runner), or - for the package's
#                                              gitlab-runner (the drop-in removed); restarts on change
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
# (scripts/tests/test_build_host_gitlab_runner.py); it also lifts the root check and, for user,
# takes GITLAB_RUNNER_DROPIN_DIR and GITLAB_RUNNER_USER_HOME and runs no systemctl or chown.
CONFIG="${GITLAB_RUNNER_CONFIG:-/etc/gitlab-runner/config.toml}"
DROPIN_DIR=/etc/systemd/system/gitlab-runner.service.d
USER_HOME=""
if [ -n "${GITLAB_RUNNER_CONFIG:-}" ]; then
    DROPIN_DIR="${GITLAB_RUNNER_DROPIN_DIR:-$DROPIN_DIR}"
    USER_HOME="${GITLAB_RUNNER_USER_HOME:-}"
fi
DROPIN="$DROPIN_DIR/asyla-user.conf"
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

# user NAME|-: the drop-in that replaces the package's ExecStart (as observed on test01,
# 2026-11-22) with --working-directory ~NAME/.gitlab-runner --user NAME, or none. Reload and
# restart only when the drop-in changes.
set_user() {
    local name="$1" home new
    if [ "$name" = "-" ]; then
        if [ ! -e "$DROPIN" ]; then
            echo "jobs run as gitlab-runner (the package unit): unchanged"
            return
        fi
        rm -f "$DROPIN"
        restart_unit
        echo "jobs run as gitlab-runner (the package unit): $DROPIN removed, gitlab-runner restarted"
        return
    fi
    if ! [[ "$name" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "user: not an account name: $name" >&2
        exit 2
    fi
    home="$USER_HOME"
    if [ -z "$home" ]; then
        home=$(getent passwd "$name" | cut -d: -f6) || true
    fi
    if [ -z "$home" ] || [ "${home#/}" = "$home" ]; then
        echo "user: no account $name (or no home directory)" >&2
        exit 1
    fi
    new="# asyla-hosts build/gitlab-runner/gitlab-runner.sh user $name: jobs run as $name (asyla #605)
[Service]
ExecStart=
ExecStart=/usr/bin/gitlab-runner \"run\" \"--config\" \"/etc/gitlab-runner/config.toml\" \"--working-directory\" \"$home/.gitlab-runner\" \"--service\" \"gitlab-runner\" \"--user\" \"$name\""
    install -d -m 0700 "$home/.gitlab-runner"
    if [ -z "${GITLAB_RUNNER_CONFIG:-}" ]; then
        chown "$name:" "$home/.gitlab-runner"
    fi
    logout_aside "$name" "$home"
    if [ -f "$DROPIN" ] && [ "$(cat "$DROPIN")" = "$new" ]; then
        echo "jobs run as $name: unchanged"
        return
    fi
    install -d -m 0755 "$DROPIN_DIR"
    printf '%s\n' "$new" > "$DROPIN"
    chmod 0644 "$DROPIN"
    restart_unit
    echo "jobs run as $name: $DROPIN written, gitlab-runner restarted"
}

# logout_aside NAME HOME: a shell job runs `bash --login` under set -eo pipefail, so a
# ~NAME/.bash_logout that runs clear_console (Debian's skeleton does) exits 1 with no TTY and every
# job fails with "prepare environment: exit status 1" (test01, 2026-11-23; GitLab's "Shell profile
# loading", https://docs.gitlab.com/runner/shells/#shell-profile-loading). Move such a file to
# ~NAME/.bash_logout.asyla-gitlab-runner; a missing one, or one without clear_console, stays as it
# is. `user -` does not put it back.
logout_aside() {
    local name="$1" home="$2"
    local f="$home/.bash_logout"
    if [ -f "$f" ] && grep -q clear_console "$f"; then
        mv -f "$f" "$f.asyla-gitlab-runner"
        echo "~$name/.bash_logout runs clear_console (a job's login shell exits 1 with no TTY): moved to ~$name/.bash_logout.asyla-gitlab-runner"
    fi
}

restart_unit() {
    if [ -z "${GITLAB_RUNNER_CONFIG:-}" ]; then
        systemctl daemon-reload
        systemctl restart gitlab-runner
    fi
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
    user) shift; [ "$#" -eq 1 ] || { echo "user needs NAME or -" >&2; exit 2; }; set_user "$1" ;;
    register) shift; [ "$#" -ge 1 ] || { echo "register needs NAME" >&2; exit 2; }; register_runner "$@" ;;
    finish) shift; finish "$@" ;;
    *) sed -n '9,18p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
