#!/usr/bin/env python3
"""Offline test of build_host.py's opt-in SSH override (BUILD_HOST_SSH_KEY,
BUILD_HOST_SSH_KNOWN_HOSTS, BUILD_HOST_SSH_BY_ADDRESS; build_host.py's docstring).

    python3 scripts/tests/test_build_host_ssh_override.py

Unset, ssh_argv is what it was before the override existed, list for list. Set, a guest is
reached with the given key, by its spec's [vm] ip, and only a host key the given known_hosts pins
is accepted. No host is contacted: subprocess.run and urlopen are replaced, and the one case that
runs ssh runs `ssh -G` (prints the configuration it would use; connects to nothing). Exit 0 when
every case passes.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_host  # noqa: E402

REAL_RUN = subprocess.run


def _no_contact(*a, **kw):
    raise AssertionError(f"the test reached out: {a[:1]}")


build_host.subprocess.run = _no_contact
build_host.urllib.request.urlopen = _no_contact

NAMES = (build_host.SSH_KEY_ENV, build_host.SSH_KNOWN_HOSTS_ENV, build_host.SSH_BY_ADDRESS_ENV)
SAVED = {n: os.environ.pop(n) for n in NAMES if n in os.environ}
D = Path(tempfile.mkdtemp(prefix="build-host-ssh-"))
KEY, KNOWN = D / "id_ed25519", D / "known_hosts"
KEY.write_text("not a key: a stand-in file\n")
KNOWN.write_text("")
BASE = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
PINS = ["-o", f"UserKnownHostsFile={KNOWN}", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes"]
HOME_KEY = str(Path.home() / ".ssh/docker_rsa")


def check(name: str, good: bool, detail: str = "") -> bool:
    print(f"{'ok  ' if good else 'FAIL'}  {name}{': ' + detail if detail and not good else ''}")
    return good


def env(**kw):
    """Exactly these override variables in the environment (None: unset)."""
    for n in NAMES:
        os.environ.pop(n, None)
    for k, v in kw.items():
        if v is not None:
            os.environ[{"key": build_host.SSH_KEY_ENV, "known": build_host.SSH_KNOWN_HOSTS_ENV,
                        "by_address": build_host.SSH_BY_ADDRESS_ENV}[k]] = v


def argv_is(name: str, target: str, want: list[str], **kw) -> bool:
    env(**kw)
    try:
        got = build_host.ssh_argv(target)
    except build_host.Fail as e:
        got = f"Fail: {e}"
    return check(name, got == want, f"\n        got  {got}\n        want {want}")


def fails(name: str, target: str, needle: str, **kw) -> bool:
    env(**kw)
    try:
        got = build_host.ssh_argv(target)
    except build_host.Fail as e:
        return check(name, needle in str(e), str(e))
    return check(name, False, f"no Fail: {got}")


def spec_ip(host: str) -> str:
    return build_host.load_spec(host)["vm"]["ip"].split("/")[0]


def ssh_passes_argv_case() -> bool:
    """ssh() runs ssh_argv's command, the override included, with the remote command last."""
    seen = []
    build_host.subprocess.run = lambda argv, **kw: seen.append(argv) or subprocess.CompletedProcess(argv, 0, "", "")
    try:
        env(key=str(KEY), known=str(KNOWN), by_address="1")
        build_host.ssh("d06", "true", check=False)
        build_host.ssh("d06", "true", check=False, stream=True)
    finally:
        build_host.subprocess.run = _no_contact
    want = BASE + PINS + ["-i", str(KEY), "-o", "IdentitiesOnly=yes", f"docker@{spec_ip('d06')}", "true"]
    return check("ssh(): both the captured and the streamed run use the override's command", seen == [want, want],
                 repr(seen))


def wait_ssh_case() -> bool:
    """wait_ssh adds StrictHostKeyChecking=accept-new after ssh_argv's options: with the override,
    StrictHostKeyChecking=yes comes first, which ssh keeps."""
    seen = []
    build_host.subprocess.run = lambda argv, **kw: seen.append(argv) or subprocess.CompletedProcess(argv, 0, "", "")
    try:
        env(key=str(KEY), known=str(KNOWN), by_address="1")
        with open(os.devnull, "w") as null:
            real, sys.stdout = sys.stdout, null
            try:
                build_host.wait_ssh("d06", minutes=1)
            finally:
                sys.stdout = real
    finally:
        build_host.subprocess.run = _no_contact
    a = seen[0] if seen else []
    return check("wait_ssh: the override's StrictHostKeyChecking=yes comes before accept-new, the target is the address",
                 bool(a) and a.index("StrictHostKeyChecking=yes") < a.index("StrictHostKeyChecking=accept-new")
                 and a[-2:] == [f"docker@{spec_ip('d06')}", "true"], repr(a))


def ssh_g_case() -> bool:
    """`ssh -G` (prints the configuration, connects to nothing) on the override's command: the
    options ssh would really use, whatever ~/.ssh/config says, even after a later accept-new."""
    if not shutil.which("ssh"):
        return check("ssh -G: skipped, no ssh here", True)
    env(key=str(KEY), known=str(KNOWN), by_address="1")
    a = build_host.ssh_argv("d06")
    r = REAL_RUN(["ssh", "-G"] + a[1:-1] + ["-o", "StrictHostKeyChecking=accept-new", a[-1]],
                 capture_output=True, text=True, timeout=30)
    got = {}
    for line in r.stdout.splitlines():
        k, _, v = line.partition(" ")
        got.setdefault(k, v)
    want = {"user": "docker", "hostname": spec_ip("d06"), "stricthostkeychecking": "true",
            "userknownhostsfile": str(KNOWN), "globalknownhostsfile": "/dev/null",
            "identitiesonly": "yes", "identityfile": str(KEY), "batchmode": "yes"}
    return check("ssh -G: docker@<d06 ip>, the key only, the pinned file only, strict checking kept, batch mode",
                 r.returncode == 0 and all(got.get(k) == v for k, v in want.items()),
                 repr({k: got.get(k) for k in want}) + r.stderr[-300:])


try:
    results = [
        # Unset: the commands before the override, list for list.
        argv_is("unset: a guest is docker@NAME with ~/.ssh/docker_rsa, as before", "test01",
                BASE + ["-i", HOME_KEY, "docker@test01"]),
        argv_is("unset: a node is passed through, as before", "root@vmh01", BASE + ["root@vmh01"]),
        check("unset: the module's ssh options are as before", build_host.SSH == BASE and str(build_host.SSH_KEY) == HOME_KEY),
        # Each part alone.
        argv_is("key: a guest gets -i KEY and IdentitiesOnly=yes, still by name", "d06",
                BASE + ["-i", str(KEY), "-o", "IdentitiesOnly=yes", "docker@d06"], key=str(KEY)),
        argv_is("key: a node keeps its own key", "root@vmh01", BASE + ["root@vmh01"], key=str(KEY)),
        argv_is("known_hosts: a guest gets the pinned file only, strict checking, the usual key", "d06",
                BASE + PINS + ["-i", HOME_KEY, "docker@d06"], known=str(KNOWN)),
        argv_is("known_hosts: a node gets the pinned file and strict checking too", "root@vmh01",
                BASE + PINS + ["root@vmh01"], known=str(KNOWN)),
        argv_is("by address: d06 is docker@<its d06/host.toml [vm] ip>", "d06",
                BASE + ["-i", HOME_KEY, f"docker@{spec_ip('d06')}"], by_address="1"),
        argv_is("by address: a node is passed through", "root@vmh01", BASE + ["root@vmh01"], by_address="1"),
        # The redeploy job's set: all three.
        argv_is("all three: d06 by address, the key, the pins", "d06",
                BASE + PINS + ["-i", str(KEY), "-o", "IdentitiesOnly=yes", f"docker@{spec_ip('d06')}"],
                key=str(KEY), known=str(KNOWN), by_address="1"),
        argv_is("all three: d03 by address, the key, the pins", "d03",
                BASE + PINS + ["-i", str(KEY), "-o", "IdentitiesOnly=yes", f"docker@{spec_ip('d03')}"],
                key=str(KEY), known=str(KNOWN), by_address="1"),
        check("the addresses are the specs' own: d06 10.0.0.65, d03 10.0.0.62",
              (spec_ip("d06"), spec_ip("d03")) == ("10.0.0.65", "10.0.0.62")),
        # Misconfigured: fail before any ssh runs.
        fails("by address: a name with no spec here fails, never by name", "nosuchhost", "has no nosuchhost/host.toml",
              by_address="1"),
        fails("by address: a name that is not a spec name fails", "../d06", "has no ../d06/host.toml", by_address="1"),
        fails("by address: 0 is not off, it fails", "d06", "must be 1 or unset", by_address="0"),
        fails("by address: set but empty fails", "d06", "must be 1 or unset", by_address=""),
        fails("key: set but empty fails", "d06", "BUILD_HOST_SSH_KEY is set but empty", key=""),
        fails("key: a missing file fails", "d06", "is not a file", key=str(D / "missing")),
        fails("known_hosts: set but empty fails", "d06", "BUILD_HOST_SSH_KNOWN_HOSTS is set but empty", known=""),
        fails("known_hosts: a missing file fails, for a node too", "root@vmh01", "is not a file", known=str(D / "missing")),
        fails("known_hosts: a path with a blank fails (ssh would read two files)", "d06", "a path with a blank",
              known=f"{KNOWN} /etc/ssh/ssh_known_hosts"),
        fails("key: a path with % fails (ssh would expand it)", "d06", "a path with a blank, %", key=f"{D}/%h"),
        ssh_passes_argv_case(),
        wait_ssh_case(),
        ssh_g_case(),
    ]
finally:
    env()
    os.environ.update(SAVED)
    shutil.rmtree(D, ignore_errors=True)
print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
