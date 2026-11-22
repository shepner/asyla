#!/bin/bash
# QEMU user-mode binfmt for arm64 legs of multi-arch builds (docker buildx) on an amd64 host: ci01
# (asyla #1237). Debian's qemu-user-binfmt (trixie; depends on qemu-user), without recommends:
# https://packages.debian.org/trixie/qemu-user-binfmt . It ships only registration data in
# /usr/lib/binfmt.d/, which systemd (systemd-binfmt) loads into the kernel at boot.
#
# Then checks the kernel's entry /proc/sys/fs/binfmt_misc/qemu-aarch64: "enabled", and flag F in
# its "flags:" line. F (fix binary) makes the kernel open the interpreter when the entry is
# registered, so a process inside a container, whose root has no /usr/bin/qemu-aarch64, still runs
# arm64 binaries with the host's. Without F this step fails and names the cause; it does not
# re-register the entry with other flags. build_host.py verify makes the same check.
#
# Idempotent: installs only when the package is absent; registers the entry from binfmt.d only
# when the kernel has none (a fresh install before the next boot).

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

PKG=qemu-user-binfmt
BINFMT_DIR=/proc/sys/fs/binfmt_misc
ENTRY="$BINFMT_DIR/qemu-aarch64"
CONF=/usr/lib/binfmt.d/qemu-aarch64.conf
AUTOMOUNT=proc-sys-fs-binfmt_misc.automount

if [ "$(dpkg-query -W -f='${Status}' "$PKG" 2>/dev/null || true)" = "install ok installed" ]; then
    log_info "$PKG is installed"
else
    log_info "Installing $PKG (no recommends)..."
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$PKG"
fi

# binfmt_misc is mounted by systemd's $AUTOMOUNT on first access; reading status triggers it.
if ! cat "$BINFMT_DIR/status" >/dev/null 2>&1; then
    log_error "binfmt_misc is not mounted at $BINFMT_DIR ($AUTOMOUNT: $(systemctl is-active "$AUTOMOUNT" 2>/dev/null || true))"
    exit 1
fi
if [ "$(cat "$BINFMT_DIR/status")" != enabled ]; then
    log_error "binfmt_misc is disabled ($BINFMT_DIR/status is not 'enabled')"
    exit 1
fi

if [ ! -e "$ENTRY" ]; then
    [ -f "$CONF" ] || { log_error "$PKG installed no $CONF"; exit 1; }
    log_info "Registering qemu-aarch64 from $CONF (systemd-binfmt)..."
    /usr/lib/systemd/systemd-binfmt "$CONF"
fi
[ -e "$ENTRY" ] || { log_error "no $ENTRY after registering $CONF"; exit 1; }

state=$(head -n 1 "$ENTRY")
flags=$(awk -F': *' '$1 == "flags" { print $2 }' "$ENTRY")
if [ "$state" != enabled ]; then
    log_error "$ENTRY is '$state', not enabled"
    exit 1
fi
case "$flags" in
    *F*) ;;
    *)
        log_error "$ENTRY has flags '$flags', without F (fix binary): the entry was registered without it (see $CONF, or a binfmt.d file in /etc or /run that overrides it), so containers cannot use the host's interpreter. Not re-registering; fix the registration's source."
        exit 1
        ;;
esac
log_info "✅ qemu-aarch64 binfmt enabled, flags $flags ($(awk '$1 == "interpreter" { print $2 }' "$ENTRY"))"
