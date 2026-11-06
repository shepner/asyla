#!/usr/bin/env python3
"""d01 home-assistant: the freezer alert (packages/freezer.yaml).

    python3 scripts/tests/test_home_assistant_freezer.py

1. home-assistant.sh up and verify against stubs (as test_home_assistant_hvac.py): up installs
   packages/freezer.yaml as an exact copy (600); verify passes, then fails once it is edited.
2. With docker and the image pinned in compose.yml present (docker pull it first), in that image
   with no network: Home Assistant's check_config accepts the installed config.
3. In that image, one boot of Home Assistant with the package alone (stand-in notify and
   persistent_notification actions, the event loop's clock moved on for the holds): the probe in
   °F or °C; above 15 °F for 59 min sends nothing, for 60 min one URGENT notice, and back to
   normal clears it with no mail; exactly 15 °F is not warm; a defrost peak (7 °F) never alerts;
   unavailable for 5 h 59 min sends nothing, 6 h one notice (not urgent), the probe back clears it;
   a probe that is unavailable while warm gives no warm alert.
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

PACKAGE = "packages/freezer.yaml"


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
        for want in ("id: asyla_freezer_warm", "id: asyla_freezer_warm_clear",
                     "id: asyla_freezer_probe_missing", "id: asyla_freezer_probe_back",
                     "- notify.hvac_report"):
            self.assertIn(want, out)


LIVE = r'''
import asyncio, sys
from homeassistant import bootstrap, runner

PROBE, WARM, MISSING = "sensor.mke_temperature_2", "binary_sensor.freezer_too_warm", "binary_sensor.freezer_probe_missing"
bad = []
def check(name, got, want):
    bad.extend([] if got == want else [name])
    print(("ok   " if got == want else "FAIL ") + name + ("" if got == want else f": got {got!r}, want {want!r}"),
          flush=True)

async def main():
    # Timers (delay_on, a state trigger's for:) are loop.call_at deadlines: skip() moves the loop's clock on.
    loop = asyncio.get_running_loop()
    real, skew = loop.time, [0.0]
    loop.time = lambda: real() + skew[0]
    async def skip(minutes):
        skew[0] += minutes * 60
        for _ in range(10):
            await asyncio.sleep(0.05)
    hass = await bootstrap.async_setup_hass(runner.RuntimeConfig(config_dir="/config", skip_pip=True))
    mails, notes, dismissed = [], [], []
    async def mail(call): mails.append(dict(call.data))
    async def note(call): notes.append(dict(call.data))
    async def dismiss(call): dismissed.append(call.data.get("notification_id"))
    hass.services.async_register("notify", "send_message", mail)
    hass.services.async_register("persistent_notification", "create", note)
    hass.services.async_register("persistent_notification", "dismiss", dismiss)
    await hass.async_start()
    def probe(v, u="°F"): hass.states.async_set(PROBE, v, {"unit_of_measurement": u} if u else {})
    def seen(): return (len(mails), len(notes), len(dismissed))
    st = lambda e: hass.states.get(e).state

    # --- a defrost peak and exactly 15 °F never alert ---------------------------------------------
    probe("-2.7"); await skip(0)
    check("normal: not warm, probe present", (st(WARM), st(MISSING)), ("off", "off"))
    dismissed.clear()  # the first evaluation at start is an edge to off: a dismiss of nothing
    probe("6.8"); await skip(120)
    check("defrost peak 6.8 °F for 2 h: not warm, nothing sent", (st(WARM), seen()), ("off", (0, 0, 0)))
    probe("15.0"); await skip(120)
    check("exactly 15 °F for 2 h: not warm", (st(WARM), seen()), ("off", (0, 0, 0)))

    # --- warm for 60 min ---------------------------------------------------------------------------
    probe("17.3"); await skip(59)
    check("17.3 °F for 59 min: nothing yet", (st(WARM), seen()), ("off", (0, 0, 0)))
    await skip(2)
    check("17.3 °F for 61 min: warm, one mail, one notification", (st(WARM), seen()), ("on", (1, 1, 0)))
    check("mail is URGENT with the reading", mails[0]["title"], "[URGENT] Freezer too warm: 17.3 °F")
    check("notification id", notes[0]["notification_id"], "asyla_freezer_warm")
    await skip(180)
    check("warm for 3 more hours: still one mail", seen(), (1, 1, 0))
    probe("-3.0"); await skip(0)
    check("back to normal: cleared, no mail", (st(WARM), seen(), dismissed), ("off", (1, 1, 1), ["asyla_freezer_warm"]))

    # --- °C probe ----------------------------------------------------------------------------------
    probe("-8.0", "°C"); await skip(120)   # 17.6 °F
    check("-8 °C (17.6 °F) for 2 h: warm", st(WARM), "on")
    probe("-12.0", "°C"); await skip(0)     # 10.4 °F
    check("-12 °C (10.4 °F): off", st(WARM), "off")
    mails.clear(); notes.clear(); dismissed.clear()

    # --- unavailable ------------------------------------------------------------------------------
    probe("unavailable", None); await skip(0)
    check("unavailable: warm sensor unavailable (no alert while unwatched)", st(WARM), "unavailable")
    await skip(359)
    check("unavailable 5 h 59 min: nothing sent", (st(MISSING), seen()), ("off", (0, 0, 0)))
    await skip(2)
    check("unavailable 6 h: one notice, not urgent",
          (st(MISSING), seen(), mails[0]["title"]), ("on", (1, 1, 0), "Freezer probe has no reading"))
    check("notification id", notes[0]["notification_id"], "asyla_freezer_probe_missing")
    await skip(600)
    check("unavailable 16 h: still one", seen(), (1, 1, 0))
    probe("-4.0"); await skip(0)
    # The warm sensor also leaves unavailable for off: that edge dismisses its (absent) notification.
    check("probe back: cleared, no mail", (st(MISSING), seen()[:2], "asyla_freezer_probe_missing" in dismissed),
          ("off", (1, 1), True))
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
            (cfg / "configuration.yaml").write_text(f"homeassistant:\n  packages:\n    freezer: !include {PACKAGE}\n")
            r = in_image(cfg, "-", stdin=LIVE)
        print(r.stdout, end="")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr[-3000:])
        self.assertIn("live: 0 failed", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
