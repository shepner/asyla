#!/bin/bash
# Gitea Actions runner on d01-d03 (and any host whose spec gives it labels, such as the test01 build test host): native gitea-runner, systemd; jobs run on the host as `docker`, or in containers (docker mode).
# Usage: gitea-runner.sh [switch ...]   Switches combine (e.g. install register up).
# Shared by every host: ~/scripts/<host>/apps/gitea-runner/gitea-runner.sh is a symlink here.
#
#   install   Install or update (idempotent): nodejs if missing (host mode), the pinned binary
#             (sha256 checked), /var/lib/gitea-runner/config.yaml with this host's labels, the unit.
#   register  Register instance-wide. Reads the token from stdin (one line); never prints or
#             stores it. Does nothing if already registered.
#   config    Print the config.yaml install would write (read-only; for tests and review).
#   up | down | restart | refresh | update | backup | status | logs
#
# Labels: d01-d03 keep RUNNER_LABELS below (hub ADR-010, ADR-011), host mode. Any other host reads
# [runner] from its own host.toml: labels, and mode = "host" (default) or "docker". Docker mode
# (ci01, asyla #1237) registers each label as NAME:docker://IMAGE (image = "..."), sets capacity
# (1-99, default 10) and container.options (container_options = "DOCKER RUN FLAGS"); the rules are
# build_host.py's check_runner_spec. Changing labels needs only install + restart: the daemon
# takes labels from config.yaml, not from .runner.

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

RUNNER_MODE=host
RUNNER_IMAGE=""
RUNNER_CAPACITY=""      # empty: config.yaml's capacity: 10
RUNNER_OPTIONS=""
case "$RUNNER_NAME" in
  d01|d02|d03) RUNNER_LABELS=(asyla "$RUNNER_NAME" docker) ;;
  # Any other host takes the labels its own spec gives it: [runner] labels in
  # ~/scripts/<host>/host.toml. The build test host test01 holds one label no workflow uses
  # (build-test), so it never takes a real job (asyla decisions/host-layout.md). A host with no
  # labels in its spec gets no runner.
  *)
    RUNNER_SPEC="$SCRIPT_DIR/../../$RUNNER_NAME/host.toml"
    RUNNER_LABELS=()
    # One "KEY VALUE" line each: mode, then image, capacity and options (docker mode), then labels.
    # IMAGE and OPTS are build_host.py's RUNNER_IMAGE and RUNNER_OPTS (test_gitea_runner_labels.sh
    # checks they stay equal); KEYS is its RUNNER_KEYS.
    if spec_lines=$(python3 -c '
import re, sys, tomllib
KEYS = ("enabled", "labels", "mode", "image", "capacity", "container_options")
DOCKER_KEYS = ("image", "capacity", "container_options")
IMAGE = r"[a-z0-9][a-z0-9._/-]*(:[0-9]+/[a-z0-9._/-]+)?(:[A-Za-z0-9_][A-Za-z0-9_.-]*)?(@sha256:[0-9a-f]{64})?"
OPTS = r"-[A-Za-z0-9=,._:/@+ -]*"
try:
    r = tomllib.load(open(sys.argv[1], "rb")).get("runner", {})
except (OSError, ValueError) as e:
    sys.exit(f"{sys.argv[1]}: {e}")
if not isinstance(r, dict):
    sys.exit("[runner] is not a table")
unknown = set(r) - set(KEYS)
if unknown:
    sys.exit(f"[runner]: unknown keys {sorted(unknown)}")
labels = r.get("labels", [])
if not labels or not isinstance(labels, list) or not all(isinstance(l, str) and re.fullmatch("[a-z0-9][a-z0-9-]*", l) for l in labels):
    sys.exit("[runner] labels must be a non-empty list of names [a-z0-9][a-z0-9-]*")
mode = r.get("mode", "host")
if mode not in ("host", "docker"):
    sys.exit(f"[runner] mode must be host or docker, not {mode!r}")
out = [f"mode {mode}"]
if mode == "host":
    extra = [k for k in DOCKER_KEYS if k in r]
    if extra:
        sys.exit(f"[runner]: {extra} are for mode = \"docker\" only")
else:
    image = r.get("image")
    if not (isinstance(image, str) and re.fullmatch(IMAGE, image)):
        sys.exit(f"[runner] mode = \"docker\" needs image = \"REGISTRY/NAME[:TAG][@sha256:DIGEST]\", not {image!r}")
    out.append(f"image {image}")
    if "capacity" in r:
        cap = r["capacity"]
        if not isinstance(cap, int) or isinstance(cap, bool) or not 1 <= cap <= 99:
            sys.exit(f"[runner] capacity must be a whole number 1-99, not {cap!r}")
        out.append(f"capacity {cap}")
    opts = r.get("container_options", "")
    if not isinstance(opts, str) or (opts and not re.fullmatch(OPTS, opts)):
        sys.exit(f"[runner] container_options must be docker run flags ({OPTS}), not {opts!r}")
    if opts:
        out.append(f"options {opts}")
out += [f"label {l}" for l in labels]
print("\n".join(out))' "$RUNNER_SPEC" 2>&1); then
      while IFS= read -r line; do
        case "$line" in
          "mode "*)     RUNNER_MODE="${line#mode }" ;;
          "image "*)    RUNNER_IMAGE="${line#image }" ;;
          "capacity "*) RUNNER_CAPACITY="${line#capacity }" ;;
          "options "*)  RUNNER_OPTIONS="${line#options }" ;;
          "label "*)    RUNNER_LABELS+=("${line#label }") ;;
        esac
      done <<<"$spec_lines"
    else
      echo "[ERROR] $spec_lines" >&2
    fi
    if [ "${#RUNNER_LABELS[@]}" -eq 0 ]; then
      echo "[ERROR] no usable [runner] labels or mode for $RUNNER_NAME in $RUNNER_SPEC" >&2
      exit 1
    fi
    ;;
esac

# The label's execution part: host, or docker://IMAGE (each job in a container of that image).
if [ "$RUNNER_MODE" = docker ]; then RUNNER_KIND="docker://$RUNNER_IMAGE"; else RUNNER_KIND=host; fi

labels_csv() {
  local IFS=,
  echo "${RUNNER_LABELS[*]/%/:$RUNNER_KIND}"
}

is_registered() {
  [ -s "$DATA_DIR/.runner" ]
}

render_config() {
  local src="$SCRIPT_DIR/config.yaml"
  if [ -n "$RUNNER_CAPACITY" ]; then
    # Docker mode with a capacity: the spec's value in place of config.yaml's.
    if ! grep -q '^  capacity: 10$' "$src"; then
      echo "[ERROR] $src has no '  capacity: 10' line to set capacity $RUNNER_CAPACITY in" >&2
      return 1
    fi
    sed "s/^  capacity: 10\$/  capacity: $RUNNER_CAPACITY/" "$src"
  else
    cat "$src"
  fi
  echo "  # Rendered by gitea-runner.sh for $RUNNER_NAME."
  echo "  labels:"
  local l
  for l in "${RUNNER_LABELS[@]}"; do echo "    - \"$l:$RUNNER_KIND\""; done
  if [ "$RUNNER_MODE" = docker ]; then
    echo
    echo "container:"
    echo "  # Docker mode ([runner] in $RUNNER_NAME/host.toml). docker_host stays at its default (empty):"
    echo "  # the runner finds the daemon and mounts its socket into job containers, as on the Mini."
    echo "  # Keys: https://gitea.com/gitea/runner/raw/tag/v4.1.0/internal/pkg/config/config.example.yaml"
    if [ -n "$RUNNER_OPTIONS" ]; then echo "  options: \"$RUNNER_OPTIONS\""; fi
  fi
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
  # Docker mode: actions run in the job container, with that image's node.
  if [ "$RUNNER_MODE" = host ] && ! command -v node >/dev/null 2>&1; then
    # JavaScript actions (actions/checkout) run with the host's node in host mode.
    echo "[INFO] Installing nodejs (Debian package)"
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends nodejs
  fi
  install_binary
  sudo install -d -o "$RUN_AS" -m 0700 "$DATA_DIR"
  local cfg
  cfg=$(mktemp)
  # set -e does not apply here (run_cmd is called in an if), so a failed render is caught by hand.
  render_config > "$cfg" || { rm -f "$cfg"; return 1; }
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
  echo "mode:       $RUNNER_MODE"
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
    config)   render_config ;;
    *)        return 1 ;;
  esac
}

if [ $# -eq 0 ]; then
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2
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
