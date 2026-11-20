#!/usr/bin/env python3
"""Offline test of verify's [[external]] lines and of which updater each host runs (the d03
cutover's two verify FAILs, 2026-10-17).

    python3 scripts/tests/test_build_host_externals.py

1. verify_externals(): an entry with `check` runs it on the host and is OK on exit 0, FAIL
   otherwise; a `manual` entry without one is a note, never a FAIL; a run-only entry prints
   nothing. load_spec() refuses a `check` that is not a shell command; d03's dead-man entry has one.
   An entry's env (d06's proxy key): load_spec checks the names, the pre-flight checks they are set
   before any phase (names only), and the external phase refuses one unset.
2. Every host that is not in LEGACY_HOSTS and has an update_scripts.sh runs test01's updater: its
   lines, comments aside, are test01's, so the build files (build_only_paths) are removed after
   the copy, and the GitLab credential comes on stdin (test_update_scripts_stdin_auth.py; d01-d03
   read a token file until 2026-10-27). d03's own updater copied the whole tree, so its verify
   failed "no build files on the host". scripts/tests/test_update_scripts_build_files_test01.sh runs that updater on test01.

Nothing reaches GitLab or a host: ssh is a stub here, and subprocess and urlopen are replaced so
that a stray call fails the test. Exit 0 when every case passes.
"""
from __future__ import annotations

import contextlib
import io
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_host  # noqa: E402


def _no_contact(*a, **kw):
    raise AssertionError(f"the test reached out: {a[:1]}")


build_host.subprocess.run = _no_contact
build_host.urllib.request.urlopen = _no_contact
results: list[bool] = []


def check(name: str, good: bool, detail: str = "") -> None:
    print(f"{'ok  ' if good else 'FAIL'}  {name}{': ' + detail if detail and not good else ''}")
    results.append(good)


def run_verify_externals(externals: list[dict], exits: dict[str, int]) -> tuple[list, list[str], str]:
    """verify_externals() with ssh stubbed: EXITS maps a check command to its exit code. Returns
    the (label, ok) lines, the commands sent to the host and the printed output."""
    lines, sent = [], []

    def fake_ssh(host, command, **kw):
        sent.append(command)
        return subprocess.CompletedProcess([], exits[command], "", "")

    real, build_host.ssh = build_host.ssh, fake_ssh
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            build_host.verify_externals({"host": "d09", "external": externals},
                                        lambda label, ok, detail="": lines.append((label, ok)))
    finally:
        build_host.ssh = real
    return lines, sent, out.getvalue()


# 1. verify_externals
RUN = {"name": "internal-access", "repo": "~/x", "run": ["scripts/deploy-host.sh {host}"]}
MANUAL = {"name": "deadman", "repo": "~/y", "manual": "install-it.sh"}
CMD = "systemctl is-active --quiet deadman.timer"

lines, sent, out = run_verify_externals([RUN, MANUAL], {})
check("a manual external without check is a note, not a FAIL", lines == [] and "[NOTE] external deadman" in out,
      f"{lines} {out!r}")
check("a run-only external sends nothing to the host", sent == [], str(sent))

lines, sent, out = run_verify_externals([{**MANUAL, "check": CMD}], {CMD: 0})
check("a check that exits 0 is OK", lines == [(f"external deadman: {CMD}", True)] and sent == [CMD], f"{lines} {sent}")
check("a checked external prints no note", "[NOTE]" not in out, out)

lines, _, _ = run_verify_externals([{**MANUAL, "check": CMD}], {CMD: 3})
check("a check that exits non-zero is a FAIL", lines == [(f"external deadman: {CMD}", False)], str(lines))

VM = ('[vm]\nnode = "vmh01"\nvmid = 999\nsockets = 1\ncores = 1\nmemory_mb = 1024\nip = "10.0.0.250/24"\n'
      'os_disk = { storage = "local-data2", size = "8G" }\ncloudinit_storage = "local-data2"\n')


def load(external: str) -> str:
    """load_spec() of a host d09 whose spec is VM + EXTERNAL: 'ok' or the Fail message."""
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)
        (d / "d09").mkdir()
        (d / "d09" / "host.toml").write_text(VM + external)
        real, build_host.REPO = build_host.REPO, d
        try:
            build_host.load_spec("d09")
            return "ok"
        except build_host.Fail as e:
            return str(e)
        finally:
            build_host.REPO = real


EXT = '[[external]]\nname = "deadman"\nrepo = "~/y"\nmanual = "install-it.sh"\n'
check("load_spec takes a manual external with a check", load(EXT + f'check = "{CMD}"\n') == "ok")
for bad in ('check = ""\n', 'check = "  "\n', "check = 1\n", 'check = ["a"]\n'):
    msg = load(EXT + bad)
    check(f"load_spec refuses {bad.strip()}", "check must be a shell command" in msg, msg)

# An external's env: distinct variable names; the pre-flight checks them before any phase (names
# only), and the external phase refuses one that is unset.
RUNX = '[[external]]\nname = "proxy"\nrepo = "~/y"\nrun = ["true"]\n'
check("load_spec takes an external env list", load(RUNX + 'env = ["D09_CF_API_TOKEN"]\n') == "ok")
for bad in ('env = "D09_X"\n', 'env = ["lower"]\n', 'env = ["A", "A"]\n'):
    msg = load(RUNX + bad)
    check(f"load_spec refuses {bad.strip()}", "env must be a list of distinct" in msg, msg)

spec = {"host": "d09", "app": [{"name": "t", "pull_token_env": "P_TOK", "start_env": ["S_ONE"]}],
        "external": [{"name": "proxy", "repo": "~/y", "run": ["true"], "env": ["E_KEY"]}]}
names = lambda phases, s=spec: [n for n, _ in build_host.env_needed(s, phases)]
check("a full build needs the pull token, start_env and the external's env",
      names(list(build_host.PHASES)) == ["P_TOK", "S_ONE", "E_KEY"], str(names(list(build_host.PHASES))))
check("--only setup needs none", names(["setup"]) == [])
check("--only external needs only the external's", names(["external"]) == ["E_KEY"])
check("a replica's apps need no start_env", names(["apps"], {**spec, "replica": {"of": "d06"}}) == ["P_TOK"])


def preflight(env: dict, apply: bool) -> str:
    """preflight_env() for a full build of SPEC with ENV as the environment: printed output, or the Fail."""
    real = dict(build_host.os.environ)
    build_host.os.environ.clear()
    build_host.os.environ.update(env)
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            build_host.preflight_env(spec, list(build_host.PHASES), apply)
        return out.getvalue()
    except build_host.Fail as e:
        return "FAIL " + str(e)
    finally:
        build_host.os.environ.clear()
        build_host.os.environ.update(real)


VAL = "stand-in"
out = preflight({"P_TOK": VAL, "S_ONE": VAL}, True)
check("the pre-flight stops an applied build that lacks one, naming it",
      out.startswith("FAIL") and "E_KEY" in out and VAL not in out, out)
out = preflight({"P_TOK": VAL, "S_ONE": VAL, "E_KEY": VAL}, True)
check("the pre-flight passes with all set and prints no value", "MISSING" not in out and VAL not in out, out)
out = preflight({}, False)
check("a dry run lists what is missing and does not stop", "MISSING" in out and not out.startswith("FAIL"), out)

real_env = dict(build_host.os.environ)
build_host.os.environ.pop("E_KEY", None)
try:
    with contextlib.redirect_stdout(io.StringIO()):
        build_host.phase_external(spec, True)
    msg = "ran"
except build_host.Fail as e:
    msg = str(e)
finally:
    build_host.os.environ.clear()
    build_host.os.environ.update(real_env)
check("the external phase refuses an unset env value before running anything",
      "E_KEY is not in the environment" in msg, msg)

d06 = build_host.load_spec("d06")
check("d06's proxy takes D06_CF_API_TOKEN at use and d06 keeps no secret file",
      [e.get("env") for e in d06["external"]] == [["D06_CF_API_TOKEN"]] and not d06.get("secret"), str(d06.get("secret")))

d03 = build_host.load_spec("d03")
dm = next((e for e in d03.get("external", []) if e["name"] == "theorg-mini-deadman"), {})
check("d03's theorg-mini-deadman is checked by verify (its timer)",
      "theorg-mini-deadman.timer" in dm.get("check", ""), str(dm))

# 2. updaters
def code(path: Path) -> list[str]:
    """The script's lines without comment-only lines (they name the host)."""
    return [l for l in path.read_text().splitlines() if not l.lstrip().startswith("#")]


want = code(build_host.REPO / "test01" / "update_scripts.sh")
check("test01's updater removes the build files",
      any("/setup\" \"${TARGET_SCRIPTS:?}/${tree:?}/host.toml\"" in l for l in want)
      and any("docker/setup\"" in l for l in want))


hosts = sorted(p.parent.name for p in build_host.REPO.glob("*/update_scripts.sh")
               if p.parent.name not in build_host.LEGACY_HOSTS and (p.parent / "host.toml").is_file())
check("d03 is among the hosts with the new-host updater", "d03" in hosts, str(hosts))
check("d01, d02 and d03 are among them", {"d01", "d02", "d03"} <= set(hosts), str(hosts))
for h in hosts:
    have = code(build_host.REPO / h / "update_scripts.sh")
    diff = [l for l in have if l not in want] + [l for l in want if l not in have]
    check(f"{h}/update_scripts.sh is test01's (comments aside)", have == want, f"{diff[:3]}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
