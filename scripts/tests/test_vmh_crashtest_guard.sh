#!/bin/bash
# vmh/apply.sh crashtest vmh03: refused while a guest runs on vmh03 unless --with-guests (asyla hub
# backlog, the d07 item, fail-safe rule 6), and setup.sh's crashtest takes the same flag. ssh is a
# stub first in PATH and HOME is a temp dir (no key), so nothing here reaches a node; the test
# aborts before the first apply.sh call unless `ssh` is that stub. setup.sh's crashtest() runs
# here as an extracted function with its crash line, /sys and /etc paths replaced (no root).
# Run: bash scripts/tests/test_vmh_crashtest_guard.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLY="$REPO/vmh/apply.sh"
SETUP="$REPO/vmh/setup.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fail=1; }

mkdir -p "$T/bin" "$T/log"
cat >"$T/bin/ssh" <<'STUB'
#!/bin/bash
# Records argv (one line per call) and stdin; setup.sh itself exits 0, the guest read answers
# $FAKE_GUESTS with ${FAKE_RC:-0}. Never contacts anything.
n=$(wc -l <"$STUB_LOG/calls" 2>/dev/null || echo 0); n=$((n + 0))
printf '%s\n' "$*" >>"$STUB_LOG/calls"
cat >"$STUB_LOG/stdin.$n"
if grep -qF 'crashtest()' "$STUB_LOG/stdin.$n"; then exit 0; fi
[ -z "${FAKE_GUESTS:-}" ] || printf '%s\n' "$FAKE_GUESTS"
exit "${FAKE_RC:-0}"
STUB
chmod +x "$T/bin/ssh"
export HOME="$T" PATH="$T/bin:$PATH" STUB_LOG="$T/log"
if [ "$(command -v ssh)" != "$T/bin/ssh" ]; then
    echo "FAIL ssh is $(command -v ssh), not the stub: aborting before any apply.sh call"
    exit 1
fi

# apply.sh ARGS... with FAKE_GUESTS / FAKE_RC from the caller; sets rc, out (stderr+stdout), calls.
apply() {
    rm -f "$T/log"/*
    out=$(bash "$APPLY" "$@" 2>&1); rc=$?
    calls=$(cat "$T/log/calls" 2>/dev/null)
}
ncalls() { [ -z "$calls" ] && echo 0 || printf '%s\n' "$calls" | wc -l | tr -d ' '; }
setup_sent() { grep -lF 'crashtest()' "$T/log"/stdin.* >/dev/null 2>&1; }

GUEST='VM 107 (d07)'

FAKE_GUESTS=$GUEST apply crashtest vmh03
[ "$rc" = 3 ] && [ "$(ncalls)" = 0 ] && ok "no --production: exit 3 before any ssh" || bad "no --production" "rc $rc, calls: $calls"

FAKE_GUESTS=$GUEST apply crashtest vmh03 --production
if [ "$rc" = 3 ] && grep -qF "$GUEST" <<<"$out" && grep -qF -- "--with-guests" <<<"$out" && [ "$(ncalls)" = 1 ] && ! setup_sent; then
    ok "a guest runs, no --with-guests: exit 3, names it, setup.sh never sent"
else bad "a guest runs, no --with-guests" "rc $rc, calls: $calls, out: $out"; fi
grep -qF 'qm list' "$T/log/stdin.0" && grep -qF 'pct list' "$T/log/stdin.0" && grep -qF 'root@10.0.0.37' <<<"$calls" \
    && ok "the guest read is qm list and pct list on vmh03" || bad "the guest read" "$calls"
cp "$T/log/stdin.0" "$T/guest_read.sh"

FAKE_GUESTS=$GUEST apply crashtest vmh03 --with-guests --production
last=$(printf '%s\n' "$calls" | tail -1)
if [ "$rc" = 0 ] && [ "$(ncalls)" = 2 ] && setup_sent && [ "${last% sh -s -- crashtest --with-guests}" != "$last" ] \
    && grep -qF "$GUEST" <<<"$out"; then
    ok "--with-guests: setup.sh sent with crashtest --with-guests, the guests named"
else bad "--with-guests" "rc $rc, calls: $calls, out: $out"; fi

FAKE_GUESTS=$GUEST apply crashtest vmh03 --console --with-guests --production
last=$(printf '%s\n' "$calls" | tail -1)
[ "$rc" = 0 ] && setup_sent && [ "${last% sh -s -- crashtest --console --with-guests}" != "$last" ] \
    && ok "--console --with-guests: both passed on" || bad "--console --with-guests" "rc $rc, calls: $calls"

FAKE_GUESTS='' apply crashtest vmh03 --production
last=$(printf '%s\n' "$calls" | tail -1)
[ "$rc" = 0 ] && [ "$(ncalls)" = 2 ] && setup_sent && [ "${last% sh -s -- crashtest}" != "$last" ] \
    && ok "no guest runs: setup.sh sent" || bad "no guest runs" "rc $rc, calls: $calls, out: $out"

FAKE_GUESTS='' FAKE_RC=255 apply crashtest vmh03 --production
[ "$rc" = 1 ] && [ "$(ncalls)" = 1 ] && ! setup_sent && grep -qF "cannot read the running guests" <<<"$out" \
    && ok "the guest read fails: refused, setup.sh never sent" || bad "the guest read fails" "rc $rc, calls: $calls, out: $out"

FAKE_GUESTS=$GUEST apply crashtest vmh03 --clean --production
last=$(printf '%s\n' "$calls" | tail -1)
[ "$rc" = 0 ] && [ "$(ncalls)" = 1 ] && setup_sent && [ "${last% sh -s -- crashtest --clean}" != "$last" ] \
    && ok "--clean with a guest running: no guest read, setup.sh sent" || bad "--clean" "rc $rc, calls: $calls"

# The guest read itself, run here by sh against stand-in qm and pct (the nodes' column layout).
mkdir -p "$T/pve"
cat >"$T/pve/qm" <<'QM'
#!/bin/sh
[ -z "${QM_FAIL:-}" ] || exit 2
cat <<'L'
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
       107 d07                  running    4096              32.00 1234
       901 test01               stopped    2048               8.00 0
L
QM
cat >"$T/pve/pct" <<'PCT'
#!/bin/sh
cat <<'L'
VMID       Status     Lock         Name
200        running                 ct-a
201        stopped                 ct-b
L
PCT
chmod +x "$T/pve/qm" "$T/pve/pct"
# Only the small read is run here, never setup.sh (an apply.sh without the read sends setup.sh first).
if grep -qF 'crashtest()' "$T/guest_read.sh" || ! grep -qF 'qm list' "$T/guest_read.sh"; then
    bad "guest read" "the first thing sent is not the guest read; not run here"
else
    got=$(PATH="$T/pve:$PATH" sh "$T/guest_read.sh"); grc=$?
    [ "$grc" = 0 ] && [ "$got" = $'VM 107 (d07)\nCT 200' ] && ok "guest read: running VMs and CTs only, no header" \
        || bad "guest read" "rc $grc, got: $got"
    PATH="$T/pve:$PATH" QM_FAIL=1 sh "$T/guest_read.sh" >/dev/null 2>&1 \
        && bad "guest read: a failed qm list is a failed read" || ok "guest read: a failed qm list is a failed read"
fi

# setup.sh's crashtest(): its argument parsing and the guest count, with the crash line replaced.
awk '/^crashtest\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$SETUP" \
    | sed -e "s#/sys/kernel/kexec_crash_loaded#$T/kexec_loaded#" \
          -e "s#/etc/pve/corosync.conf#$T/no-corosync.conf#" \
          -e 's#^\( *\)nohup .*sysrq-trigger.*#\1say "CRASH (stand-in)"#' >"$T/crashtest_fn.sh"
if ! grep -q '^crashtest() {' "$T/crashtest_fn.sh" || grep -q 'sysrq' "$T/crashtest_fn.sh" \
    || ! grep -qF 'CRASH (stand-in)' "$T/crashtest_fn.sh"; then
    bad "setup.sh crashtest() extracted with its crash line replaced" "skipping the setup.sh cases"
else
    echo 1 >"$T/kexec_loaded"
    cat >"$T/pve/kdump-config" <<'KD'
#!/bin/sh
[ "$1" = show ] && echo "kexec command: (stand-in)"
exit 0
KD
    chmod +x "$T/pve/kdump-config"
    if ! sed --version >/dev/null 2>&1; then   # BSD sed (macOS): GNU's `sed -i SCRIPT FILE` as the node runs it
        real_sed=$(command -v sed)
        printf '#!/bin/sh\nif [ "$1" = -i ]; then shift; exec %s -i "" "$@"; fi\nexec %s "$@"\n' "$real_sed" "$real_sed" >"$T/pve/sed"
        chmod +x "$T/pve/sed"
    fi
    sh_bin=$(command -v dash || echo /bin/sh)
    crash() {   # QM_RUNNING=0|1, then crashtest's args; sets rc, out
        : >"$T/kdump-tools"
        out=$(cd "$T" && PATH="$T/pve:$PATH" "$sh_bin" -c '
            set -eu
            say() { printf "%s\n" "$*"; }
            die() { printf "vmh setup: %s\n" "$*" >&2; exit 1; }
            part_crash() { say "part_crash (stand-in)"; }
            ROLE=canary node=vmh03 KDUMP_DEFAULTS="$1" KDUMP_APPEND="panic=10"
            . "$2"
            shift 2
            crashtest "$@"' sh "$T/kdump-tools" "$T/crashtest_fn.sh" "$@" 2>&1); rc=$?
    }
    # qm with a running guest unless QM_RUNNING=0 (the stand-in above lists one running VM).
    QM_STOPPED="$T/pve-stopped"; mkdir -p "$QM_STOPPED"
    printf '#!/bin/sh\necho "      VMID NAME STATUS"\n' >"$QM_STOPPED/qm"
    printf '#!/bin/sh\necho "VMID Status Lock Name"\n' >"$QM_STOPPED/pct"
    chmod +x "$QM_STOPPED/qm" "$QM_STOPPED/pct"

    crash --bogus
    [ "$rc" = 1 ] && grep -qF 'crashtest [--console] [--with-guests] | --clean' <<<"$out" \
        && ok "setup.sh: an unknown flag dies with the usage" || bad "setup.sh: unknown flag" "rc $rc, $out"
    crash
    [ "$rc" = 1 ] && grep -qF '2 guest(s) running' <<<"$out" && ! grep -qF CRASH <<<"$out" \
        && ok "setup.sh: guests run, no --with-guests: dies before the crash" || bad "setup.sh: guests, no flag" "rc $rc, $out"
    crash --with-guests
    [ "$rc" = 0 ] && grep -qF 'warning 2 guest(s) running' <<<"$out" && grep -qF 'CRASH (stand-in)' <<<"$out" \
        && ! grep -qF loglevel=7 "$T/kdump-tools" \
        && ok "setup.sh: --with-guests warns with the count and goes on" || bad "setup.sh: --with-guests" "rc $rc, $out"
    for order in "--console --with-guests" "--with-guests --console"; do
        # shellcheck disable=SC2086
        crash $order
        [ "$rc" = 0 ] && grep -qF 'CRASH (stand-in)' <<<"$out" && grep -qF loglevel=7 "$T/kdump-tools" \
            && ok "setup.sh: $order in either order" || bad "setup.sh: $order" "rc $rc, $out"
    done
    out=$(cd "$T" && PATH="$QM_STOPPED:$T/pve:$PATH" "$sh_bin" -c '
        set -eu
        say() { printf "%s\n" "$*"; }
        die() { printf "vmh setup: %s\n" "$*" >&2; exit 1; }
        ROLE=canary node=vmh03 KDUMP_DEFAULTS="$1" KDUMP_APPEND="panic=10"
        . "$2"
        crashtest' sh "$T/kdump-tools" "$T/crashtest_fn.sh" 2>&1); rc=$?
    [ "$rc" = 0 ] && grep -qF 'CRASH (stand-in)' <<<"$out" && ! grep -qF warning <<<"$out" \
        && ok "setup.sh: no guest runs: goes on without a warning" || bad "setup.sh: no guests" "rc $rc, $out"
fi

sh -n "$SETUP" && ok "sh -n vmh/setup.sh" || bad "sh -n vmh/setup.sh"
bash -n "$APPLY" && ok "bash -n vmh/apply.sh" || bad "bash -n vmh/apply.sh"

exit "$fail"
