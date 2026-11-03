#!/usr/bin/env bash
# Vendored unchanged by asyla from theOrg observability scripts/write_ping_url.sh at 2144f83c3ec978663d3cb544e743ae8006471a0a
# (only these two comment lines added). Update by re-vendoring at the new OBSERVABILITY_TAG.
# Write a healthchecks.io ping URL, read from stdin, into the volume the service that pings mounts
# (DEPLOY.md, "Watching the watcher"). The URL reaches its file through a pipe, never an argument,
# and nothing here prints it: anyone holding it can keep the check up.
#
#   write_ping_url.sh watchdog < url      -> <project>_alertmanager-healthchecks/watchdog-url
#   write_ping_url.sh delivery < url      -> <project>_alert-relay-healthchecks/delivery-url
#   write_ping_url.sh watchdog|delivery --remove   removes that file, which switches the ping off
#
# The file is owned by uid 65534 (Alertmanager's user; alert-relay runs as root), mode 0600. Empty
# stdin is an error, so a URL lost on its way here never switches a ping off. Either way, restart
# the service after: Alertmanager renders its configuration at start, and alert-relay reads the
# file at start.
#
# Env: COMPOSE_PROJECT_NAME (default observability), the project the stack runs under.
# Exit: 0 written or removed; 1 stdin is empty or not a URL; 2 usage.
set -euo pipefail

usage() { echo "usage: $0 watchdog|delivery [--remove] < url" >&2; exit 2; }
case "${1:-}" in
  watchdog) vol=alertmanager-healthchecks file=watchdog-url ;;
  delivery) vol=alert-relay-healthchecks file=delivery-url ;;
  *) usage ;;
esac
case "${2:-}" in
  "") remove=false ;;
  --remove) remove=true ;;
  *) usage ;;
esac
[ $# -le 2 ] || usage
VOL="${COMPOSE_PROJECT_NAME:-observability}_${vol}"

if $remove; then
  docker run --rm --cpus 1 -v "${VOL}:/out" alpine rm -f "/out/${file}"
  echo "Removed ${file} from ${VOL}: that ping is off once the service restarts"
  exit 0
fi
url=$(head -n 1 | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
if [ -z "$url" ]; then
  echo "error: nothing on stdin; use --remove to switch the ping off" >&2
  exit 1
fi
# The same shape alert-relay accepts: http(s), a host, a path.
if ! grep -Eq '^https?://[^/[:space:]]+/[^[:space:]]*$' <<<"$url"; then
  echo "error: stdin is not an http(s) ping URL; ${VOL} is unchanged" >&2
  exit 1
fi
# Written next to the target and renamed over it, so a reader never sees half a URL.
printf '%s\n' "$url" | docker run --rm -i --cpus 1 -v "${VOL}:/out" alpine sh -c \
  "umask 077; cat > /out/${file}.new && chown 65534:65534 /out/${file}.new && mv /out/${file}.new /out/${file}"
echo "Wrote ${file} into ${VOL}; restart the service that mounts it"
