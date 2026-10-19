#!/usr/bin/env python3
"""Offline test of the host-maintenance key set of a host spec (gap G11): [host_maintenance] in
load_spec(), the setup phase's call of build/setup/host_maintenance_keys.sh, that script run by
local bash against a temporary home (a fake ssh-keyscan on PATH), and verify's lines, whose host
command runs by local bash against the same folder (fake getent and GNU-style stat on PATH). The
optional self_address (the host's own key, read on the host) with its own host key file.

    python3 scripts/tests/test_build_host_maintenance_keys.py

Nothing reaches GitLab or a host: subprocess and urlopen are replaced so that a stray call fails
the test. Every key here is made by ssh-keygen in a temporary folder when the test runs; none is
committed. Exit 0 when every case passes.
"""
from __future__ import annotations

import atexit
import contextlib
import grp
import io
import os
import pwd
import shlex
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_host  # noqa: E402


def _no_contact(*a, **kw):
    raise AssertionError(f"the test reached out: {a[:1]}")


REAL_RUN = build_host.subprocess.run   # local bash and ssh-keygen only
build_host.subprocess.run = _no_contact
build_host.urllib.request.urlopen = _no_contact
results: list[bool] = []


def check(name: str, good: bool, detail: str = "") -> None:
    print(f"{'ok  ' if good else 'FAIL'}  {name}{': ' + detail if detail and not good else ''}")
    results.append(good)


VM = ('[vm]\nnode = "vmh01"\nvmid = 999\nsockets = 1\ncores = 1\nmemory_mb = 1024\nip = "10.0.0.250/24"\n'
      'os_disk = { storage = "local-data2", size = "8G" }\ncloudinit_storage = "local-data2"\n')
IDENT = "/home/docker/.config/host-maintenance/ssh/id_ed25519"
ENTRY = '[[secret]]\nvar = "D09_HM"\npath = "{path}"\nowner = "{owner}"\nmode = "{mode}"\n'
PIN_A = "10.0.0.60 ssh-ed25519 " + "A" * 68
PIN_B = "10.0.0.61 ssh-ed25519 " + "B" * 68


def table(identity: str = IDENT, user: str = "docker", pins: list[str] | None = None, extra: str = "") -> str:
    pins = [PIN_A, PIN_B] if pins is None else pins
    return (f'[host_maintenance]\nidentity = "{identity}"\nuser = "{user}"\nknown_hosts = '
            + "[" + ", ".join(f'"{p}"' for p in pins) + "]\n" + extra)


def load(text: str, host: str = "d09") -> dict:
    d = Path(tempfile.mkdtemp(prefix="build-host-hm-"))
    (d / host).mkdir()
    (d / host / "host.toml").write_text(VM + text)
    real, build_host.REPO = build_host.REPO, d
    try:
        return build_host.load_spec(host)
    finally:
        build_host.REPO = real


def spec_ok(name: str, text: str) -> dict | None:
    try:
        s = load(text)
        check(f"spec accepted: {name}", True)
        return s
    except build_host.Fail as e:
        check(f"spec accepted: {name}", False, str(e))
        return None


def spec_refused(name: str, text: str, needle: str) -> None:
    try:
        load(text)
        got = "accepted"
    except build_host.Fail as e:
        got = str(e)
    check(f"spec refused: {name}", needle in got, got)


# ---------------------------------------------------------------- the spec

sec = ENTRY.format(path=IDENT, owner="docker:docker", mode="600")
s = spec_ok("identity of a [[secret]], a user, two pins", sec + table())
check("its owner is the secret's", s is not None and build_host.hm_owner(s) == "docker:docker")
spec_ok("no [host_maintenance]", sec)
spec_refused("identity of no [[secret]]", table(), "path of one [[secret]]")
spec_refused("identity of a [[secret]] with mode 644", ENTRY.format(path=IDENT, owner="docker:docker", mode="644")
             + table(), "mode 600")
spec_refused("identity under /mnt/docker/", ENTRY.format(path="/mnt/docker/x/id", owner="docker:docker", mode="600")
             + table(identity="/mnt/docker/x/id"), "installed after the setup phase")
spec_refused("a relative identity", table(identity="ssh/id"), "absolute path")
spec_refused("an identity with ..", table(identity="/home/docker/../root/id"), "absolute path")
spec_refused("an identity with a shell character", table(identity="/home/docker/a;b"), "absolute path")
spec_refused("a user with a space", sec + table(user="do cker"), "user name")
spec_refused("no pins", sec + table(pins=[]), "known_hosts must be")
spec_refused("a pin of another key type", sec + table(pins=["10.0.0.60 ssh-rsa " + "A" * 68]), "known_hosts must be")
spec_refused("a pin with a comment", sec + table(pins=[PIN_A + " d01"]), "known_hosts must be")
spec_refused("a pin with a shell character", sec + table(pins=["10.0.0.60;x ssh-ed25519 " + "A" * 68]),
             "known_hosts must be")
spec_refused("an address pinned twice", sec + table(pins=[PIN_A, PIN_A]), "twice")
spec_refused("an unknown key in the table", sec + table(extra='hosts = ["d01"]\n'), "nothing else")
spec_refused("no user", sec + table().replace('user = "docker"\n', ""), "nothing else")
spec_refused("a bad secret owner", ENTRY.format(path=IDENT, owner="docker", mode="600") + table(), "USER:GROUP")
SELF = 'self_address = "10.0.0.250"\n'   # VM's ip
s_self = spec_ok("self_address, the host's own [vm] ip, not pinned", sec + table(extra=SELF))
spec_refused("self_address also pinned", sec + table(pins=[PIN_A, "10.0.0.250 ssh-ed25519 " + "C" * 68], extra=SELF),
             "also pinned")
spec_refused("self_address another host's ip", sec + table(extra='self_address = "10.0.0.62"\n'), "own [vm] ip")
spec_refused("self_address not a string", sec + table(extra="self_address = 1\n"), "own [vm] ip")

def test01_spec() -> dict:
    """test01's spec. While test01 rehearses a production host ([replica], e.g. gap G1), the hello
    spec as committed at 226904e instead, so these cases keep a spec with the tables they test."""
    t = build_host.load_spec("test01")
    if not t.get("replica"):
        return t
    text = REAL_RUN(["git", "-C", str(build_host.REPO), "show", "226904e:test01/host.toml"],
                    capture_output=True, text=True, check=True).stdout
    d = Path(tempfile.mkdtemp(prefix="build-host-test01-"))
    (d / "test01").mkdir()
    (d / "test01" / "host.toml").write_text(text)
    (d / "build").symlink_to(build_host.REPO / "build")
    real, build_host.REPO = build_host.REPO, d
    try:
        return build_host.load_spec("test01")
    finally:
        build_host.REPO = real


t = test01_spec()
hm = t.get("host_maintenance", {})
check("test01: the identity is TEST01_HOST_MAINTENANCE_SSH_KEY's path, user docker, d01 to d03 pinned",
      [x["var"] for x in t["secret"] if x["path"] == hm.get("identity")] == ["TEST01_HOST_MAINTENANCE_SSH_KEY"]
      and hm.get("user") == "docker"
      and [p.split()[0] for p in hm.get("known_hosts", [])] == ["10.0.0.60", "10.0.0.61", "10.0.0.62"])
check("test01: its own key at its address 10.0.0.69 (self_address; the hello spec of 226904e has none)",
      bool(build_host.load_spec("test01").get("replica")) or hm.get("self_address") == "10.0.0.69", str(hm))
check("no legacy spec has [host_maintenance] (none is left)",
      not any(build_host.load_spec(h).get("host_maintenance") for h in build_host.LEGACY_HOSTS
              if (build_host.REPO / h / "host.toml").is_file()))
d03 = build_host.load_spec("d03")
d03_hm = d03.get("host_maintenance", {})
check("d03: the interim key set: D03_HOST_MAINTENANCE_SSH_KEY's path, user docker, d01, d02, d04, d06, ns02, ns01 pinned, "
      "its own key at 10.0.0.62",
      [x["var"] for x in d03["secret"] if x["path"] == d03_hm.get("identity")] == ["D03_HOST_MAINTENANCE_SSH_KEY"]
      and d03_hm.get("user") == "docker"
      and [p.split()[0] for p in d03_hm.get("known_hosts", [])] == ["10.0.0.60", "10.0.0.61", "10.0.0.63", "10.0.0.65", "10.0.0.11", "10.0.0.10"]
      and d03_hm.get("self_address") == "10.0.0.62"
      and not any(e.get("name") == "host-maintenance key set" for e in d03.get("external", [])), str(d03_hm))
# test01's own spec, a replica included (it keeps test01's key set): the hello spec of 226904e pins old keys.
check("d03 and test01 pin d01 and d02 alike", d03_hm.get("known_hosts", [])[:2]
      == build_host.load_spec("test01").get("host_maintenance", {}).get("known_hosts", [])[:2])


# ---------------------------------------------------------------- the setup phase

def setup_calls(spec: dict, apply: bool) -> tuple[list[tuple], str]:
    calls = []
    real = build_host.build_step
    build_host.build_step = lambda host, script, args="": calls.append((host, script, args))
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            build_host.phase_setup(spec, apply)
    finally:
        build_host.build_step = real
    return calls, out.getvalue()


calls, out = setup_calls(t, False)
check("setup dry run: names the key set step, runs nothing", not calls and build_host.HM_SCRIPT in out, out)
calls, out = setup_calls(t, True)
check("setup: the key set step runs after the spec's steps, from build/setup/",
      [c[1] for c in calls] == t["setup"]["steps"] + [build_host.HM_SCRIPT] and calls[-1][0] == "test01", str(calls))
calls, out = setup_calls(s, True)
check("setup: no [setup] steps, the key set step alone", [c[1] for c in calls] == [build_host.HM_SCRIPT], str(calls))
calls, out = setup_calls(load(sec), True)
check("setup: no [host_maintenance], no key set step", calls == [], str(calls))
calls, out = setup_calls(s_self, False)
check("setup dry run with self_address: names the own key and its address",
      not calls and "own key (/etc/ssh/ssh_host_ed25519_key.pub) as 10.0.0.250" in out, out)


def plan_text(sp: dict) -> str:
    out = io.StringIO()
    real, build_host.find_vm = build_host.find_vm, lambda vmid: None
    try:
        with contextlib.redirect_stdout(out):
            build_host.plan(sp)
    finally:
        build_host.find_vm = real
    return out.getvalue()


check("plan: the key set line names the pins and the own key's address",
      "known_hosts: 10.0.0.60, 10.0.0.61; own key as 10.0.0.250, read on the host)" in plan_text(s_self), plan_text(s_self))
check("plan: without self_address, the pins only",
      "known_hosts: 10.0.0.60, 10.0.0.61), authorized for docker" in plan_text(s), plan_text(s))
check("the script is in build/setup/, outside what the updaters install (HOST/, docker/)",
      (build_host.REPO / build_host.BUILD_SETUP / build_host.HM_SCRIPT).is_file())


# ---------------------------------------------------------------- the script, local bash

SCRIPT = build_host.REPO / build_host.BUILD_SETUP / build_host.HM_SCRIPT
ME = pwd.getpwuid(os.getuid()).pw_name
MYGROUP = grp.getgrgid(os.getgid()).gr_name
work = Path(tempfile.mkdtemp(prefix="hm-keys-")).resolve()
atexit.register(shutil.rmtree, work, True)   # the keys made for the test go with it


def keygen(name: str, comment: str) -> Path:
    f = work / "keys" / name
    f.parent.mkdir(exist_ok=True)
    REAL_RUN(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", str(f)], check=True)
    return f


def pub_of(f: Path) -> str:
    return (f.parent / (f.name + ".pub")).read_text().strip()


ident_src = keygen("ident", "host-maintenance@test")
pins = [f"10.0.0.{60 + i} " + " ".join(pub_of(keygen(f"host{i}", "h")).split()[:2]) for i in range(3)]
other_user_key = pub_of(keygen("other", "docker@workstation"))

home = work / "home"
keydir = home / ".config" / "host-maintenance" / "ssh"
ident = keydir / "id_ed25519"
spec_path = work / "host.toml"
scan_file = work / "scan"
(work / "bin").mkdir()
(work / "bin" / "ssh-keyscan").write_text("""#!/bin/bash
for a; do :; done
awk -v a="$a" '$1 == a' "$FAKE_SCAN"
""")
(work / "bin" / "getent").write_text(f"""#!/bin/bash
[ "$1" = passwd ] && [ "$2" = {shlex.quote(ME)} ] && echo "{ME}:x:1:1::{home}:/bin/bash"
""")
(work / "bin" / "stat").write_text("""#!/usr/bin/env python3
import grp, os, pwd, sys
# GNU stat -c '%a %U:%G' FILE, as verify's host command uses it.
st = os.stat(sys.argv[-1])
print(f"{st.st_mode & 0o7777:o} {pwd.getpwuid(st.st_uid).pw_name}:{grp.getgrgid(st.st_gid).gr_name}")
""")
for f in (work / "bin").iterdir():
    f.chmod(0o755)
ENV = {**os.environ, "PATH": f"{work / 'bin'}:{os.environ['PATH']}", "FAKE_SCAN": str(scan_file),
       "HOST_SPEC": str(spec_path), "HOST_MAINTENANCE_HOME": str(home)}


def write_spec(pinned: list[str], extra: str = "") -> dict:
    text = (ENTRY.format(path=ident, owner=f"{ME}:{MYGROUP}", mode="600")
            + table(identity=str(ident), user=ME, pins=pinned, extra=extra))
    spec_path.write_text(VM + text)
    sp = load(text)
    sp["host"] = "d09"
    return sp


def install_identity() -> None:
    """What the secrets phase does: the private key at its path, mode 600."""
    keydir.mkdir(parents=True, exist_ok=True)
    ident.write_bytes(ident_src.read_bytes())
    ident.chmod(0o600)


def run_script(scan: list[str]) -> tuple[int, str]:
    scan_file.write_text("".join(l + "\n" for l in scan))
    r = REAL_RUN(["bash", str(SCRIPT)], capture_output=True, text=True, env=ENV, timeout=120)
    return r.returncode, r.stdout + r.stderr


def mode(p: Path) -> str:
    return f"{p.stat().st_mode & 0o777:o}"


def secret_shown(out: str) -> bool:
    body = [l for l in ident_src.read_text().splitlines() if l and not l.startswith("-")]
    return "PRIVATE" in out or any(l in out for l in body)


auth = home / ".ssh" / "authorized_keys"
auth.parent.mkdir(parents=True)
auth.write_text(other_user_key + "\n")
spec = write_spec(pins)
install_identity()
keydir.chmod(0o755)
rc, out = run_script(pins)
want_pub = " ".join(REAL_RUN(["ssh-keygen", "-y", "-f", str(ident_src)], capture_output=True, text=True).stdout.split())
check("script: exit 0", rc == 0, out)
check("script: the .pub is ssh-keygen -y of the key, comment kept",
      pub_of(ident) == want_pub and pub_of(ident).endswith(" host-maintenance@test"), pub_of(ident))
check("script: known_hosts is the pins, in spec order", (keydir / "known_hosts").read_text() == "".join(p + "\n" for p in pins))
check("script: key dir 700, key 600, .pub and known_hosts 644",
      [mode(p) for p in (keydir, ident, keydir / "id_ed25519.pub", keydir / "known_hosts")] == ["700", "600", "644", "644"],
      str([mode(p) for p in (keydir, ident, keydir / "id_ed25519.pub", keydir / "known_hosts")]))
lines = auth.read_text().splitlines()
check("script: authorized_keys keeps the other key and adds this one, marked",
      lines == [other_user_key, f"{want_pub} {build_host.HM_MARK}"], str(lines))
check("script: ~/.ssh and authorized_keys 700 and 600", mode(auth.parent) == "700" and mode(auth) == "600")
check("script: each pin is checked", out.count("host key matches its pin") == 3, out)
check("script: the private key is never printed", not secret_shown(out))
first = auth.read_text()

rc, out = run_script(pins)
check("script: a second run changes nothing", rc == 0 and auth.read_text() == first
      and (keydir / "known_hosts").read_text() == "".join(p + "\n" for p in pins), out)

auth.write_text(other_user_key + "\n" + want_pub + "\n")
rc, out = run_script(pins)
check("script: an unmarked line of the same key (as d03 has) is replaced, not doubled",
      rc == 0 and auth.read_text() == first, auth.read_text())


# ---------------------------------------------------------------- verify's lines, local bash

def verify_lines(sp: dict) -> list[str]:
    lines: list[str] = []

    class R:
        returncode = 0
        stdout = ""

    def fake_ssh(target, command, **kw):
        assert command.startswith("sudo bash -c "), command
        r = REAL_RUN(["bash", "-c", shlex.split(command)[3]], capture_output=True, text=True, env=ENV, timeout=60)
        R.stdout = r.stdout
        return R

    real = build_host.ssh
    build_host.ssh = fake_ssh
    try:
        build_host.verify_host_maintenance(sp, lambda label, ok, detail="": lines.append(
            f"[{'OK' if ok else 'FAIL'}] {label}: {detail}"))
    finally:
        build_host.ssh = real
    return lines


def fails_on(lines: list[str], needle: str) -> bool:
    return any(l.startswith("[FAIL]") and needle in l for l in lines)


v = verify_lines(spec)
check("verify: after the script, four OK lines", len(v) == 4 and all(l.startswith("[OK]") for l in v), "\n".join(v))
check("verify: the private key is never printed", not secret_shown("\n".join(v)))
check("verify: no [host_maintenance], no line", verify_lines(load(sec.replace(IDENT, "/home/docker/x")))
      == [])

pubf = keydir / "id_ed25519.pub"
saved = pubf.read_text()
pubf.write_text(other_user_key + "\n")
check("verify: a .pub of another key fails", fails_on(verify_lines(spec), "is ssh-keygen -y of the key"))
pubf.write_text(saved)
keydir.chmod(0o755)
check("verify: a key dir of mode 755 fails", fails_on(verify_lines(spec), "key dir 700"))
keydir.chmod(0o700)
auth.write_text(first + first.splitlines()[-1] + "\n")
check("verify: the key in authorized_keys twice fails", fails_on(verify_lines(spec), "once, marked"))
auth.write_text(other_user_key + "\n" + want_pub + "\n")
check("verify: the key unmarked fails", fails_on(verify_lines(spec), "once, marked"))
auth.write_text(other_user_key + "\n")
check("verify: the key missing from authorized_keys fails", fails_on(verify_lines(spec), "once, marked"))
auth.write_text(first)
check("verify: known_hosts other than the pins fails", fails_on(verify_lines(write_spec(pins[:2])), "pinned list"))
spec = write_spec(pins)
check("verify: back in order, all OK", all(l.startswith("[OK]") for l in verify_lines(spec)))


# ---------------------------------------------------------------- self_address: the host's own key

hostkey = keygen("ssh_host_ed25519_key", "root@d09")
hostkey_pub = hostkey.parent / (hostkey.name + ".pub")
ENV["HOST_MAINTENANCE_HOST_KEY"] = str(hostkey_pub)
build_host.HM_HOST_KEY = str(hostkey_pub)   # verify's host command reads it here
self_line = "10.0.0.250 " + " ".join(pub_of(hostkey).split()[:2])
spec_self = write_spec(pins, SELF)
rc, out = run_script(pins + [self_line])
check("script with self_address: exit 0", rc == 0, out)
check("script with self_address: known_hosts is the pins, then the own key at the address",
      (keydir / "known_hosts").read_text() == "".join(p + "\n" for p in pins + [self_line]),
      (keydir / "known_hosts").read_text())
check("script with self_address: the own key is scanned too", out.count("host key matches its pin") == 4
      and "then this host's own as 10.0.0.250" in out, out)
v = verify_lines(spec_self)
check("verify with self_address: four OK lines, the last names the own key",
      len(v) == 4 and all(l.startswith("[OK]") for l in v) and "own key as 10.0.0.250" in v[-1], "\n".join(v))
check("verify with self_address: a spec without it fails on the extra line",
      fails_on(verify_lines(spec), "pinned list"))
(keydir / "known_hosts").write_text("".join(p + "\n" for p in pins))
check("verify with self_address: known_hosts without the own key fails", fails_on(verify_lines(spec_self), "own key"))
rc, out = run_script(pins + [self_line])
saved = hostkey_pub.read_text()
hostkey_pub.write_text(pub_of(keygen("rebuilt", "root@d09")) + "\n")
check("verify with self_address: a host key other than known_hosts' line fails", fails_on(verify_lines(spec_self), "own key"))
hostkey_pub.unlink()
check("verify with self_address: no host key file fails, named",
      fails_on(verify_lines(spec_self), "no ed25519 key in"))
rc, out = run_script(pins + [self_line])
check("script with self_address: no host key file fails", rc == 1 and "does not read" in out, out)
hostkey_pub.write_text("ssh-rsa " + "A" * 68 + " root@d09\n")
rc, out = run_script(pins + [self_line])
check("script with self_address: a host key file of another type fails", rc == 1 and "not an ed25519 public key" in out, out)
hostkey_pub.write_text(saved)
rc, out = run_script(pins)
check("script with self_address: the own address not answering fails", rc == 1 and "10.0.0.250: no ed25519 host key" in out, out)
spec_path.write_text(VM + ENTRY.format(path=ident, owner=f"{ME}:{MYGROUP}", mode="600")
                     + table(identity=str(ident), user=ME, pins=pins + [self_line], extra=SELF))
rc, out = run_script(pins + [self_line])
check("script: a self_address that is also pinned is refused", rc == 1 and "self_address must be" in out, out)
spec = write_spec(pins)
rc, out = run_script(pins)
check("script without self_address again: known_hosts the pins only",
      rc == 0 and (keydir / "known_hosts").read_text() == "".join(p + "\n" for p in pins), out)


# ---------------------------------------------------------------- the pins checked against the scan

rc, out = run_script([pins[0], pins[1], pins[2].rsplit(" ", 1)[0] + " " + pub_of(keygen("intruder", "x")).split()[1]])
check("script: a host offering another key fails, named", rc == 1 and "10.0.0.62 offers another host key" in out, out)
check("script: known_hosts still holds the pins, not the scan",
      (keydir / "known_hosts").read_text() == "".join(p + "\n" for p in pins))
rc, out = run_script(pins[:2])
check("script: a pinned host that does not answer fails", rc == 1 and "10.0.0.62: no ed25519 host key" in out, out)
ident.unlink()
rc, out = run_script(pins)
check("script: no private key installed fails", rc == 1 and "is missing" in out, out)
r = REAL_RUN(["bash", str(SCRIPT)], capture_output=True, text=True,
             env={k: v for k, v in ENV.items() if k != "HOST_MAINTENANCE_HOME"}, timeout=60)
check("script: refused when not root (outside the test)", os.getuid() == 0 or (r.returncode == 1 and "run as root" in r.stderr),
      r.stderr)

print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
