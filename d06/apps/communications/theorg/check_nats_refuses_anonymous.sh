#!/usr/bin/env bash
# Prove the running broker refuses a client that presents no credential, on 4222 and on the
# WebSocket listener 8080. Exit 0 only when both refuse with NATS's authorization error.
#
# Run it after anything that changes users.conf (the deploy runs it right after the configuration
# step), and before a proxy serves 8080 to the LAN (asyla's d06 route for wss://nats.asyla.org).
# NATS re-reads users.conf on a reload as it is and never re-checks it, so this is the check of
# what the broker does now. It probes from inside the broker's own network (8080 is not published
# on the host) with an image already on the host, sends no credential, prints only verdicts, and
# changes nothing: a failure stops or recreates nothing, it only exits non-zero.
#
# Usage, from the repo root on the Docker host:
#   bash scripts/check_nats_refuses_anonymous.sh
# Env: NATS_CONTAINER (default nats-1), NATS_PROBE_IMAGE (any image with python3; default the
# stack's own communications-chat-api:latest, so nothing is pulled).
set -euo pipefail
container=${NATS_CONTAINER:-nats-1}
image=${NATS_PROBE_IMAGE:-communications-chat-api:latest}
here=$(cd "$(dirname "$0")" && pwd)

net=$(docker inspect "${container}" \
  --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' | awk '{print $1}')
if [ -z "${net}" ]; then
  echo "::error::${container} is on no network; cannot probe it" >&2
  exit 2
fi

# The probe goes in on stdin: on the deploy runner the workspace is not on the Docker host, so it
# cannot be bind-mounted.
if docker run --rm -i --cpus 1 --network "${net}" --entrypoint python3 "${image}" \
    - --anonymous "${container}" 4222 --ws-port 8080 <"${here}/nats_auth_probe.py"; then
  echo "NATS refuses anonymous clients on 4222 and 8080"
else
  rc=$?
  echo "::error::NATS took an anonymous client, or the probe got no verdict (lines above). The broker is left running as it is: re-run the configuration step (bootstrap_communications_openbao.py, DEPLOY.md), and keep wss://nats.asyla.org off until this passes." >&2
  exit "${rc}"
fi
