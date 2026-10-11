#!/usr/bin/env python3
"""Offline test of build_host.parse_args(): the parser accepts what the Usage block shows.

    python3 scripts/tests/test_build_host_args.py

`build_host.py HOST secrets push --apply VAR` (the documented order) was a usage error while
`--apply` before HOST worked. Tests the parser only: no action runs, and subprocess and urlopen
are replaced so that a call to a host or to GitLab would fail the test. Exit 0 when every case
passes.
"""
from __future__ import annotations

import contextlib
import io
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_host  # noqa: E402


def _no_contact(*a, **kw):
    raise AssertionError(f"the parser test reached out: {a[:1]}")


build_host.subprocess.run = _no_contact
build_host.urllib.request.urlopen = _no_contact

DEFAULTS = {"args": [], "apply": False, "start": None, "only": None, "recreate": False, "confirm": None}


def parse(line: str) -> dict | str:
    """The parsed namespace as a dict, or 'exit N' when argparse refuses the line."""
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            return vars(build_host.parse_args(line.split()))
    except SystemExit as e:
        return f"exit {e.code}: {err.getvalue().strip().splitlines()[-1] if err.getvalue().strip() else ''}"


def same(name: str, want: dict, *lines: str) -> bool:
    """Every line parses to `want` (over the defaults): the orders are equivalent."""
    want = {**DEFAULTS, **want}
    ok = True
    for line in lines:
        got = parse(line)
        good = got == want
        ok &= good
        print(f"{'ok  ' if good else 'FAIL'}  {name}: build_host.py {line}" + ("" if good else f"\n        got  {got}\n        want {want}"))
    return ok


def refused(name: str, line: str, needle: str) -> bool:
    got = parse(line)
    good = isinstance(got, str) and got.startswith("exit 2") and needle in got
    print(f"{'ok  ' if good else 'FAIL'}  {name}: build_host.py {line}" + ("" if good else f"\n        got  {got}"))
    return good


def documented(name: str, text: str) -> bool:
    good = text in build_host.__doc__
    print(f"{'ok  ' if good else 'FAIL'}  {name}: {text!r} in the Usage block")
    return good


results = [
    # The secrets line, with --apply before and after the VAR names.
    documented("usage", "build_host.py HOST secrets check|push|install [--apply] [VAR ...]"),
    same("secrets push, one VAR, applied",
         {"host": "d03", "action": "secrets", "args": ["push", "VAR_A"], "apply": True},
         "d03 secrets push --apply VAR_A",          # the documented order (refused before the fix)
         "d03 secrets push VAR_A --apply",
         "--apply d03 secrets push VAR_A",
         "d03 --apply secrets push VAR_A",
         "d03 secrets --apply push VAR_A"),
    same("secrets push, two VARs, applied",
         {"host": "d03", "action": "secrets", "args": ["push", "VAR_A", "VAR_B"], "apply": True},
         "d03 secrets push --apply VAR_A VAR_B",
         "d03 secrets push VAR_A VAR_B --apply",
         "d03 secrets push VAR_A --apply VAR_B",
         "--apply d03 secrets push VAR_A VAR_B"),
    same("secrets push, no VAR, applied",
         {"host": "d03", "action": "secrets", "args": ["push"], "apply": True},
         "d03 secrets push --apply",
         "--apply d03 secrets push"),
    same("secrets install, one VAR, applied",
         {"host": "d04", "action": "secrets", "args": ["install", "VAR_A"], "apply": True},
         "d04 secrets install --apply VAR_A",
         "d04 secrets install VAR_A --apply"),
    # Without --apply nothing turns it on, whatever the VAR names are.
    same("secrets check, one VAR, dry",
         {"host": "d03", "action": "secrets", "args": ["check", "VAR_A"]},
         "d03 secrets check VAR_A"),
    same("secrets push, no VAR, dry",
         {"host": "d03", "action": "secrets", "args": ["push"]},
         "d03 secrets push"),
    # The other Usage lines still parse as before.
    same("plan", {"host": "d04", "action": "plan"}, "d04 plan"),
    same("verify", {"host": "d04", "action": "verify"}, "d04 verify"),
    same("scripts-check", {"host": "d04", "action": "scripts-check"}, "d04 scripts-check"),
    same("token", {"host": "d04", "action": "token", "apply": True}, "d04 token --apply", "--apply d04 token"),
    same("build, dry", {"host": "d04", "action": "build"}, "d04 build"),
    same("build --recreate --apply",
         {"host": "d04", "action": "build", "recreate": True, "apply": True},
         "d04 build --recreate --apply",
         "d04 build --apply --recreate",
         "--recreate --apply d04 build"),
    same("build --from", {"host": "d04", "action": "build", "apply": True, "start": "setup"},
         "d04 build --apply --from setup"),
    same("build --only", {"host": "d04", "action": "build", "only": "verify"}, "d04 build --only verify"),
    same("build --recreate --confirm",
         {"host": "d03", "action": "build", "recreate": True, "confirm": "d03"},
         "d03 build --recreate --confirm d03"),
    same("destroy", {"host": "d04", "action": "destroy", "apply": True, "confirm": "d04"},
         "d04 destroy --apply --confirm d04"),
    # Still refused: the intermixed parser must not start accepting stray words.
    refused("a stray word after build", "d04 build apply", "build takes no further arguments: apply"),
    refused("a stray word after an option", "d04 build --only verify extra", "build takes no further arguments: extra"),
    refused("a stray word after destroy", "d04 destroy --apply d03", "destroy takes no further arguments: d03"),
    refused("an unknown option", "d03 secrets push --aply VAR_A", "unrecognized arguments: --aply"),
    refused("an unknown action", "d03 secret push", "invalid choice"),
    refused("an unknown phase", "d04 build --only nothing", "invalid choice"),
    refused("no action", "d04", "required"),
]
print("all cases passed" if all(results) else f"{results.count(False)} case(s) failed")
sys.exit(0 if all(results) else 1)
