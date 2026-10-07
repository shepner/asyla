#!/bin/bash
# Gitea Actions runner on d01-d03 (docker.io/gitea/runner). Usage: gitea-runner.sh [switch ...]
# Switches can be combined (e.g. register up). Shared by every d0N host: each host's
# ~/scripts/<host>/apps/gitea-runner/gitea-runner.sh is a symlink to this file.
#
#   register  Register this host as an instance-wide runner. Reads the registration token from
#             stdin (one line); never prints or stores it. Does nothing if already registered.
#   up        Install config.yaml into the data dir and start the runner (must be registered).
#   down | restart | refresh | update | backup | status | logs
#
# Labels (hub ADR-010, ADR-011): site `asyla`, host `<hostname -s>`, capability `docker`. All three
# run jobs in JOB_IMAGE, so whichever label matches first, a job gets the same image.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

if [ -f "$HOME/scripts/docker/common.env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/scripts/docker/common.env"
fi
DOCKER_DL="${DOCKER_DL:-/mnt/docker}"
LOCAL_TZ="${LOCAL_TZ:-America/Chicago}"

GITEA_INSTANCE_URL="https://gitea.asyla.org"
RUNNER_IMAGE="docker.io/gitea/runner:4.1.0"
# node for JavaScript actions (actions/checkout), git, and python3 3.11 (the structure CI needs >= 3.11).
JOB_IMAGE="node:24-bookworm"
RUNNER_NAME="$(hostname -s)"
SITE_LABEL="asyla"
RUNNER_LABELS="$SITE_LABEL:docker://$JOB_IMAGE,$RUNNER_NAME:docker://$JOB_IMAGE,docker:docker://$JOB_IMAGE"
DATA_DIR="$DOCKER_DL/GiteaRunner/data"

export RUNNER_IMAGE RUNNER_LABELS DATA_DIR LOCAL_TZ

case "$RUNNER_NAME" in
  d01|d02|d03) ;;
  *) echo "[ERROR] gitea-runner is for d01-d03 only, not $RUNNER_NAME" >&2; exit 1 ;;
esac

run_compose() {
  docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" "$@"
}

is_registered() {
  [ -s "$DATA_DIR/.runner" ]
}

prepare_data() {
  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  if ! cmp -s "$SCRIPT_DIR/config.yaml" "$DATA_DIR/config.yaml"; then
    install -m 0644 "$SCRIPT_DIR/config.yaml" "$DATA_DIR/config.yaml"
    echo "[INFO] Installed config.yaml into $DATA_DIR"
  fi
}

do_register() {
  if is_registered; then
    echo "[INFO] $RUNNER_NAME is already registered ($DATA_DIR/.runner); nothing to do"
    return 0
  fi
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
  prepare_data
  echo "[INFO] Registering $RUNNER_NAME at $GITEA_INSTANCE_URL with labels $RUNNER_LABELS"
  # The token goes in on stdin and reaches gitea-runner as an environment variable: not in argv,
  # not in the container's config, not on disk.
  printf '%s\n' "$token" | docker run --rm -i -v "$DATA_DIR:/data" -w /data --entrypoint bash "$RUNNER_IMAGE" -c '
    IFS= read -r GITEA_RUNNER_REGISTRATION_TOKEN; export GITEA_RUNNER_REGISTRATION_TOKEN
    gitea-runner --config /data/config.yaml register --no-interactive \
      --instance "$1" --name "$2" --labels "$3"; rc=$?
    [ -f /data/.runner ] && chmod 600 /data/.runner
    exit $rc' _ "$GITEA_INSTANCE_URL" "$RUNNER_NAME" "$RUNNER_LABELS"
  token=""
  if ! is_registered; then
    echo "[ERROR] Registration did not write $DATA_DIR/.runner" >&2
    return 1
  fi
  echo "[INFO] Registered $RUNNER_NAME"
}

do_up() {
  if ! is_registered; then
    echo "[ERROR] $RUNNER_NAME is not registered; run: $0 register (token on stdin)" >&2
    return 1
  fi
  prepare_data
  run_compose up -d
}

do_update() {
  echo "[INFO] Pulling the runner and job images (not restarting; use refresh or restart)"
  run_compose pull
  docker pull -q "$JOB_IMAGE"
}

do_status() {
  echo "host:       $RUNNER_NAME"
  echo "registered: $(is_registered && echo yes || echo no)"
  echo "labels:     $RUNNER_LABELS"
  echo "container:  $(docker inspect -f '{{.State.Status}} since {{.State.StartedAt}} ({{.Config.Image}})' gitea-runner 2>/dev/null || echo absent)"
}

run_cmd() {
  case "$1" in
    register) do_register ;;
    up)       do_up ;;
    down)     run_compose down ;;
    restart)  run_compose down; do_up ;;
    refresh)  do_update; do_up ;;
    update)   do_update ;;
    backup)
      # Nothing worth keeping: config.yaml is in the repo, and a lost .runner is replaced by
      # registering again (then delete the stale runner in Gitea).
      echo "[INFO] gitea-runner has no data to back up"
      ;;
    status)   do_status ;;
    *)        return 1 ;;
  esac
}

if [ $# -eq 0 ]; then
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
fi

if [ "$1" = "logs" ]; then
  run_compose logs -f "${@:2}"
  exit 0
fi

for cmd in "$@"; do
  if ! run_cmd "$cmd"; then
    echo "[ERROR] '$cmd' failed or is unknown" >&2
    exit 1
  fi
done
