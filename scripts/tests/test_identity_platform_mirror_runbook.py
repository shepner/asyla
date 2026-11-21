#!/usr/bin/env python3
"""Offline test of d05/apps/identity-platform/README.md "Rebuild from the nas01 mirror (#1101)"
(stdlib unittest; asyla #1101).

    python3 scripts/tests/test_identity_platform_mirror_runbook.py

The runbook's commands must match what they drive: each app_switch.sh line's switch and VARs are
d05/host.toml's switch_env for identity-platform (credentials exec names and app_switch VARs
alike), the switches run in the order identity-platform.sh's header gives, and the build line
names build_host.py's CREDENTIALS, the app's pull token and start_env, and --confirm d05.
"""
from __future__ import annotations

import ast
import re
import shlex
import tomllib
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
README = REPO / "d05" / "apps" / "identity-platform" / "README.md"
HEADING = "## Rebuild from the nas01 mirror (#1101)"
ORDER = ["restore-mirror", "mirror-check", "leaf-issue", "leaf-schedule-install",
         "start-openldap", "start-keycloak", "configure", "cutover-done"]
CD = "cd ~/local/asyla && "

with open(REPO / "d05" / "host.toml", "rb") as f:
    APP = next(a for a in tomllib.load(f)["app"] if a["name"] == "identity-platform")


def build_host_credentials() -> list[str]:
    tree = ast.parse((REPO / "scripts" / "build_host.py").read_text())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "CREDENTIALS" for t in node.targets):
            return list(ast.literal_eval(node.value))
    raise AssertionError("no CREDENTIALS in build_host.py")


def section() -> str:
    text = README.read_text()
    assert text.count(HEADING) == 1, f"{HEADING!r} is not in the README exactly once"
    body = text.split(HEADING, 1)[1]
    m = re.search(r"^## ", body, re.M)
    return body[: m.start()] if m else body


def blocks(text: str) -> list[list[str]]:
    """The fenced blocks' non-empty lines, indentation stripped."""
    out, cur = [], None
    for line in text.splitlines():
        s = line.strip()
        if s == "```":
            if cur is None:
                cur = []
            else:
                out.append(cur)
                cur = None
        elif cur is not None and s:
            cur.append(s)
    assert cur is None, "an unclosed fence"
    return out


def parse(line: str) -> tuple[list[str], list[str]]:
    """(credentials exec names, the command after --), the leading cd removed."""
    assert line.startswith(CD), f"not the README's form ({CD!r}): {line}"
    words = shlex.split(line[len(CD):])
    if words[:3] == ["python3", "core/tools/credentials.py", "exec"]:
        i = words.index("--")
        return words[3:i], words[i + 1:]
    return [], words


def switch_of(cmd: list[str]) -> tuple[str, list[str]]:
    assert cmd[:3] == ["projects/asyla-hosts/scripts/app_switch.sh", "d05", "identity-platform"], cmd
    return cmd[3], cmd[4:]


class Runbook(unittest.TestCase):
    def setUp(self):
        self.blocks = blocks(section())
        self.assertGreaterEqual(len(self.blocks), 3, "the main block, the accept-age block, the proof")

    def test_order(self):
        main = self.blocks[0]
        got = [switch_of(parse(l)[1])[0] for l in main[1:]]
        self.assertEqual(got, ORDER)

    def test_switch_values_match_switch_env(self):
        lines = self.blocks[0][1:] + self.blocks[1]
        for line in lines:
            names, cmd = parse(line)
            sw, rest = switch_of(cmd)
            with self.subTest(switch=sw):
                self.assertIn(sw, APP["switch_env"])
                want = APP["switch_env"][sw]
                self.assertEqual(names, want, "credentials exec names")
                self.assertEqual(rest, want, "app_switch VARs (no ARG on this path)")

    def test_accept_age_block(self):
        self.assertEqual([switch_of(parse(l)[1])[0] for l in self.blocks[1]], ["restore-mirror-accept-age"])

    def test_build_line(self):
        names, cmd = parse(self.blocks[0][0])
        self.assertEqual(cmd, ["python3", "projects/asyla-hosts/scripts/build_host.py", "d05", "build",
                               "--apply", "--confirm", "d05"])
        want = build_host_credentials() + [APP["pull_token_env"]] + APP["start_env"]
        self.assertEqual(names, want)

    def test_proof_line(self):
        self.assertEqual(self.blocks[2], [
            "cd ~/local/asyla/projects/asyla-hosts && scripts/tests/test_identity_platform_mirror_restore_test01.sh"])
        self.assertTrue((REPO / "scripts/tests/test_identity_platform_mirror_restore_test01.sh").is_file())


if __name__ == "__main__":
    unittest.main()
