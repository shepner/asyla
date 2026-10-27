#!/bin/bash
# Node exporter for theOrg's trends Prometheus (asyla standard ASY-TRD; operator 2026-10-20: host
# agents including the node exporter belong in the base build). Debian's prometheus-node-exporter
# (upstream node_exporter; 1.9.0 on trixie), without its recommends (dbus and the
# prometheus-node-exporter-collectors timers), on port 9100, plus the textfile sources copy
# (node_exporter/ beside this script).
#
# From this host's host.toml (HOST_SPEC):
#   [node_exporter]
#   allow = ["10.0.0.150"]          # who may connect to 9100, besides localhost: the scraper only
#   textfile_sources = ["/mnt/docker/app/app.prom", ...]   # copied into the textfile directory
#
# Port 9100 is limited to `allow` by the unit's own IPAddressDeny=any / IPAddressAllow= (systemd
# BPF filter on the service's sockets; packets from any other address are dropped), not by a host
# firewall rule: Docker manages the host's nftables tables, and the filter needs no rule of its own.
# It is in place before the package is installed, so the service never runs open.
#
# Collectors: upstream's defaults, with three changes. The textfile directory is
# /var/lib/node_exporter/textfile_collector (theOrg's answer, 2026-10-26; the NFS check writes
# asyla_nfs.prom there). Debian's mount-point exclusion drops all of /mnt, which would hide the data
# disk (/mnt/docker); here only the NAS shares under /mnt/nas are left out (their size belongs to
# the NAS, and a statfs of a hung share waits). Container veth interfaces are left out of netdev and
# netclass: they come and go with each recreate (series churn; theOrg's answer, item 1).

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

SPEC="${HOST_SPEC:?HOST_SPEC must name the host.toml of this host}"
[ -f "$SPEC" ] || { log_error "HOST_SPEC $SPEC is not a file"; exit 1; }

PROM_DIR=/var/lib/node_exporter/textfile_collector
LIST=/etc/asyla/textfile-sources
DROPIN_DIR=/etc/systemd/system/prometheus-node-exporter.service.d
DROPIN="$DROPIN_DIR/asyla.conf"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/node_exporter"

# [node_exporter] from the spec, checked: "allow ADDRESS" and "source PATH" lines.
spec_lines=$(python3 - "$SPEC" <<'PY'
import ipaddress, os, sys, tomllib
ne = tomllib.load(open(sys.argv[1], "rb")).get("node_exporter")
if not isinstance(ne, dict):
    sys.exit(f"{sys.argv[1]}: no [node_exporter] table")
unknown = set(ne) - {"allow", "textfile_sources"}
if unknown:
    sys.exit(f"[node_exporter]: unknown keys {sorted(unknown)}")
allow = ne.get("allow")
if not isinstance(allow, list) or not allow:
    sys.exit("[node_exporter] allow must list at least one address: who may scrape port 9100")
for a in allow:
    try:
        ipaddress.ip_network(a, strict=True)
    except (TypeError, ValueError):
        sys.exit(f"[node_exporter] allow: {a!r} is not an address or prefix")
    print("allow", a)
sources = ne.get("textfile_sources", [])
if not isinstance(sources, list):
    sys.exit("[node_exporter] textfile_sources must be a list of paths")
names = set()
for s in sources:
    name = os.path.basename(s) if isinstance(s, str) else ""
    if not (isinstance(s, str) and s.startswith("/") and s.endswith(".prom") and s.isprintable() and " " not in s):
        sys.exit(f"[node_exporter] textfile_sources: {s!r} must be an absolute path ending in .prom, without spaces")
    if name in names or name in ("asyla_nfs.prom", "asyla_textfile_sources.prom"):
        sys.exit(f"[node_exporter] textfile_sources: {name} is taken (each copy is named by the source's file name)")
    names.add(name)
    print("source", s)
PY
) || { log_error "Bad [node_exporter] in $SPEC"; exit 1; }
allow=$(awk '$1 == "allow" { print $2 }' <<<"$spec_lines")
sources=$(awk '$1 == "source" { print $2 }' <<<"$spec_lines")

# The unit's settings, before the package: its postinst starts the service at once.
log_info "Writing $DROPIN (flags; port 9100 from localhost and: $(echo $allow))..."
mkdir -p "$DROPIN_DIR"
{
    echo "# Written by asyla-hosts build/setup/node_exporter.sh; replaces Debian's ExecStart, so"
    echo "# /etc/default/prometheus-node-exporter (ARGS) is not used. \$\$ is a literal \$ for systemd."
    echo "[Service]"
    echo "ExecStart="
    echo "ExecStart=/usr/bin/prometheus-node-exporter --collector.textfile.directory=$PROM_DIR \"--collector.filesystem.mount-points-exclude=^/(dev|proc|run|sys|media|mnt/nas|var/lib/docker/.+|var/lib/containers/storage/.+)(\$\$|/)\" --collector.netdev.device-exclude=^veth --collector.netclass.ignored-devices=^veth"
    echo "IPAddressDeny=any"
    echo "IPAddressAllow=localhost"
    for a in $allow; do echo "IPAddressAllow=$a"; done
} > "$DROPIN.new"
mv -f "$DROPIN.new" "$DROPIN"
systemctl daemon-reload

log_info "Installing prometheus-node-exporter (no recommends)..."
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends prometheus-node-exporter

# The textfile sources: the list, the copy script and its timer. A source dropped from the list
# has its copy removed, so nothing stale is served for it.
log_info "Installing the textfile sources copy (asyla-textfile-sources.timer, every minute)..."
mkdir -p "$PROM_DIR" /etc/asyla
if [ -f "$LIST" ]; then
    while read -r old; do
        case "$old" in ''|'#'*) continue ;; esac
        grep -qxF "$old" <<<"$sources" || { rm -f "$PROM_DIR/$(basename "$old")"; log_info "Dropped source $old"; }
    done < "$LIST"
fi
{
    echo "# Written by asyla-hosts build/setup/node_exporter.sh from host.toml [node_exporter] textfile_sources."
    [ -z "$sources" ] || echo "$sources"
} > "$LIST.new"
mv -f "$LIST.new" "$LIST"
install -m 755 "$SRC/asyla-textfile-sources" /usr/local/sbin/asyla-textfile-sources
install -m 644 "$SRC/asyla-textfile-sources.service" "$SRC/asyla-textfile-sources.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now asyla-textfile-sources.timer
systemctl start asyla-textfile-sources.service

systemctl enable prometheus-node-exporter
systemctl restart prometheus-node-exporter

# Check: it answers on localhost with every textfile parsed and the copy's own metrics in it.
log_info "Checking http://127.0.0.1:9100/metrics..."
python3 - <<'PY' || { log_error "node exporter check failed"; exit 1; }
import sys, time, urllib.request
for _ in range(20):
    try:
        body = urllib.request.urlopen("http://127.0.0.1:9100/metrics", timeout=5).read().decode()
        break
    except OSError:
        time.sleep(0.5)
else:
    sys.exit("no answer on 127.0.0.1:9100")
lines = [l for l in body.splitlines() if l and not l.startswith("#")]
if "node_textfile_scrape_error 0" not in lines:
    sys.exit("node_textfile_scrape_error is not 0: a file in the textfile directory did not parse")
if not any(l.startswith("asyla_textfile_sources_last_run_timestamp_seconds ") for l in lines):
    sys.exit("asyla_textfile_sources.prom is not served")
ok = [l for l in lines if l.startswith("asyla_textfile_source_ok{")]
files = sorted(l.split('file="', 1)[1].split('"', 1)[0] for l in lines if l.startswith("node_textfile_mtime_seconds{"))
print(f"{len(lines)} series; textfiles: {', '.join(files)}; sources copied: {sum(l.endswith(' 1') for l in ok)} of {len(ok)}")
PY
log_info "✅ node exporter on :9100 (from localhost and $(echo $allow)), textfile directory $PROM_DIR"
