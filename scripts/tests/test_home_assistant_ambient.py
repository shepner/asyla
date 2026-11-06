#!/usr/bin/env python3
"""d01 home-assistant: the Ambient Weather sensor health (packages/ambient_sensors.yaml).

    python3 scripts/tests/test_home_assistant_ambient.py

1. home-assistant.sh up and verify against stubs: up installs packages/ambient_sensors.yaml as an
   exact copy (600); verify passes, then fails once it is edited.
2. With docker and the image pinned in compose.yml present, in that image with no network: check_config
   accepts the installed config.
3. One boot of Home Assistant with the package alone (stand-in notify and persistent_notification
   actions; states set with the age they would have): a temperature entity (outdoor, channels 1 and 3
   to 10, the WH32B) unchanged or unavailable for 12 h is silent and sends one notice naming it, the
   freezer's channel 2 and the humidity entities never count, 11 h 59 min does not; a channel added
   later is covered with no edit; a battery flag on for 6 h sends one notice, an unrelated battery
   binary sensor does not count; both clear without a mail.
   Without docker and the image, 2 and 3 say skip.
Nothing reaches a host or Home Assistant.
"""
from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_home_assistant_hvac import APP, IMAGE, Stage, image_present, in_image, mode  # noqa: E402

PACKAGE = "packages/ambient_sensors.yaml"


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


@unittest.skipUnless(image_present(), f"needs docker and {IMAGE} (docker pull it)")
class CheckConfig(unittest.TestCase):
    def test_check_config_accepts_it(self):
        import re
        with tempfile.TemporaryDirectory() as tmp:
            s = Stage(Path(tmp))
            r = s.run("up")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            shutil.rmtree(s.config / ".storage", ignore_errors=True)
            r = in_image(s.config, "-m", "homeassistant", "--script", "check_config", "-c", "/config", "--info", "all")
        out = re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr)
        self.assertEqual(r.returncode, 0, out)
        self.assertNotRegex(out, r"Incorrect config|Failed config|Invalid config|Error")
        for want in ("id: asyla_ambient_sensors_silent", "id: asyla_ambient_batteries_low",
                     "- notify.hvac_report"):
            self.assertIn(want, out)


LIVE = r'''
import asyncio, sys, time
from homeassistant import bootstrap, runner

SIL, BAT = "binary_sensor.ambient_sensors_silent", "binary_sensor.ambient_batteries_low"
H = 3600
bad = []
def check(name, got, want):
    bad.extend([] if got == want else [name])
    print(("ok   " if got == want else "FAIL ") + name + ("" if got == want else f": got {got!r}, want {want!r}"),
          flush=True)

async def main():
    loop = asyncio.get_running_loop()
    real, skew = loop.time, [0.0]
    loop.time = lambda: real() + skew[0]
    async def skip(minutes):
        skew[0] += minutes * 60
        # A template over a whole domain (states.sensor) tracks only the entities it has read so far
        # (others on the next minute's render, which now() brings): the test asks for the render.
        await asyncio.sleep(0.3)
        await hass.services.async_call("homeassistant", "update_entity", {"entity_id": [SIL, BAT]}, blocking=True)
        await asyncio.sleep(0.3)
    hass = await bootstrap.async_setup_hass(runner.RuntimeConfig(config_dir="/config", skip_pip=True))
    mails, notes, dismissed = [], [], []
    async def mail(call): mails.append(dict(call.data))
    async def note(call): notes.append(dict(call.data))
    async def dismiss(call): dismissed.append(call.data.get("notification_id"))
    hass.services.async_register("notify", "send_message", mail)
    hass.services.async_register("persistent_notification", "create", note)
    hass.services.async_register("persistent_notification", "dismiss", dismiss)
    await hass.async_start()
    def put(e, v, age=0, **a): hass.states.async_set(e, v, a, timestamp=time.time() - age)
    st = lambda e: hass.states.get(e).state
    ents = lambda e: sorted(hass.states.get(e).attributes.get("entities", []))
    seen = lambda: (len(mails), len(notes))

    # --- silent temperatures -------------------------------------------------------------------
    for e in ("sensor.mke_temperature", "sensor.mke_temperature_1", "sensor.mke_inside_temperature"):
        put(e, "60.0", 100, unit_of_measurement="°F")
    put("sensor.mke_temperature_2", "-3.0", 40 * H, unit_of_measurement="°F")    # the freezer: freezer.yaml
    put("sensor.mke_humidity_indoor", "40", 40 * H, unit_of_measurement="%")      # humidity never counts
    put("sensor.mke_temperature_24_h_minimum", "50", 40 * H, unit_of_measurement="°F")
    put("sensor.indoor_dew_point", "10", 40 * H)
    await skip(0)
    check("all moving; the freezer, humidity and 24 h minimum, however old, do not count", (st(SIL), seen()), ("off", (0, 0)))
    put("sensor.mke_temperature_1", "61.0", 12 * H - 60, unit_of_measurement="°F"); await skip(0)
    check("channel 1 unchanged 11 h 59 min: not yet", (st(SIL), seen()), ("off", (0, 0)))
    put("sensor.mke_temperature_1", "62.0", 12 * H + 60, unit_of_measurement="°F"); await skip(0)
    check("channel 1 unchanged 12 h 01 min: silent, one notice naming it", (st(SIL), ents(SIL), seen()),
          ("on", ["sensor.mke_temperature_1"], (1, 1)))
    check("not urgent, names the entity", ("URGENT" in mails[0]["title"], "sensor.mke_temperature_1" in mails[0]["message"]),
          (False, True))
    check("notification id", notes[0]["notification_id"], "asyla_ambient_sensors_silent")
    # A channel added later is picked up with no edit; the mail is not repeated.
    put("sensor.mke_temperature_7", "unavailable", 13 * H); await skip(0)
    check("channel 7 added, unavailable 13 h: listed, no second mail",
          (ents(SIL), seen()), (["sensor.mke_temperature_1", "sensor.mke_temperature_7"], (1, 1)))
    put("sensor.mke_temperature_1", "63.0", 5); put("sensor.mke_temperature_7", "55.0", 5, unit_of_measurement="°F")
    await skip(0)
    check("both move: cleared, no mail", (st(SIL), seen(), dismissed), ("off", (1, 1), ["asyla_ambient_sensors_silent"]))
    dismissed.clear()
    for e in ("sensor.mke_inside_temperature", "sensor.mke_temperature"):
        put(e, "unavailable", 12 * H + 60); await skip(0)
        check(f"{e} unavailable 12 h: silent", (e in ents(SIL), st(SIL)), (True, "on"))
        put(e, "60.0", 5, unit_of_measurement="°F"); await skip(0)
    mails.clear(); notes.clear(); dismissed.clear()

    # --- batteries -----------------------------------------------------------------------------
    put("binary_sensor.mke_battery", "off", 0, device_class="battery")
    put("binary_sensor.mke_battery_2", "off", 0, device_class="battery")
    put("binary_sensor.mke_interior_battery", "off", 0, device_class="battery")
    put("binary_sensor.other_thing", "on", 0, device_class="battery")      # not the station's
    put("binary_sensor.mke_something_else", "on", 0, device_class="problem")
    await skip(0)
    check("no station battery low: off", (st(BAT), seen()), ("off", (0, 0)))
    put("binary_sensor.mke_battery_2", "on", 0, device_class="battery"); await skip(0)
    check("freezer probe battery low: off until 6 h", st(BAT), "off")
    await skip(5 * 60 + 59)
    check("5 h 59 min: not yet", (st(BAT), seen()), ("off", (0, 0)))
    await skip(2)
    check("6 h: one notice naming it, not urgent", (st(BAT), ents(BAT), seen(), "URGENT" in mails[0]["title"]),
          ("on", ["binary_sensor.mke_battery_2"], (1, 1), False))
    check("notification id", notes[0]["notification_id"], "asyla_ambient_batteries_low")
    put("binary_sensor.mke_battery_2", "off", 0, device_class="battery"); await skip(0)
    check("battery replaced: cleared, no mail", (st(BAT), seen(), dismissed), ("off", (1, 1), ["asyla_ambient_batteries_low"]))
    await hass.async_stop(force=True)

asyncio.run(main())
print(f"live: {len(bad)} failed")
sys.exit(1 if bad else 0)
'''


@unittest.skipUnless(image_present(), f"needs docker and {IMAGE} (docker pull it)")
class LiveInPinnedImage(unittest.TestCase):
    def test_holds_and_notices(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp)
            (cfg / "packages").mkdir()
            shutil.copy(APP / PACKAGE, cfg / PACKAGE)
            (cfg / "configuration.yaml").write_text(f"homeassistant:\n  packages:\n    ambient: !include {PACKAGE}\n")
            r = in_image(cfg, "-", stdin=LIVE)
        print(r.stdout, end="")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr[-3000:])
        self.assertIn("live: 0 failed", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
