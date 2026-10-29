#!/usr/bin/env python3
"""d01 home-assistant: the HVAC cold-spell report (packages/hvac.yaml, asyla/report_hvac_cycles.py).

    python3 scripts/tests/test_home_assistant_hvac.py

1. home-assistant.sh up and verify against stubs (docker, curl, stat): up installs packages/ and
   asyla/ as exact copies (folders 700, files 600), removes a file no longer shipped, keeps
   __pycache__; verify passes, then fails once the installed package is edited; up from a copy
   of the app folder without packages/ fails and leaves the installed files alone.
2. With docker and the image pinned in compose.yml present (docker pull it first), in that image
   with no network: Home Assistant's check_config accepts the installed config (it exits 0 even on
   errors, so its output is read), report_hvac_cycles.py --selftest passes on the image's python3,
   and the automation's templates render as intended (Jinja2 with stand-ins for now, states and
   strptime).
   Without them those cases say skip.
Nothing reaches a host, Home Assistant or Prometheus.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
APP = REPO / "d01" / "apps" / "home-assistant"
IMAGE = re.search(r"image:\s*(\S+)", (APP / "compose.yml").read_text()).group(1)
REAL_DOCKER = shutil.which("docker")

DOCKER_STUB = """#!/bin/bash
echo "docker $*" >> "$STUB_LOG"
case "$*" in
  *"config --images"*) echo img:1 ;;
  "network inspect -f"*) echo 172.31.240.0/24 ;;
  "inspect -f"*) echo healthy ;;
esac
exit 0
"""
CURL_STUB = "#!/bin/bash\necho 200\n"
# GNU stat -c %a on macOS too.
STAT_STUB = """#!/bin/bash
python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "${@: -1}"
"""


def image_present() -> bool:
    if not REAL_DOCKER:
        return False
    return subprocess.run([REAL_DOCKER, "image", "inspect", IMAGE], capture_output=True).returncode == 0


def in_image(cfg: Path, *args: str, stdin: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run([REAL_DOCKER, "run", "--rm", "-i", "--network", "none", "-v", f"{cfg}:/config",
                           "--entrypoint", "python3", IMAGE, *args],
                          input=stdin, capture_output=True, text=True, timeout=300)


class Stage:
    """A d01 home folder with backup_lib.sh, DOCKER_DL in a temp dir and stub commands."""

    def __init__(self, tmp: Path, app: Path = APP):
        self.tmp, self.app = tmp, app
        home, bindir = tmp / "home", tmp / "bin"
        (home / "scripts" / "docker").mkdir(parents=True)
        shutil.copy(REPO / "docker" / "backup_lib.sh", home / "scripts" / "docker")
        (home / "scripts" / "docker" / "common.env").write_text(f"DOCKER_DL={tmp}/dl\nDOCKER_D1={tmp}/d1\n")
        bindir.mkdir()
        for name, body in (("docker", DOCKER_STUB), ("curl", CURL_STUB), ("stat", STAT_STUB)):
            (bindir / name).write_text(body)
            (bindir / name).chmod(0o755)
        self.config = tmp / "dl" / "home-assistant" / "config"
        # An existing HA: up sets the proxy trust before the start and does not wait for a first start.
        (self.config / ".storage").mkdir(parents=True)
        (self.config / ".storage" / "http").write_text("{}")
        self.env = os.environ | {"HOME": str(home), "PATH": f"{bindir}:{os.environ['PATH']}",
                                 "STUB_LOG": str(tmp / "docker.log")}

    def run(self, *cmd: str) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", str(self.app / "home-assistant.sh"), *cmd], env=self.env,
                              capture_output=True, text=True, timeout=60)


def mode(p: Path) -> str:
    return format(p.stat().st_mode & 0o777, "o")


class UpAndVerify(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.s = Stage(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def test_up_installs_packages_and_scripts(self):
        r = self.s.run("up")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for rel in ("packages/hvac.yaml", "asyla/report_hvac_cycles.py", "configuration.yaml"):
            self.assertEqual((self.s.config / rel).read_bytes(), (APP / rel).read_bytes(), rel)
            self.assertEqual(mode(self.s.config / rel), "600", rel)
        for d in ("packages", "asyla"):
            self.assertEqual(mode(self.s.config / d), "700", d)
        self.assertIn("packages/ installed", r.stdout)

    def test_up_removes_unshipped_files_and_keeps_pycache(self):
        (self.s.config / "packages").mkdir()
        (self.s.config / "packages" / "old.yaml").write_text("sensor: []\n")
        (self.s.config / "asyla" / "__pycache__").mkdir(parents=True)
        (self.s.config / "asyla" / "__pycache__" / "x.pyc").write_text("")
        self.assertEqual(self.s.run("up").returncode, 0)
        self.assertFalse((self.s.config / "packages" / "old.yaml").exists())
        self.assertTrue((self.s.config / "asyla" / "__pycache__" / "x.pyc").exists())

    def test_verify_compares_installed_trees(self):
        self.assertEqual(self.s.run("up").returncode, 0)
        r = self.s.run("verify")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("packages/ matches the repo", r.stdout)
        self.assertIn("asyla/ matches the repo", r.stdout)
        with open(self.s.config / "packages" / "hvac.yaml", "a") as f:
            f.write("# edited on the host\n")
        r = self.s.run("verify")
        self.assertEqual(r.returncode, 1)
        self.assertIn("packages/ differs from the repo", r.stdout)

    def test_up_fails_when_a_tree_is_missing(self):
        self.assertEqual(self.s.run("up").returncode, 0)
        before = {p: p.read_bytes() for p in self.s.config.rglob("*") if p.is_file()}
        app = self.s.tmp / "app"
        shutil.copytree(APP, app, ignore=lambda d, names: ["packages"] if Path(d) == APP else [])
        log = self.s.tmp / "docker.log"
        log.write_text("")
        self.s.app = app
        r = self.s.run("up")
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"[ERROR] {app}/packages missing", r.stderr)
        self.assertNotIn("packages/ installed", r.stdout)
        self.assertNotIn("up -d", log.read_text())
        after = {p: p.read_bytes() for p in self.s.config.rglob("*") if p.is_file()}
        self.assertEqual(after, before)


TEMPLATES = r'''
import datetime as dt, sys, yaml
from jinja2.sandbox import ImmutableSandboxedEnvironment
from homeassistant.helpers import config_validation as cv
pkg = yaml.safe_load(open("/config/packages/hvac.yaml"))
auto = pkg["automation"][0]
ENTITY = "input_datetime.hvac_cold_spell_report_last_success"
helper = pkg["input_datetime"][ENTITY.split(".")[1]]
cond = [c for c in auto["conditions"] if c["condition"] == "template"][0]["value_template"]
acts = auto["actions"]
body = [a for a in acts if "variables" in a][0]["variables"]["body"]
tz = dt.timezone(dt.timedelta(hours=-6))
env = ImmutableSandboxedEnvironment()  # Home Assistant's TemplateEnvironment is one
def strptime(s, fmt, default):  # as Home Assistant's: the default on a string that does not parse
    try:
        return dt.datetime.strptime(s, fmt)
    except (ValueError, AttributeError, TypeError):
        return default
# The state as input_datetime writes it (has_date and has_time): local "%Y-%m-%d %H:%M:%S".
def gate(now, state):
    g = {"now": lambda: now, "strptime": strptime,
         "states": lambda e: state if e == ENTITY else "unknown"}
    return env.from_string(cond).render(**g).strip()
now = dt.datetime(2026, 12, 8, 9, 0, 0, 100000, tzinfo=tz)
fmt = lambda d: d.strftime("%Y-%m-%d %H:%M:%S")
cases = [
    ("helper: date and time, no initial (restored at start)",
     (helper.get("has_date"), helper.get("has_time"), "initial" in helper), (True, True, False)),
    ("unknown", gate(now, "unknown"), "True"),
    ("unavailable", gate(now, "unavailable"), "True"),
    ("never set (today 00:00:00, input_datetime's start value)", gate(now, "2026-12-08 00:00:00"), "True"),
    ("6 days ago", gate(now, fmt(now - dt.timedelta(days=6))), "False"),
    ("yesterday", gate(now, fmt(now - dt.timedelta(days=1))), "False"),
    ("today", gate(now, "2026-12-08 09:00:00"), "False"),
    ("7 days ago, 0.2 s later in the day", gate(now, fmt(now - dt.timedelta(days=7) + dt.timedelta(seconds=0.2))), "True"),
    ("7 days ago at 23:30 local", gate(now, "2026-12-01 23:30:00"), "True"),
    ("6 days ago at 23:30 local", gate(now, "2026-12-02 23:30:00"), "False"),
]
# Right after the shell_command: set the helper only on success, in an `if` that does not end the run.
shell = [i for i, a in enumerate(acts) if a.get("action") == "shell_command.hvac_cycle_report"][0]
step = acts[shell + 1]
ok_if = step["if"][0]["value_template"]
then = step["then"][0]
r = lambda **kw: env.from_string(ok_if).render(**kw).strip()
cases += [
    ("set step follows the shell_command", (list(step), then["action"], then["target"]["entity_id"]),
     (["if", "then"], "input_datetime.set_datetime", ENTITY)),
    ("notifications are not inside the if", [a.get("action") for a in acts[shell + 2:] if "action" in a],
     ["persistent_notification.create", "notify.send_message"]),
    ("set: report ok", r(report={"returncode": 0, "stdout": "x", "stderr": ""}), "True"),
    ("set: report failed", r(report={"returncode": 2, "stdout": "", "stderr": "[ERROR] x"}), "False"),
    ("set: no response", r(), "False"),
    ("set: datetime is now(), valid for the service",
     cv.datetime(env.from_string(then["data"]["datetime"]).render(now=lambda: now)), now),
]
r = lambda **kw: env.from_string(body).render(**kw).strip()
cases += [
    ("body: report", r(report={"returncode": 0, "stdout": "HVAC runs ...", "stderr": ""}), "HVAC runs ..."),
    ("body: failed", r(report={"returncode": 2, "stdout": "", "stderr": "[ERROR] query failed"}),
     "report_hvac_cycles.py failed (exit 2): [ERROR] query failed"),
    ("body: no response", r()[:40], "report_hvac_cycles.py did not finish (sh"),
]
bad = 0
for name, got, want in cases:
    ok = got == want
    bad += not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": got {got!r}, want {want!r}"))
sys.exit(1 if bad else 0)
'''


@unittest.skipUnless(image_present(), f"needs docker and {IMAGE} (docker pull it)")
class InPinnedImage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        s = Stage(Path(cls._tmp.name))
        r = s.run("up")
        assert r.returncode == 0, r.stdout + r.stderr
        cls.cfg = s.config
        shutil.rmtree(cls.cfg / ".storage")  # check_config needs none; keep it like a fresh install

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def test_check_config_accepts_it(self):
        r = in_image(self.cfg, "-m", "homeassistant", "--script", "check_config", "-c", "/config", "--info", "all")
        out = re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr)
        self.assertEqual(r.returncode, 0, out)
        self.assertNotRegex(out, r"Incorrect config|Failed config|Invalid config|Error", out)
        for want in ("platform: statistics", "state_characteristic: value_min", "id: asyla_hvac_cold_spell_report",
                     "hvac_cycle_report: python3 /config/asyla/report_hvac_cycles.py --days 7",
                     "- sensor.mke_temperature_24_h_minimum", "- notify.hvac_report", "- 09:00:00",
                     "hvac_cold_spell_report_last_success:", "input_datetime.set_datetime"):
            self.assertIn(want, out)

    def test_report_selftest_on_image_python(self):
        r = in_image(self.cfg, "/config/asyla/report_hvac_cycles.py", "--selftest")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("FAIL", r.stdout)

    def test_templates(self):
        r = in_image(self.cfg, "-", stdin=TEMPLATES)
        print(r.stdout, end="")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_statistics_entity_id_is_the_one_the_conditions_read(self):
        # Home Assistant names the entity from `name` (slugified) on its first registration.
        r = in_image(self.cfg, "-c", "import yaml; from homeassistant.util import slugify; "
                     "print(slugify(yaml.safe_load(open('/config/packages/hvac.yaml'))['sensor'][0]['name']))")
        self.assertEqual(r.stdout.strip(), "mke_temperature_24_h_minimum", r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
