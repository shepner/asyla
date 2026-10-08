#!/bin/bash
# Gitea Actions runner on d01-d03 (and the d04 build test host): native gitea-runner, systemd, jobs run on the host as `docker`.
# Usage: gitea-runner.sh [switch ...]   Switches combine (e.g. install register up).
# Shared by every d0N host: ~/scripts/<host>/apps/gitea-runner/gitea-runner.sh is a symlink here.
#
#   install   Install or update (idempotent): nodejs if missing, the pinned binary (sha256 checked),
#             /var/lib/gitea-runner/config.yaml with this host's labels, the systemd unit.
#   register  Register instance-wide. Reads the token from stdin (one line); never prints or
#             stores it. Does nothing if already registered.
#   up | down | restart | refresh | update | backup | status | logs
#
# Labels: RUNNER_LABELS below (hub ADR-010, ADR-011), all host mode. Changing them needs only
# install + restart: the daemon takes labels from config.yaml, not from .runner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

GITEA_INSTANCE_URL="https://gitea.asyla.org"
RUNNER_VERSION="4.1.0"
# checksums.txt of https://gitea.com/gitea/runner/releases/tag/v4.1.0
RUNNER_SHA256="b781d26b0f82269e73f6fae813a84c8ba5a215ea65cd7949c2fb3db5e0ccc8cf"
RUNNER_URL="https://gitea.com/gitea/runner/releases/download/v$RUNNER_VERSION/gitea-runner-$RUNNER_VERSION-linux-amd64"
BIN="/usr/local/bin/gitea-runner"
DATA_DIR="/var/lib/gitea-runner"
UNIT="gitea-runner.service"
RUN_AS="docker"
RUNNER_NAME="$(hostname -s)"

case "$RUNNER_NAME" in
  d01|d02|d03) RUNNER_LABELS=(asyla "$RUNNER_NAME" docker) ;;
  # The build test host: one label no workflow uses, so it never takes a real job
  # (asyla decisions/host-build-and-recovery.md). Not "d04": old workflows still say runs-on: d04.
  d04) RUNNER_LABELS=(build-test) ;;
  *) echo "[ERROR] gitea-runner is for d01-d04 only, not $RUNNER_NAME" >&2; exit 1 ;;
esac

labels_csv() {
  local IFS=,
  echo "${RUNNER_LABELS[*]/%/:host}"
}

is_registered() {
  [ -s "$DATA_DIR/.runner" ]
}

render_config() {
  cat "$SCRIPT_DIR/config.yaml"
  echo "  # Rendered by gitea-runner.sh for $RUNNER_NAME."
  echo "  labels:"
  local l
  for l in "${RUNNER_LABELS[@]}"; do echo "    - \"$l:host\""; done
}

install_binary() {
  if [ -x "$BIN" ] && "$BIN" --version 2>/dev/null | grep -q "v$RUNNER_VERSION\$"; then
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  echo "[INFO] Downloading gitea-runner $RUNNER_VERSION"
  curl -fsSL -o "$tmp" "$RUNNER_URL"
  if ! echo "$RUNNER_SHA256  $tmp" | sha256sum -c --quiet -; then
    rm -f "$tmp"
    echo "[ERROR] gitea-runner $RUNNER_VERSION checksum mismatch; not installed" >&2
    return 1
  fi
  sudo install -m 0755 "$tmp" "$BIN"
  rm -f "$tmp"
  echo "[INFO] Installed $("$BIN" --version)"
}

do_install() {
  if ! command -v node >/dev/null 2>&1; then
    # JavaScript actions (actions/checkout) run with the host's node in host mode.
    echo "[INFO] Installing nodejs (Debian package)"
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends nodejs
  fi
  install_binary
  sudo install -d -o "$RUN_AS" -m 0700 "$DATA_DIR"
  local cfg
  cfg=$(mktemp)
  render_config > "$cfg"
  if ! cmp -s "$cfg" "$DATA_DIR/config.yaml"; then
    install -m 0644 "$cfg" "$DATA_DIR/config.yaml"
    echo "[INFO] Installed $DATA_DIR/config.yaml (labels $(labels_csv))"
  fi
  rm -f "$cfg"
  if ! cmp -s "$SCRIPT_DIR/$UNIT" "/etc/systemd/system/$UNIT"; then
    sudo install -m 0644 "$SCRIPT_DIR/$UNIT" "/etc/systemd/system/$UNIT"
    sudo systemctl daemon-reload
    echo "[INFO] Installed /etc/systemd/system/$UNIT"
  fi
}

do_register() {
  if is_registered; then
    echo "[INFO] $RUNNER_NAME is already registered ($DATA_DIR/.runner); nothing to do"
    return 0
  fi
  [ -x "$BIN" ] && [ -f "$DATA_DIR/config.yaml" ] || { echo "[ERROR] run install first" >&2; return 1; }
  local token=""
  if [ -t 0 ]; then
    read -rsp "Gitea runner registration token: " token; echo
  else
    IFS= read -r token || true
  fi
  if [ -z "$token" ]; then
    echo "[ERROR] No registration token on stdin" >&2
    return 1
  fi
  echo "[INFO] Registering $RUNNER_NAME at $GITEA_INSTANCE_URL with labels $(labels_csv)"
  # The token reaches gitea-runner as an environment variable of this one process: not in argv,
  # not on disk.
  (cd "$DATA_DIR" && GITEA_RUNNER_REGISTRATION_TOKEN="$token" "$BIN" --config "$DATA_DIR/config.yaml" \
    register --no-interactive --instance "$GITEA_INSTANCE_URL" --name "$RUNNER_NAME" --labels "$(labels_csv)")
  token=""
  if ! is_registered; then
    echo "[ERROR] Registration did not write $DATA_DIR/.runner" >&2
    return 1
  fi
  chmod 600 "$DATA_DIR/.runner"
  echo "[INFO] Registered $RUNNER_NAME"
}

do_up() {
  if ! is_registered; then
    echo "[ERROR] $RUNNER_NAME is not registered; run: $0 register (token on stdin)" >&2
    return 1
  fi
  sudo systemctl enable --now "$UNIT"
}

do_status() {
  echo "host:       $RUNNER_NAME"
  echo "binary:     $("$BIN" --version 2>/dev/null || echo absent)"
  echo "node:       $(node --version 2>/dev/null || echo absent)"
  echo "registered: $(is_registered && echo yes || echo no)"
  echo "labels:     $(labels_csv)"
  echo "service:    $(systemctl is-active "$UNIT" 2>/dev/null || true) ($(systemctl is-enabled "$UNIT" 2>/dev/null || echo not-installed))"
}

run_cmd() {
  case "$1" in
    install)  do_install ;;
    register) do_register ;;
    up)       do_up ;;
    down)     sudo systemctl disable --now "$UNIT" ;;
    restart)  sudo systemctl restart "$UNIT" ;;
    update)   do_install ;;
    refresh)  do_install && sudo systemctl try-restart "$UNIT" ;;
    backup)
      # Nothing worth keeping: everything but .runner comes from the repo, and a lost .runner is
      # replaced by registering again (then delete the stale runner in Gitea).
      echo "[INFO] gitea-runner has no data to back up"
      ;;
    status)   do_status ;;
    *)        return 1 ;;
  esac
}

if [ $# -eq 0 ]; then
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  exec journalctl -u "$UNIT" -f
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "[ERROR] '$cmd' failed or is unknown" >&2
    exit 1
  fi
done
