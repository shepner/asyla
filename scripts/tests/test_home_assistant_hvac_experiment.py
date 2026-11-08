#!/usr/bin/env python3
"""d01 home-assistant: the HVAC winter experiment (packages/hvac_experiment.yaml).

    python3 scripts/tests/test_home_assistant_hvac_experiment.py

1. home-assistant.sh up and verify against stubs (as test_home_assistant_hvac.py): up installs
   packages/hvac_experiment.yaml as an exact copy (600); verify passes, then fails once it is edited.
2. The night rule in Python (no Home Assistant): the night date is (now - 9 h).date(), a heat pump
   night (-15) every even day from 2026-11-12, a gas night (65) every odd one, through 2027-03-31;
   across 2027-01-01 and the 2027-03-14 DST change. The comfort trigger's rule against the fixture.
3. Static checks on the package (PyYAML with Home Assistant's tags tolerated; on this machine's
   python3 when it has PyYAML, else in the pinned image): the entity ids, one number.set_value and
   only in script.hvac_experiment_set_lockout, the allowed values exactly -15, 30, 35, 65, every
   switching automation gated on input_boolean.hvac_experiment_stop, no notify, the dates and times.
4. With docker and the image pinned in compose.yml present (docker pull it first), in that image
   with no network: check_config accepts the installed config; then one boot of Home Assistant with
   the package alone (Home Assistant's own loader, template engine and automations; a stand-in
   number.set_value that reads the value back as the Ecobee poll would; dt_util.now replaced by a
   fixed local time; the event loop's clock moved on for delays and holds). The night variables and
   the morning window rendered at the same datetimes as 2; the comfort trigger rendered against the
   2026-11-06/07 night and made-up minutes; then each automation and script end to end.
   Without docker and the image, 4 says skip (and 3 too when this python3 has no PyYAML).
Nothing reaches a host, Home Assistant or the Ecobee.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_home_assistant_hvac import APP, IMAGE, Stage, image_present, in_image, mode  # noqa: E402

PACKAGE = "packages/hvac_experiment.yaml"
TZ = ZoneInfo("America/Chicago")
FIRST_NIGHT, LAST_NIGHT = dt.date(2026, 11, 12), dt.date(2027, 3, 31)


def night(t: dt.datetime) -> tuple[int, bool, int]:
    """(days since the first night, in the window, value by parity) for local time t: a night runs
    21:00-08:59 and carries its evening's date. Written without the package's timedelta(hours=9), so
    the two can be compared."""
    nd = t.date() if t.hour >= 9 else t.date() - dt.timedelta(days=1)
    day = (nd - FIRST_NIGHT).days
    return day, 0 <= day <= (LAST_NIGHT - FIRST_NIGHT).days, -15 if day % 2 == 0 else 65


# (local time, days since 2026-11-12, in the window, value). Shared by the Python rule and the render
# in the image.
NIGHT_CASES = [
    ("2026-11-12T08:59", -1, False, 65),    # the night before the first one: outside
    ("2026-11-12T21:00", 0, True, -15),     # first night: heat pump
    ("2026-11-13T03:00", 0, True, -15),     # same night
    ("2026-11-13T08:59", 0, True, -15),
    ("2026-11-13T21:00", 1, True, 65),      # gas night
    ("2026-11-14T03:00", 1, True, 65),
    ("2026-12-31T21:00", 49, True, 65),     # across 2027-01-01
    ("2027-01-01T03:00", 49, True, 65),
    ("2027-01-01T21:00", 50, True, -15),
    ("2027-01-02T03:00", 50, True, -15),
    ("2027-03-13T21:00", 121, True, 65),    # the 2027-03-14 02:00 DST change falls in this night
    ("2027-03-14T03:00", 121, True, 65),
    ("2027-03-14T08:59", 121, True, 65),
    ("2027-03-14T21:00", 122, True, -15),
    ("2027-03-15T03:00", 122, True, -15),
    ("2027-03-31T21:00", 139, True, 65),    # last night
    ("2027-04-01T03:00", 139, True, 65),
    ("2027-04-01T21:00", 140, False, -15),  # outside the window
]
# 09:00 runs: (local time, inside 2026-11-13..2027-04-01).
MORNING_CASES = [("2026-11-12T09:00", False), ("2026-11-13T09:00", True), ("2027-01-01T09:00", True),
                 ("2027-04-01T09:00", True), ("2027-04-02T09:00", False)]

# The comfort trigger against the night of 2026-11-06/07, from the cached trends minutes
# (copcurve/frame.pkl, preset from ha_preset.json, the asyla-home-assistant job). The cache has no
# sensor.mke_inside_temperature, so "inside" here is the mean of the five Ecobee room sensors
# (frame tin); the mode is heat (not off, the furnace or heat pump ran). 07:03 (a target interpolated
# between 65 and 71) is left out. Then made-up minutes.
# (label, hvac mode, preset, target °F, inside °F, trigger true)
FIXTURE = [
    ("11-06 21:00 sleep 65", "heat", "sleep", 65.0, 68.9, False),
    ("11-07 01:00 sleep 65", "heat", "sleep", 65.0, 66.9, False),
    ("11-07 05:30 sleep 65, coldest minute", "heat", "sleep", 65.0, 66.7, False),
    ("11-07 06:30 sleep 65", "heat", "sleep", 65.0, 67.1, False),
    ("11-07 07:00 sleep 65, warming before the preset changes", "heat", "sleep", 65.0, 70.4, False),
    ("11-07 07:04 recovery: Morning 71", "heat", "Morning", 71.0, 70.7, False),
    ("11-07 07:30 recovery: Morning 71", "heat", "Morning", 71.0, 69.6, False),
    ("11-07 08:30 Morning 71", "heat", "Morning", 71.0, 70.7, False),
    ("made up: recovery 3.5 °F below Morning 71", "heat", "Morning", 71.0, 67.5, False),
    ("made up: 3 °F below a sleep 65", "heat", "sleep", 65.0, 62.0, True),
    ("made up: exactly 2 °F below a sleep 65", "heat", "sleep", 65.0, 63.0, False),
    ("made up: 3 °F below, mode off", "off", "sleep", 65.0, 62.0, False),
    ("made up: inside unavailable", "heat", "sleep", 65.0, "unavailable", False),
    ("made up: no target", "heat", "sleep", None, 62.0, False),
]


class UpAndVerify(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.s = Stage(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def test_up_installs_and_verify_compares_the_package(self):
        r = self.s.run("up")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.s.config / PACKAGE).read_bytes(), (APP / PACKAGE).read_bytes())
        self.assertEqual(mode(self.s.config / PACKAGE), "600")
        r = self.s.run("verify")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("packages/ matches the repo", r.stdout)
        with open(self.s.config / PACKAGE, "a") as f:
            f.write("# edited on the host\n")
        r = self.s.run("verify")
        self.assertEqual(r.returncode, 1)
        self.assertIn("packages/ differs from the repo", r.stdout)


class NightRuleInPython(unittest.TestCase):
    def test_cases(self):
        for iso, *want in NIGHT_CASES:
            t = dt.datetime.fromisoformat(iso).replace(tzinfo=TZ)
            self.assertEqual(night(t), tuple(want), iso)

    def test_the_package_formula_agrees_every_15_min_through_the_winter(self):
        # (now - 9 h).date() on an aware local time, as the template does, against night(): every
        # real local time (stepped in UTC, so the DST change gives no missing or doubled hour).
        t = dt.datetime(2026, 11, 11, 12, 0, tzinfo=dt.UTC)
        n = 0
        while t < dt.datetime(2027, 4, 3, tzinfo=dt.UTC):
            loc = t.astimezone(TZ)
            day = ((loc - dt.timedelta(hours=9)).date() - FIRST_NIGHT).days
            self.assertEqual(day, night(loc)[0], loc.isoformat())
            t += dt.timedelta(minutes=15)
            n += 1
        self.assertGreater(n, 13000)

    def test_comfort_rule_on_the_fixture(self):
        def rule(mode_, preset, target, inside):
            num = lambda v: isinstance(v, (int, float))
            return mode_ == "heat" and preset == "sleep" and num(target) and num(inside) and inside < target - 2
        for label, *row, want in FIXTURE:
            self.assertEqual(rule(*row), want, label)


STATIC = r'''
import re, sys, yaml

class Loader(yaml.SafeLoader):
    pass
# Home Assistant's tags (!secret, !include, !input, ...) read as None.
Loader.add_multi_constructor("!", lambda loader, suffix, node: None)
PKG = yaml.load(open(sys.argv[1], encoding="utf-8").read(), Loader=Loader)

E = "number.downstairs_hallway_compressor_minimum_temperature"
STOP, TESTED, COMFORT = ("input_boolean.hvac_experiment_" + n for n in ("stop", "write_tested", "comfort_stopped"))
SET = "script.hvac_experiment_set_lockout"
STOP_OFF = {"condition": "state", "entity_id": STOP, "state": "off"}

def walk(x, at=()):
    yield at, x
    if isinstance(x, dict):
        for k, v in x.items():
            yield from walk(v, at + (k,))
    elif isinstance(x, list):
        for i, v in enumerate(x):
            yield from walk(v, at + (i,))
nodes = list(walk(PKG))
dicts = [(at, v) for at, v in nodes if isinstance(v, dict)]
strings = [v for _, v in nodes if isinstance(v, str)] + [str(k) for _, d in dicts for k in d]
A = {a["id"]: a for a in PKG["automation"]}
S = PKG["script"]
cases = []
def check(name, got, want):
    cases.append((name, got, want))

# --- entity ids ----------------------------------------------------------------------------------
ids = {m for s in strings for m in re.findall(r"\b(?:number|climate|sensor|weather|input_boolean|script)\.[a-z0-9_]+", s)}
ids -= {"number.set_value", "input_boolean.turn_on", "input_boolean.turn_off"}
check("entity ids", ids, {E, "climate.downstairs_hallway", "sensor.mke_inside_temperature", "weather.downstairs_hallway",
                          STOP, TESTED, COMFORT, SET, "script.hvac_experiment_write_test",
                          "sensor.hvac_experiment_lockout", "sensor.ecobee_outdoor_feed_temperature"})
check("helpers: three, no initial (restored)", (sorted(PKG["input_boolean"]), [("initial" in h) for h in PKG["input_boolean"].values()]),
      (["hvac_experiment_comfort_stopped", "hvac_experiment_stop", "hvac_experiment_write_tested"], [False] * 3))
check("stop helper name", PKG["input_boolean"]["hvac_experiment_stop"]["name"], "HVAC experiment stop")
check("top-level keys", sorted(PKG), ["automation", "input_boolean", "script", "template"])

# --- the only write ------------------------------------------------------------------------------
actions = [(at, d["action"]) for at, d in dicts if "action" in d]
check("one number.set_value, in the set-lockout script", [at for at, a in actions if a == "number.set_value"],
      [("script", "hvac_experiment_set_lockout", "sequence", 1)])
check("set_value targets the lockout", S["hvac_experiment_set_lockout"]["sequence"][1]["target"], {"entity_id": E})
check("actions used", {a for _, a in actions},
      {"number.set_value", SET, "script.hvac_experiment_write_test", "input_boolean.turn_on", "input_boolean.turn_off"})
check("no legacy service: key", [at for at, d in dicts if "service" in d], [])
check("helpers written: only write_tested and comfort_stopped",
      {d["target"]["entity_id"] for _, d in dicts if d.get("action", "").startswith("input_boolean.")}, {TESTED, COMFORT})
check("no notify anywhere", [s for s in strings if "notif" in s.lower()], [])

# --- allowed values ------------------------------------------------------------------------------
seq = S["hvac_experiment_set_lockout"]["sequence"]
guard = seq[0]["value_template"]
check("set-lockout: mode queued, guard first", (S["hvac_experiment_set_lockout"]["mode"], seq[0]["condition"]), ("queued", "template"))
allowed = {int(x) for x in re.search(r"v in \[([^\]]*)\]", guard).group(1).split(",")}
check("allowed values", allowed, {-15, 30, 35, 65})
check("guard: the entity in °F", f"is_state_attr('{E}', 'unit_of_measurement', '°F')" in guard, True)
passed = [d["data"]["value"] for _, d in dicts if d.get("action") == SET]
check("values passed: literal", {v for v in passed if isinstance(v, int)}, {30, 35})
check("values passed: template", {v for v in passed if not isinstance(v, int)}, {"{{ night_value }}"})
nightv = A["asyla_hvac_experiment_night"]["variables"]
m = re.fullmatch(r"\{\{ (-?\d+) if night_day % 2 == 0 else (-?\d+) \}\}", nightv["night_value"])
check("night values: -15 even, 65 odd", m and (int(m.group(1)), int(m.group(2))), (-15, 65))

# --- the stop gate -------------------------------------------------------------------------------
for i in ("night", "morning", "comfort_stop", "write_test_fallback"):
    check(f"{i}: gated on the stop", STOP_OFF in A["asyla_hvac_experiment_" + i]["conditions"], True)
start = A["asyla_hvac_experiment_start"]
choose = [s for s in start["actions"] if "choose" in s][0]["choose"]
check("start: write test and night options gated, the 35 one not", [STOP_OFF in o["conditions"] for o in choose], [True, True, False])
check("start: the ungated option only sets 35", choose[2]["sequence"], [{"action": SET, "data": {"value": 35}}])
check("start: night option needs the comfort flag off",
      {"condition": "state", "entity_id": COMFORT, "state": "off"} in choose[1]["conditions"], True)
check("stop: on, sets 35", (A["asyla_hvac_experiment_stop"]["triggers"], A["asyla_hvac_experiment_stop"]["actions"]),
      ([{"trigger": "state", "entity_id": STOP, "to": "on"}], [{"action": SET, "data": {"value": 35}}]))

# --- dates and times -----------------------------------------------------------------------------
check("all dates", sorted({d for s in strings for d in re.findall(r"20\d\d-\d\d-\d\d", s)}),
      ["2026-11-12", "2026-11-13", "2027-03-31", "2027-04-01"])
check("night: 21:00", A["asyla_hvac_experiment_night"]["triggers"], [{"trigger": "time", "at": "21:00:00"}])
check("night date is now - 9 h, from 2026-11-12", nightv["night_day"].strip(),
      "{{ ((now() - timedelta(hours=9)).date() - strptime('2026-11-12', '%Y-%m-%d').date()).days }}")
check("window to 2027-03-31", re.findall(r"\d{4}-\d\d-\d\d", nightv["night_in_window"]), ["2027-03-31", "2026-11-12"])
check("night: clear the comfort flag, then set", [a["action"] for a in A["asyla_hvac_experiment_night"]["actions"]],
      ["input_boolean.turn_off", SET])
mo = A["asyla_hvac_experiment_morning"]
check("morning: 09:00, 2026-11-13..2027-04-01", (mo["triggers"], re.findall(r"\d{4}-\d\d-\d\d", mo["conditions"][1]["value_template"])),
      ([{"trigger": "time", "at": "09:00:00"}], ["2026-11-13", "2027-04-01"]))
check("morning: set 35, clear the comfort flag", [(a["action"], a.get("data")) for a in mo["actions"]],
      [(SET, {"value": 35}), ("input_boolean.turn_off", None)])
check("start: on homeassistant start, 3 min, then the night variables again",
      (start["triggers"], start["actions"][0], start["actions"][1]),
      ([{"trigger": "homeassistant", "event": "start"}], {"delay": "00:03:00"}, {"variables": nightv}))
times = lambda o: [(c.get("after"), c.get("before")) for c in o["conditions"] if c["condition"] == "time"]
check("start: write test 09:15-20:45, night 21:00-09:00", (times(choose[0]), times(choose[1])),
      ([("09:15:00", "20:45:00")], [("21:00:00", "09:00:00")]))
check("start: options run the write test, the night value, 35",
      [o["sequence"] for o in choose[:2]],
      [[{"action": "script.hvac_experiment_write_test"}], [{"action": SET, "data": {"value": "{{ night_value }}"}}]])
check("fallback: 12:00, only when not done", (A["asyla_hvac_experiment_write_test_fallback"]["triggers"],
      {"condition": "state", "entity_id": TESTED, "state": "off"} in A["asyla_hvac_experiment_write_test_fallback"]["conditions"]),
      ([{"trigger": "time", "at": "12:00:00"}], True))
co = A["asyla_hvac_experiment_comfort_stop"]
tr = co["triggers"][0]
check("comfort: template held 30 min", (tr["trigger"], tr["for"]), ("template", "00:30:00"))
for part in ("is_state(c, 'heat')", "is_state_attr(c, 'preset_mode', 'sleep')", "inside < target - 2",
             "state_attr(c, 'temperature') | float(none)", "states('sensor.mke_inside_temperature') | float(none)"):
    check(f"comfort trigger has {part}", part in tr["value_template"], True)
check("comfort: only when the lockout reads -15", co["conditions"][1]["value_template"],
      "{{ states('%s') | float(none) == -15 }}" % E)
check("comfort: set 35, flag on", [(a["action"], a.get("data")) for a in co["actions"]], [(SET, {"value": 35}), ("input_boolean.turn_on", None)])
wt = S["hvac_experiment_write_test"]
check("write test: mode single", wt["mode"], "single")
check("write test: steps", [next(k for k in s if k in ("action", "wait_template", "delay")) and
                            (s.get("action"), s.get("data", {}).get("value"), s.get("timeout"), s.get("continue_on_timeout"), s.get("delay"))
                            for s in wt["sequence"]],
      [(SET, 30, None, None, None), (None, None, "00:05:00", True, None), (None, None, None, None, "00:02:00"),
       (SET, 35, None, None, None), (None, None, "00:05:00", True, None), ("input_boolean.turn_on", None, None, None, None)])
check("write test: waits read the lockout", [s["wait_template"] for s in wt["sequence"] if "wait_template" in s],
      ["{{ states('%s') | float(none) == %d }}" % (E, v) for v in (30, 35)])

# --- template sensors ----------------------------------------------------------------------------
sens = PKG["template"][0]["sensor"]
check("sensors", [(s["name"], s["default_entity_id"], s["unit_of_measurement"], s["device_class"], s["state_class"], "availability" in s) for s in sens],
      [("HVAC experiment lockout", "sensor.hvac_experiment_lockout", "°F", "temperature", "measurement", True),
       ("Ecobee outdoor feed temperature", "sensor.ecobee_outdoor_feed_temperature", "°F", "temperature", "measurement", True)])
check("outdoor sensor reads the weather entity's temperature", "state_attr(w, 'temperature')" in sens[1]["state"], True)

bad = 0
for name, got, want in cases:
    ok = got == want
    bad += not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": got {got!r}, want {want!r}"))
print(f"static: {bad} failed of {len(cases)}")
sys.exit(1 if bad else 0)
'''


def host_has_yaml() -> bool:
    return importlib.util.find_spec("yaml") is not None


@unittest.skipUnless(host_has_yaml() or image_present(), f"needs PyYAML here, or docker and {IMAGE}")
class Static(unittest.TestCase):
    def test_static(self):
        if host_has_yaml():
            r = subprocess.run([sys.executable, "-", str(APP / PACKAGE)], input=STATIC, capture_output=True,
                               text=True, timeout=60)
        else:
            with tempfile.TemporaryDirectory() as tmp:
                (Path(tmp) / "packages").mkdir()
                shutil.copy(APP / PACKAGE, Path(tmp) / PACKAGE)
                r = in_image(Path(tmp), "-", f"/config/{PACKAGE}", stdin=STATIC)
        print(r.stdout, end="")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr[-3000:])
        self.assertIn("static: 0 failed", r.stdout)


@unittest.skipUnless(image_present(), f"needs docker and {IMAGE} (docker pull it)")
class CheckConfig(unittest.TestCase):
    def test_check_config_accepts_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = Stage(Path(tmp))
            r = s.run("up")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            shutil.rmtree(s.config / ".storage", ignore_errors=True)
            r = in_image(s.config, "-m", "homeassistant", "--script", "check_config", "-c", "/config", "--info", "all")
        out = re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr)
        self.assertEqual(r.returncode, 0, out)
        self.assertNotRegex(out, r"Incorrect config|Failed config|Invalid config|Error")
        for want in ("id: asyla_hvac_experiment_night", "id: asyla_hvac_experiment_morning",
                     "id: asyla_hvac_experiment_comfort_stop", "id: asyla_hvac_experiment_stop",
                     "id: asyla_hvac_experiment_start", "id: asyla_hvac_experiment_write_test_fallback",
                     "hvac_experiment_set_lockout:", "hvac_experiment_write_test:", "hvac_experiment_stop:",
                     "- number.downstairs_hallway_compressor_minimum_temperature"):
            self.assertIn(want, out)


LIVE = r'''
import asyncio, datetime as dt, json, sys
from zoneinfo import ZoneInfo
from homeassistant import bootstrap, runner
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.template import Template
from homeassistant.util import dt as dt_util
from homeassistant.util.yaml import load_yaml

TZ = ZoneInfo("America/Chicago")
E = "number.downstairs_hallway_compressor_minimum_temperature"
CLIMATE, INSIDE, WEATHER = "climate.downstairs_hallway", "sensor.mke_inside_temperature", "weather.downstairs_hallway"
STOP, TESTED, COMFORT = ("input_boolean.hvac_experiment_" + n for n in ("stop", "write_tested", "comfort_stopped"))
LOCKOUT, OUTDOOR = "sensor.hvac_experiment_lockout", "sensor.ecobee_outdoor_feed_temperature"
F = {"unit_of_measurement": "°F"}
NIGHT_CASES, MORNING_CASES, FIXTURE = json.loads(r"""@DATA@""")
PKG = load_yaml("/config/packages/hvac_experiment.yaml")   # Home Assistant's own loader (the YAML alias)
AUTO = {a["id"]: a for a in PKG["automation"]}

bad = []
def check(name, got, want):
    bad.extend([] if got == want else [name])
    print(("ok   " if got == want else "FAIL ") + name + ("" if got == want else f": got {got!r}, want {want!r}"), flush=True)

# Local time as Home Assistant reads it (templates' now(), time conditions): dt_util.now, replaced.
NOW = [dt.datetime(2026, 11, 12, 22, 0, tzinfo=TZ)]
def at(iso):
    NOW[0] = dt.datetime.fromisoformat(iso).replace(tzinfo=TZ)

async def main():
    loop = asyncio.get_running_loop()
    real, skew = loop.time, [0.0]
    loop.time = lambda: real() + skew[0]
    async def skip(minutes):
        skew[0] += minutes * 60
        for _ in range(10):
            await asyncio.sleep(0.05)
    hass = await bootstrap.async_setup_hass(runner.RuntimeConfig(config_dir="/config", skip_pip=True))
    dt_util.now = lambda time_zone=None: NOW[0]
    st = lambda e: hass.states.get(e).state if hass.states.get(e) else None

    # --- 1. the night variables and the morning window, rendered at fixed local times ------------
    nv = cv.SCRIPT_VARIABLES_SCHEMA(dict(AUTO["asyla_hvac_experiment_night"]["variables"]))
    for iso, day, inw, val in NIGHT_CASES:
        at(iso)
        r = nv.async_render(hass, {})
        check(f"render night {iso}: day {day}, in window {inw}, value {val}",
              (r["night_day"], r["night_in_window"], r["night_value"]), (day, inw, val))
    mt = AUTO["asyla_hvac_experiment_morning"]["conditions"][1]["value_template"]
    for iso, want in MORNING_CASES:
        at(iso)
        check(f"render morning window {iso}: {want}", Template(mt, hass).async_render(), want)

    # --- 2. the comfort trigger against the fixture -----------------------------------------------
    trig = AUTO["asyla_hvac_experiment_comfort_stop"]["triggers"][0]["value_template"]
    for label, hmode, preset, target, inside, want in FIXTURE:
        hass.states.async_set(CLIMATE, hmode, {"preset_mode": preset, "temperature": target})
        hass.states.async_set(INSIDE, str(inside), F)
        check(f"comfort trigger, {label}: {want}", Template(trig, hass).async_render(), want)

    # --- 3. the boot ----------------------------------------------------------------------------
    calls, ids, readback, unit = [], set(), [True], ["°F"]
    def lockout(v, u="°F"):
        hass.states.async_set(E, v, {"unit_of_measurement": u, "min": -25, "max": 66, "step": 5} if u else {})
    async def set_value(call):  # stands in for the Ecobee number; with readback, its next poll at once
        e = call.data.get("entity_id")
        ids.add(e if isinstance(e, str) else tuple(e))
        calls.append(call.data["value"])
        if readback[0]:
            lockout(str(float(call.data["value"])), unit[0])
    hass.services.async_register("number", "set_value", set_value)
    def took():
        out = calls[:]
        calls.clear()
        return out
    autos = {s.attributes.get("id"): s.entity_id for s in hass.states.async_all("automation")}
    async def fire(aid):  # automation.trigger with its conditions; not blocking (the start run waits 3 min)
        await hass.services.async_call("automation", "trigger", {"entity_id": autos[aid], "skip_condition": False})
        await skip(0)
    async def boolean(e, on):
        await hass.services.async_call("input_boolean", "turn_on" if on else "turn_off", {"entity_id": e}, blocking=True)
    async def inside(v):
        hass.states.async_set(INSIDE, v, F)
        await skip(0)

    lockout("35.0")
    hass.states.async_set(CLIMATE, "heat", {"preset_mode": "home", "temperature": 68})
    hass.states.async_set(INSIDE, "68.0", F)
    hass.states.async_set(WEATHER, "cloudy", {"temperature": 28, "temperature_unit": "°F"})
    at("2026-11-12T22:00")
    await hass.async_start()
    await skip(0)
    check("automations loaded", sorted(autos), sorted(AUTO))
    check("helpers start off", (st(STOP), st(TESTED), st(COMFORT)), ("off", "off", "off"))
    check("start: nothing before 3 min", took(), [])
    await skip(3.1)
    check("start 3 min later, 11-12 22:00 (heat pump night, write test not due at night): -15", took(), [-15])
    check("lockout sensor follows the read-back setting", st(LOCKOUT), "-15.0")
    check("outdoor feed sensor, 28 °F", st(OUTDOOR), "28.0")

    # comfort stop on a heat pump night
    hass.states.async_set(CLIMATE, "heat", {"preset_mode": "sleep", "temperature": 65})
    await inside("64.0"); await skip(31)
    check("comfort: 1 °F below sleep 65 for 31 min: nothing", (took(), st(COMFORT)), ([], "off"))
    await inside("62.0"); await skip(29)
    check("comfort: 3 °F below for 29 min: nothing yet", took(), [])
    await skip(2)
    check("comfort: 3 °F below for 31 min, lockout -15: 35, flag on", (took(), st(COMFORT)), ([35], "on"))
    await inside("66.0")
    at("2026-11-13T02:00")
    await fire("asyla_hvac_experiment_start"); await skip(3.1)
    check("start after a comfort stop, same night: stays 35", took(), [])
    # comfort on a gas night: the lockout reads 65
    lockout("65.0"); await boolean(COMFORT, False)
    await inside("62.0"); await skip(31)
    check("comfort: 3 °F below for 31 min, lockout 65 (gas night): nothing", (took(), st(COMFORT)), ([], "off"))
    await inside("66.0")

    # night, at 21:00, by date (the comfort flag set first, to see it cleared)
    for iso, want in (("2026-11-12T21:00", [-15]), ("2026-11-13T21:00", [65]), ("2027-01-01T21:00", [-15]),
                      ("2027-03-14T21:00", [-15]), ("2027-03-31T21:00", [65]), ("2027-04-01T21:00", []),
                      ("2026-11-11T21:00", [])):
        await boolean(COMFORT, True); at(iso)
        await fire("asyla_hvac_experiment_night")
        check(f"night {iso}: {want}, comfort flag {'cleared' if want else 'kept'}", (took(), st(COMFORT)),
              (want, "off" if want else "on"))
    # morning, at 09:00
    for iso, want in (("2026-11-13T09:00", [35]), ("2027-04-01T09:00", [35]), ("2026-11-12T09:00", []),
                      ("2027-04-02T09:00", [])):
        await boolean(COMFORT, True); lockout("-15.0"); at(iso)
        await fire("asyla_hvac_experiment_morning")
        check(f"morning {iso}: {want}", (took(), st(COMFORT)), (want, "off" if want else "on"))

    # the stop
    lockout("-15.0"); await boolean(COMFORT, False)
    await boolean(STOP, True); await skip(0)
    check("stop on: 35", took(), [35])
    lockout("-15.0")
    at("2026-11-12T21:00"); await fire("asyla_hvac_experiment_night")
    at("2026-11-13T09:00"); await fire("asyla_hvac_experiment_morning")
    check("stopped: night and morning write nothing", took(), [])
    await inside("62.0"); await skip(31)
    check("stopped: comfort writes nothing", (took(), st(COMFORT)), ([], "off"))
    await inside("66.0")
    at("2026-11-13T12:00"); await fire("asyla_hvac_experiment_write_test_fallback"); await skip(8)
    check("stopped: no write test at 12:00", (took(), st(TESTED)), ([], "off"))
    at("2026-11-12T23:00"); await fire("asyla_hvac_experiment_start"); await skip(3.1)
    check("stopped, start on a heat pump night reading -15: 35 only", took(), [35])
    await boolean(STOP, False); await skip(0)
    check("stop off: writes nothing by itself", took(), [])

    # the set-lockout script on its own
    lockout("35.0")
    for v, want in ((40, []), (66, []), (-25, []), (30.5, []), ("abc", []), (None, []), (-15, [-15]),
                    ("65", [65]), (30, [30]), (35.0, [35])):
        await hass.services.async_call("script", "hvac_experiment_set_lockout", {"value": v}, blocking=True)
        check(f"set-lockout {v!r}: {want}", took(), want)
    unit[0] = "°C"; lockout("2.0", "°C")
    await hass.services.async_call("script", "hvac_experiment_set_lockout", {"value": 35}, blocking=True)
    check("set-lockout 35 with the entity in °C: nothing", took(), [])
    unit[0] = "°F"; lockout("35.0")

    # the write test: from the 12:00 fallback, read back at once
    at("2026-11-13T12:00"); await fire("asyla_hvac_experiment_write_test_fallback")
    check("write test: 30 first", (took(), st(TESTED)), ([30], "off"))
    await skip(1.9)
    check("write test: nothing more within 2 min", took(), [])
    await skip(0.3)
    check("write test: 35 after 2 min, done", (took(), st(TESTED)), ([35], "on"))
    # no read-back: each wait runs out at 5 min, and it is still marked done
    readback[0] = False; await boolean(TESTED, False)
    await hass.services.async_call("script", "turn_on", {"entity_id": "script.hvac_experiment_write_test"}); await skip(0)
    check("write test, no read-back: 30", took(), [30])
    await skip(6.9)
    check("write test, no read-back: still waiting at 6.9 min", took(), [])
    await skip(5.6)
    check("write test, no read-back: then 35, and done by 12.5 min", (took(), st(TESTED)), ([35], "on"))
    readback[0] = True

    # the start, by day
    await boolean(TESTED, False); lockout("35.0"); at("2026-11-13T13:00")
    await fire("asyla_hvac_experiment_start"); await skip(3.1)
    check("start 13:00, write test due: 30", took(), [30])
    await skip(2.2)
    check("start 13:00: then 35, done", (took(), st(TESTED)), ([35], "on"))
    # Unavailable: the start asks for 35, the set-lockout guard writes nothing (no unit to check).
    for state_, want in (("65.0", [35]), ("30.0", [35]), ("35.0", []), ("unavailable", [])):
        lockout(state_) if state_ != "unavailable" else lockout("unavailable", None)
        await fire("asyla_hvac_experiment_start"); await skip(3.1)
        check(f"start 13:00, write test done, reading {state_}: {want}", took(), want)
    lockout("35.0"); at("2026-11-13T22:00")
    await fire("asyla_hvac_experiment_start"); await skip(3.1)
    check("start 11-13 22:00 (gas night): 65", took(), [65])
    lockout("35.0"); await boolean(TESTED, False); at("2026-11-13T20:50")
    await fire("asyla_hvac_experiment_start"); await skip(3.1)
    check("start 20:50, write test not done, reading 35: nothing (neither day window nor night)", (took(), st(TESTED)), ([], "off"))
    at("2027-04-01T22:00"); await fire("asyla_hvac_experiment_start"); await skip(3.1)
    check("start 2027-04-01 22:00 (after the window), reading 35: nothing", took(), [])

    # the read-only sensors: unavailable, not 0, with their source
    lockout("unavailable", None); await skip(0)
    check("lockout sensor: unavailable with the number", st(LOCKOUT), "unavailable")
    lockout("30.0"); await skip(0)
    check("lockout sensor: 30.0", st(LOCKOUT), "30.0")
    hass.states.async_set(WEATHER, "cloudy", {"temperature": 0, "temperature_unit": "°C"}); await skip(0)
    check("outdoor feed sensor: 0 °C is 32.0 °F", st(OUTDOOR), "32.0")
    hass.states.async_set(WEATHER, "unavailable", {}); await skip(0)
    check("outdoor feed sensor: unavailable with the weather entity", st(OUTDOOR), "unavailable")
    check("every write went to the lockout entity", bool(ids) and ids <= {E, (E,)}, True)
    await hass.async_stop(force=True)

asyncio.run(main())
print(f"live: {len(bad)} failed")
sys.exit(1 if bad else 0)
'''


@unittest.skipUnless(image_present(), f"needs docker and {IMAGE} (docker pull it)")
class LiveInPinnedImage(unittest.TestCase):
    def test_renders_and_automations(self):
        data = json.dumps([NIGHT_CASES, MORNING_CASES, FIXTURE])
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp)
            (cfg / "packages").mkdir()
            shutil.copy(APP / PACKAGE, cfg / PACKAGE)
            (cfg / "configuration.yaml").write_text(
                "homeassistant:\n  time_zone: America/Chicago\n  unit_system: us_customary\n"
                f"  packages:\n    hvac_experiment: !include {PACKAGE}\n")
            r = in_image(cfg, "-", stdin=LIVE.replace("@DATA@", data))
        print(r.stdout, end="")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr[-3000:])
        self.assertIn("live: 0 failed", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
