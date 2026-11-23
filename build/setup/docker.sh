#!/bin/bash
# Install Docker and Docker Compose v2 for Debian 13 (Trixie)
# Uses official Docker repository method

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Container logs: the `local` driver, which rotates (json-file, Docker's default, never does:
# https://docs.docker.com/engine/logging/drivers/json-file/). 20m x 5 files, compressed, are the
# driver's own defaults, written out (https://docs.docker.com/engine/logging/drivers/local/).
# `docker logs` and a log shipper that reads through the Docker API (Vector's docker_logs) read it;
# nothing may tail the files on disk. Operator, 2026-10-20 (asyla backlog
# 2026-10-20-hosts-observability-through-theorg, hygiene). Written before Docker is installed, so
# a new host's daemon starts with it. dockerd reads it only at start, and only containers created
# after that take it: on a host that already has containers this step writes nothing and stops,
# since applying it there restarts dockerd (operator approval per host).
DAEMON_JSON=/etc/docker/daemon.json
DAEMON_JSON_DEFAULT='{
  "log-driver": "local",
  "log-opts": { "max-size": "20m", "max-file": "5", "compress": "true" }
}'

# An optional [docker] table in this host's host.toml (HOST_SPEC) adds daemon settings (asyla
# #1237, ci01). A spec without it, or no HOST_SPEC, gets DAEMON_JSON_DEFAULT unchanged, so the
# hosts built before it see no change:
#   [docker]
#   data_root = "/mnt/docker/engine"     # dockerd's data-root: the data disk, not the OS disk
#   containerd_root = "/mnt/docker/containerd"   # containerd's root (below); not a daemon.json key
#   default_address_pools = [{ base = "10.210.0.0/16", size = 24 }]   # IPv4; size 16-30
#   registry_mirrors = ["http://127.0.0.1:5000"]   # http(s) URLs, no path
# Keys and their meaning: https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file.
# With the table, the JSON is the default's two keys plus data_root, default_address_pools and
# registry_mirrors, rendered by json.dumps (indent 2, in that key order), so the same spec always
# gives the same bytes; a table with none of those three gives the default's bytes.
#
# containerd_root: Docker Engine 29.0 and later use the containerd image store by default on a
# fresh install, and with it image content and snapshots live in containerd's root
# (/var/lib/containerd), which data-root does not move
# (https://docs.docker.com/engine/daemon/#daemon-data-directory,
# https://docs.docker.com/engine/storage/containerd/). d06 (29.10.0) and test01 (29.9.2) run that
# store (docker info: driver-type io.containerd.snapshotter.v1; read 2026-11-22). The store is
# kept, not turned off: theOrg's multi-arch builds may rely on it. So with containerd_root set,
# before containerd.io is installed, this step creates the directory (root:root 0711, as containerd
# creates its own root: containerd v2.1.4 cmd/containerd/server/server.go#L82) and a
# containerd.service drop-in (CONTAINERD_DROPIN) that waits for its mount and starts containerd
# with --root. A drop-in, not /etc/containerd/config.toml's root, so the package's config file is
# never rewritten; it replaces ExecStart, so after the install the step checks the package's unit
# still runs plain /usr/bin/containerd and the binary still takes --root (both true on d06 and
# test01, 2026-11-22), and fails otherwise. At the end it checks the running containerd's command
# line names containerd_root, and fails when data_root is set, the containerd store is active and
# containerd_root is not: the images would be on the OS disk.
# Prints the daemon.json content (no trailing newline is significant: callers compare with $(...)).
render_daemon_json() {
    render_docker_table daemon-json
}

# render_containerd_root: prints [docker] containerd_root, or nothing when the spec has none.
render_containerd_root() {
    render_docker_table containerd-root
}

# render_docker_table MODE: validates HOST_SPEC's [docker] table (every key, in both modes) and
# prints, for daemon-json, the daemon.json content; for containerd-root, containerd_root or nothing.
render_docker_table() {
    local mode="$1" spec="${HOST_SPEC:-}" json
    if [ -z "$spec" ] || ! grep -q '^\[docker' "$spec" 2>/dev/null; then
        # No table: no python needed, the old bytes exactly.
        if [ "$mode" = daemon-json ]; then printf '%s\n' "$DAEMON_JSON_DEFAULT"; fi
        return 0
    fi
    [ -f "$spec" ] || { log_error "HOST_SPEC $spec is not a file"; return 1; }
    json=$(python3 - "$spec" "$mode" <<'PY'
import ipaddress, json, re, sys, tomllib, urllib.parse
mode = sys.argv[2]
d = tomllib.load(open(sys.argv[1], "rb")).get("docker")
if d is None:
    sys.exit(0)   # no [docker] table (a [docker...] line of another table): the default
if not isinstance(d, dict):
    sys.exit("[docker] must be a table")
if not d:
    sys.exit(0)   # an empty table: the default's bytes, not a re-rendering of them
known = ("containerd_root", "data_root", "default_address_pools", "registry_mirrors")
unknown = set(d) - set(known)
if unknown:
    sys.exit(f"[docker]: unknown keys {sorted(unknown)} (known: {', '.join(known)})")
out = {"log-driver": "local", "log-opts": {"max-size": "20m", "max-file": "5", "compress": "true"}}
def abs_path(key):
    r = d[key]
    # A plain absolute path: it also goes into a systemd RequiresMountsFor= line (and, for
    # containerd_root, an ExecStart= line).
    if not (isinstance(r, str) and re.fullmatch(r"(/[A-Za-z0-9_.-]+)+", r) and "/../" not in r + "/" and "/./" not in r + "/"):
        sys.exit(f"[docker] {key} must be an absolute path (letters, digits, _ . -), not {r!r}")
    return r
if "data_root" in d:
    out["data-root"] = abs_path("data_root")
croot = abs_path("containerd_root") if "containerd_root" in d else None
if croot and "data-root" in out:
    a, b = croot + "/", out["data-root"] + "/"
    if a.startswith(b) or b.startswith(a):
        sys.exit(f"[docker] containerd_root {croot!r} and data_root {out['data-root']!r} must be separate directories, neither inside the other")
if "default_address_pools" in d:
    pools = d["default_address_pools"]
    if not isinstance(pools, list) or not pools:
        sys.exit("[docker] default_address_pools must be a non-empty list of { base = CIDR, size = N }")
    outp = []
    for p in pools:
        if not isinstance(p, dict) or set(p) != {"base", "size"}:
            sys.exit(f"[docker] default_address_pools: {p!r} must have exactly base and size")
        try:
            net = ipaddress.IPv4Network(p["base"], strict=True)
        except (TypeError, ValueError):
            sys.exit(f"[docker] default_address_pools: base {p['base']!r} is not an IPv4 network (a.b.c.d/N)")
        s = p["size"]
        if not isinstance(s, int) or isinstance(s, bool) or not 16 <= s <= 30 or s < net.prefixlen:
            sys.exit(f"[docker] default_address_pools: size {s!r} must be 16-30 and not shorter than {net}")
        outp.append({"base": str(net), "size": s})
    out["default-address-pools"] = outp
if "registry_mirrors" in d:
    mirrors = d["registry_mirrors"]
    if not isinstance(mirrors, list) or not mirrors:
        sys.exit("[docker] registry_mirrors must be a non-empty list of URLs")
    for m in mirrors:
        u = urllib.parse.urlsplit(m) if isinstance(m, str) else None
        if u is None or u.scheme not in ("http", "https") or not u.netloc or u.path not in ("", "/") \
                or u.query or u.fragment or not m.isprintable() or " " in m:
            sys.exit(f"[docker] registry_mirrors: {m!r} must be an http(s) URL with no path")
    out["registry-mirrors"] = mirrors
if mode == "containerd-root":
    if croot:
        print(croot)
elif len(out) > 2:
    print(json.dumps(out, indent=2))
# else: only containerd_root (not a daemon.json key): the default's bytes, printed by the caller
PY
) || { log_error "Bad [docker] in $spec"; return 1; }
    if [ "$mode" = daemon-json ] && [ -z "$json" ]; then json="$DAEMON_JSON_DEFAULT"; fi
    if [ -n "$json" ]; then printf '%s\n' "$json"; fi
}

# The containerd.service drop-in for containerd_root ROOT (see the header): wait for the mount, and
# start containerd with --root. ExecStart= empties the package unit's list first (systemd.service,
# ExecStart=: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#ExecStart=).
CONTAINERD_DROPIN=/etc/systemd/system/containerd.service.d/asyla-containerd-root.conf
CONTAINERD_DEFAULT_ROOT=/var/lib/containerd
CONTAINERD_EXEC=/usr/bin/containerd
containerd_dropin_text() {
    printf '%s\n' "# build/setup/docker.sh (asyla-hosts): containerd's root (the containerd image store's images and
# snapshots) is on the data disk; wait for it, and start containerd with that root.
[Unit]
RequiresMountsFor=$1

[Service]
ExecStart=
ExecStart=$CONTAINERD_EXEC --root $1"
}

# refuse_root_fs NAME DIR: exit 1 when DIR would be on the root filesystem (the nearest existing
# parent's mount is /), i.e. the data disk is not mounted there.
refuse_root_fs() {
    local probe="$2"
    while [ ! -e "$probe" ]; do probe=$(dirname "$probe"); done
    if [ "$(findmnt -no TARGET -T "$probe")" = "/" ]; then
        log_error "$1 $2 would be on the root filesystem: is the data disk mounted (build phase disk)?"
        exit 1
    fi
}

# --print-daemon-json: print the daemon.json this HOST_SPEC gives and stop (no root, nothing
# written; for the tests, as container_dns.sh --dropin). --print-containerd-dropin: the
# containerd.service drop-in it gives, or nothing without containerd_root. --check-data-disk: only
# the root-filesystem checks of data_root and containerd_root (reads findmnt, writes nothing).
case "${1:-}" in
    --print-daemon-json)
        render_daemon_json
        exit
        ;;
    --print-containerd-dropin)
        croot=$(render_containerd_root) || exit 1
        if [ -n "$croot" ]; then containerd_dropin_text "$croot"; fi
        exit 0
        ;;
    --check-data-disk)
        json=$(render_daemon_json) || exit 1
        croot=$(render_containerd_root) || exit 1
        case "$json" in
            *'"data-root"'*) refuse_root_fs data_root "$(printf '%s\n' "$json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data-root"])')" ;;
        esac
        if [ -n "$croot" ]; then refuse_root_fs containerd_root "$croot"; fi
        exit 0
        ;;
esac

# containerd_config_root: /etc/containerd/config.toml's top-level root, or nothing.
containerd_config_root() {
    [ -f /etc/containerd/config.toml ] || return 0
    python3 -c 'import sys, tomllib; r = tomllib.load(open(sys.argv[1], "rb")).get("root"); print(r) if isinstance(r, str) else None' \
        /etc/containerd/config.toml 2>/dev/null || true
}

# containerd_running_root: the running containerd's root (its --root flag, else config.toml's root,
# else containerd's default), from /proc/MainPID/cmdline. Nothing when containerd is not running.
containerd_running_root() {
    local pid i root="" args=()
    pid=$(systemctl show -p MainPID --value containerd 2>/dev/null || true)
    if [ -z "$pid" ] || [ "$pid" = 0 ] || [ ! -r "/proc/$pid/cmdline" ]; then return 0; fi
    mapfile -d '' args < "/proc/$pid/cmdline"
    for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[i]}" in
            --root) root="${args[i+1]:-}" ;;
            --root=*) root="${args[i]#--root=}" ;;
        esac
    done
    [ -n "$root" ] || root=$(containerd_config_root)
    printf '%s\n' "${root:-$CONTAINERD_DEFAULT_ROOT}"
}

# containerd_current_root: the root containerd runs with now, or would start with (the drop-in's
# --root, else config.toml's, else the default).
containerd_current_root() {
    local root
    root=$(containerd_running_root)
    if [ -z "$root" ] && [ -f "$CONTAINERD_DROPIN" ]; then
        root=$(sed -n "s|^ExecStart=$CONTAINERD_EXEC --root ||p" "$CONTAINERD_DROPIN" | tail -n 1)
    fi
    [ -n "$root" ] || root=$(containerd_config_root)
    printf '%s\n' "${root:-$CONTAINERD_DEFAULT_ROOT}"
}

# containerd_has_content DIR: DIR holds image content (a blob) or a snapshot.
containerd_has_content() {
    [ -n "$(find "$1/io.containerd.content.v1.content/blobs" -type f -print -quit 2>/dev/null)" ] ||
        [ -n "$(find "$1/io.containerd.snapshotter.v1.overlayfs/snapshots" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

log_info "Starting Docker installation..."

# Update package lists
log_info "Updating package lists..."
apt update

# Install prerequisites for Docker repository
log_info "Installing prerequisites..."
apt install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Add Docker's official GPG key
log_info "Adding Docker's official GPG key..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Set up Docker repository for Debian
log_info "Setting up Docker repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package lists again to include Docker repository
log_info "Updating package lists with Docker repository..."
apt update

# daemon.json (DAEMON_JSON_DEFAULT, or from [docker]; render_daemon_json above).
DAEMON_JSON_WANT=$(render_daemon_json)
DATA_ROOT=""
case "$DAEMON_JSON_WANT" in
    *'"data-root"'*) DATA_ROOT=$(printf '%s\n' "$DAEMON_JSON_WANT" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data-root"])') ;;
esac

# A data-root on the data disk: /mnt/docker is in fstab with nofail (data_disk.sh), so a boot
# without that disk would start dockerd on an empty directory of the OS disk. The drop-in makes
# docker.service require and follow the mount that holds DATA_ROOT (RequiresMountsFor=,
# https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html#RequiresMountsFor=).
# Written before Docker is installed, so its first start already waits. Removed again when the
# spec has no data_root (the hosts before ci01 never had it, so for them nothing changes).
DOCKER_DROPIN=/etc/systemd/system/docker.service.d/asyla-data-root.conf
if [ -n "$DATA_ROOT" ]; then
    # The data disk must hold it: the nearest existing parent's mount is not /.
    refuse_root_fs data_root "$DATA_ROOT"
    # root:root 0710, as dockerd creates its default /var/lib/docker.
    install -d -m 0710 -o root -g root "$DATA_ROOT"
    dropin_want="# build/setup/docker.sh (asyla-hosts): dockerd's data-root is on the data disk; wait for it.
[Unit]
RequiresMountsFor=$DATA_ROOT"
    if [ "$(cat "$DOCKER_DROPIN" 2>/dev/null)" != "$dropin_want" ]; then
        install -d -m 755 "$(dirname "$DOCKER_DROPIN")"
        printf '%s\n' "$dropin_want" > "$DOCKER_DROPIN"
        chmod 644 "$DOCKER_DROPIN"
        systemctl daemon-reload
        log_info "Wrote $DOCKER_DROPIN (RequiresMountsFor=$DATA_ROOT)"
    fi
elif [ -f "$DOCKER_DROPIN" ]; then
    rm -f "$DOCKER_DROPIN"
    systemctl daemon-reload
    log_info "Removed $DOCKER_DROPIN (the spec has no [docker] data_root)"
fi

# containerd's root on the data disk (containerd_root; the header says why). Written before
# containerd.io is installed, so its first start already uses it. A change of root on a host whose
# containerd already holds images, or that has containers, is refused: the moved root would lose
# them (operator approval per host, as for daemon.json below). A spec without containerd_root
# writes nothing (and removes a drop-in left from an earlier spec, under the same refusal).
CONTAINERD_ROOT=$(render_containerd_root)
if [ -n "$CONTAINERD_ROOT" ]; then
    containerd_want=$(containerd_dropin_text "$CONTAINERD_ROOT")
else
    containerd_want=""
fi
if [ "$(cat "$CONTAINERD_DROPIN" 2>/dev/null)" != "$containerd_want" ]; then
    old_root=$(containerd_current_root)
    if [ "$old_root" != "${CONTAINERD_ROOT:-$CONTAINERD_DEFAULT_ROOT}" ]; then
        if containerd_has_content "$old_root"; then
            log_error "containerd's root would move from $old_root to ${CONTAINERD_ROOT:-$CONTAINERD_DEFAULT_ROOT}, and $old_root holds images or snapshots that the move would lose: ask the operator (per host)."
            exit 1
        fi
        if command -v docker >/dev/null && [ -n "$(docker ps -aq 2>/dev/null)" ]; then
            log_error "containerd's root would move from $old_root and the host has containers: ask the operator (per host)."
            exit 1
        fi
    fi
    if [ -n "$CONTAINERD_ROOT" ]; then
        refuse_root_fs containerd_root "$CONTAINERD_ROOT"
        # root:root 0711, as containerd creates its own root (header).
        install -d -m 0711 -o root -g root "$CONTAINERD_ROOT"
        install -d -m 755 "$(dirname "$CONTAINERD_DROPIN")"
        printf '%s\n' "$containerd_want" > "$CONTAINERD_DROPIN"
        chmod 644 "$CONTAINERD_DROPIN"
        log_info "Wrote $CONTAINERD_DROPIN (containerd --root $CONTAINERD_ROOT, RequiresMountsFor)"
    else
        rm -f "$CONTAINERD_DROPIN"
        log_info "Removed $CONTAINERD_DROPIN (the spec has no [docker] containerd_root)"
    fi
    systemctl daemon-reload
    if systemctl is-active -q containerd 2>/dev/null; then
        systemctl restart containerd
        if systemctl is-active -q docker 2>/dev/null; then systemctl restart docker; fi
    fi
elif [ -n "$CONTAINERD_ROOT" ]; then
    refuse_root_fs containerd_root "$CONTAINERD_ROOT"
fi

if [ "$(cat "$DAEMON_JSON" 2>/dev/null)" != "$DAEMON_JSON_WANT" ]; then
    if command -v docker >/dev/null && [ -n "$(docker ps -aq 2>/dev/null)" ]; then
        log_error "$DAEMON_JSON differs from this build's and the host has containers. Applying it restarts dockerd, so it is not done here: ask the operator (per host), then write it and restart docker."
        exit 1
    fi
    log_info "Writing $DAEMON_JSON (log driver local, 20m x 5)..."
    install -d -m 755 /etc/docker
    printf '%s\n' "$DAEMON_JSON_WANT" > "$DAEMON_JSON"
    chmod 644 "$DAEMON_JSON"
    if systemctl is-active -q docker 2>/dev/null; then
        systemctl restart docker
    fi
fi

# Install Docker Engine, CLI, and containerd
log_info "Installing Docker Engine, CLI, and containerd..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# The drop-in replaces the package unit's ExecStart: that is sound only while the package's own
# line is plain /usr/bin/containerd (any flags it adds would be dropped) and the binary takes --root.
if [ -n "$CONTAINERD_ROOT" ]; then
    unit_file=$(systemctl show -p FragmentPath --value containerd)
    unit_exec=$(grep -E '^ExecStart=' "$unit_file" 2>/dev/null || true)
    containerd_help=$("$CONTAINERD_EXEC" --help 2>&1 || true)
    case "$containerd_help" in *--root*) has_root_flag=yes ;; *) has_root_flag=no ;; esac
    if [ "$unit_exec" != "ExecStart=$CONTAINERD_EXEC" ] || [ "$has_root_flag" != yes ]; then
        log_error "containerd.io changed: $unit_file has '$unit_exec' (want ExecStart=$CONTAINERD_EXEC), --root flag: $has_root_flag. $CONTAINERD_DROPIN no longer fits; set the root in /etc/containerd/config.toml (top-level root) instead."
        exit 1
    fi
fi

# Enable and start Docker service
log_info "Enabling and starting Docker service..."
systemctl enable docker
systemctl start docker

# Add docker user to docker group (if user exists)
if id "docker" &>/dev/null; then
    log_info "Adding docker user to docker group..."
    usermod -aG docker docker
    log_info "User 'docker' added to docker group. User may need to log out and back in for changes to take effect."
else
    log_warn "User 'docker' does not exist. Please create the user first or add manually: usermod -aG docker <username>"
fi

# Verify Docker installation
log_info "Verifying Docker installation..."
docker --version
docker compose version
driver=$(docker info --format '{{.LoggingDriver}}')
if [ "$driver" != "local" ]; then
    log_error "Docker's log driver is $driver, not local ($DAEMON_JSON)"
    exit 1
fi
log_info "✅ Log driver: $driver"
# The [docker] settings, as the running daemon reports them (docker info's JSON: DockerRootDir,
# RegistryConfig.Mirrors, DefaultAddressPools; moby api/types/system/info.go). A mirror is listed
# with a trailing slash.
case "$DAEMON_JSON_WANT" in
    *'"data-root"'*|*'"registry-mirrors"'*|*'"default-address-pools"'*)
        if ! docker info --format '{{json .}}' | python3 -c '
import json, sys
want, info = json.loads(sys.argv[1]), json.load(sys.stdin)
bad = []
root, have_root = want.get("data-root"), info.get("DockerRootDir")
if root and have_root != root:
    bad.append(f"data root {have_root}, not {root}")
have_m = [m.rstrip("/") for m in (info.get("RegistryConfig") or {}).get("Mirrors") or []]
for m in want.get("registry-mirrors", []):
    if m.rstrip("/") not in have_m:
        bad.append(f"registry mirror {m} not in {have_m}")
have_p = [(p.get("Base"), p.get("Size")) for p in info.get("DefaultAddressPools") or []]
for p in want.get("default-address-pools", []):
    base, size = p["base"], p["size"]
    if (base, size) not in have_p:
        bad.append(f"address pool {base} size {size} not in {have_p}")
for b in bad:
    print(b, file=sys.stderr)
sys.exit(1 if bad else 0)' "$DAEMON_JSON_WANT"; then
            log_error "dockerd does not run with $DAEMON_JSON's [docker] settings (above)"
            exit 1
        fi
        log_info "✅ dockerd runs with the [docker] settings (data root, mirrors, address pools)"
        ;;
esac
# Which image store is active (docker info .Driver and .DriverStatus: driver-type
# io.containerd.snapshotter.v1 for the containerd store), and the running containerd's root. Only
# for a spec with data_root or containerd_root: the hosts before ci01 get no new check.
if [ -n "$DATA_ROOT$CONTAINERD_ROOT" ]; then
    store=$(docker info --format '{{.Driver}} {{json .DriverStatus}}')
    case "$store" in *io.containerd.snapshotter.v1*) containerd_store=yes ;; *) containerd_store=no ;; esac
    have_croot=$(containerd_running_root)
    log_info "Image store: $store (containerd store: $containerd_store); containerd root: ${have_croot:-containerd not running}"
    if [ -n "$CONTAINERD_ROOT" ] && [ "$have_croot" != "$CONTAINERD_ROOT" ]; then
        log_error "containerd runs with root '${have_croot:-none}', not [docker] containerd_root $CONTAINERD_ROOT ($CONTAINERD_DROPIN)"
        exit 1
    fi
    if [ -z "$CONTAINERD_ROOT" ] && [ "$containerd_store" = yes ]; then
        log_error "data_root is $DATA_ROOT, but Docker's containerd image store is active, so images and snapshots are in containerd's root ${have_croot:-$CONTAINERD_DEFAULT_ROOT}, not under data_root: set [docker] containerd_root on the data disk."
        exit 1
    fi
    log_info "✅ Image store on the data disk (containerd store: $containerd_store, containerd root ${have_croot:-not running}, data root ${DATA_ROOT:-default})"
fi

# Clean up package cache
log_info "Cleaning up package cache..."
apt autoremove -y
apt autoclean

log_info "Docker installation completed successfully!"
log_info "Docker version: $(docker --version)"
log_info "Docker Compose version: $(docker compose version)"

