#!/usr/bin/env python3
"""d01 home-assistant: location names for the Ambient sensors (packages/sensor_names.yaml).

    python3 scripts/tests/test_home_assistant_sensor_names.py

1. home-assistant.sh up installs packages/sensor_names.yaml as an exact copy (600) and verify passes.
2. The package sets friendly_name only, on Ambient station entity ids (mke_ / outside_mke_), each once.
3. With docker and the image pinned in compose.yml present, in that image with no network: check_config
   accepts the installed config, and one boot shows a real entity written as
   sensor.outside_mke_temperature_5 named "Attic temperature", its entity id unchanged.
   Without docker and the image, 3 says skip.
Nothing reaches a host or Home Assistant.
"""
from __future__ import annotations

import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_home_assistant_hvac import APP, IMAGE, Stage, image_present, in_image, mode  # noqa: E402

PACKAGE = "packages/sensor_names.yaml"
LINE = re.compile(r"^    ((?:binary_)?sensor\.(?:outside_)?mke_[a-z0-9_]+): \{friendly_name: \"([^\"]+)\"\}$")


class Package(unittest.TestCase):
    def test_up_installs_and_verify_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = Stage(Path(tmp))
            r = s.run("up")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertEqual((s.config / PACKAGE).read_bytes(), (APP / PACKAGE).read_bytes())
            self.assertEqual(mode(s.config / PACKAGE), "600")
            r = s.run("verify")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_friendly_names_only_on_station_entities_each_once(self):
        lines = [l for l in (APP / PACKAGE).read_text().splitlines() if l and not l.lstrip().startswith("#")]
        self.assertEqual(lines[:2], ["homeassistant:", "  customize:"])
        ids = []
        for l in lines[2:]:
            m = LINE.match(l)
            self.assertIsNotNone(m, f"not a friendly_name line on a station entity: {l!r}")
            ids.append(m.group(1))
        self.assertEqual(len(ids), len(set(ids)), "an entity named twice")
        self.assertIn("sensor.outside_mke_temperature_5", ids)


LIVE = r'''
import asyncio, sys
from homeassistant import bootstrap, runner

async def main():
    hass = await bootstrap.async_setup_hass(runner.RuntimeConfig(config_dir="/config", skip_pip=True))
    await hass.async_start()
    await hass.async_block_till_done()
    s = hass.states.get("sensor.outside_mke_temperature_5")
    got = (s is not None, s and s.attributes.get("friendly_name"))
    print("attic:", got, flush=True)
    await hass.async_stop(force=True)
    print("live: " + ("0 failed" if got == (True, "Attic temperature") else "1 failed"))

asyncio.run(main())
'''


@unittest.skipUnless(image_present(), f"needs docker and {IMAGE} (docker pull it)")
class InPinnedImage(unittest.TestCase):
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

    def test_a_real_entity_takes_the_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp)
            (cfg / "packages").mkdir()
            shutil.copy(APP / PACKAGE, cfg / PACKAGE)
            # A template sensor stands in for the station's entity: it writes its state through the
            # entity platform, which is where customize is applied.
            (cfg / "configuration.yaml").write_text(
                "homeassistant:\n  packages:\n    names: !include " + PACKAGE + "\n"
                "template:\n  - sensor:\n      - name: \"Outside MKE Temperature 5\"\n"
                "        unique_id: test_attic\n        default_entity_id: sensor.outside_mke_temperature_5\n"
                "        state: \"45\"\n")
            r = in_image(cfg, "-", stdin=LIVE)
        print(r.stdout, end="")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr[-3000:])
        self.assertIn("live: 0 failed", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
