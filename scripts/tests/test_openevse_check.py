#!/usr/bin/env python3
"""Offline test of d03/apps/openevse-monitor/openevse_check.py: what it calls a problem (stdlib unittest).

    python3 scripts/tests/test_openevse_check.py

The /status body is the one openevse01 (WiFi gateway 2.9.1, controller 5.0.1) served on
2026-10-26T04:17Z, cut to the fields the checker reads; nothing reaches the network.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import tempfile
import tomllib
import unittest
from pathlib import Path

APP = Path(__file__).resolve().parents[2] / "d03" / "apps" / "openevse-monitor"
_spec = importlib.util.spec_from_file_location("openevse_check", APP / "openevse_check.py")
oc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(oc)
oc.urllib.request.OpenerDirector.open = lambda *a, **kw: (_ for _ in ()).throw(AssertionError("network"))

with open(APP / "openevse-monitor.toml", "rb") as f:
    CFG = tomllib.load(f)
T = dt.datetime(2026, 10, 26, 4, 20, tzinfo=dt.timezone.utc)
STEP = dt.timedelta(minutes=5)


def status(**kw) -> dict:
    s = {"state": 2, "amp": 0, "pilot": 55, "voltage": 240, "temp1": 272, "temp2": False, "temp3": False,
         "elapsed": 6698, "wattsec": 20628920, "watthour": 5217395, "gfcicount": 0, "nogndcount": 2,
         "stuckcount": 0, "rapi_connected": 1, "comm_sent": 286, "comm_success": 286, "srssi": -60,
         "free_heap": 17184, "mode": "STA", "wifi_client_connected": 1}
    return s | kw


class Run:
    """Cycles of check() on one state, 5 minutes apart, with stage.json in a temp dir."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        oc.DATA = Path(self.tmp.name)
        self.state, self.t = {}, T

    def cycle(self, st=None, error=None):
        found, _ = oc.check(CFG, st, error, self.state, self.t)
        self.t += STEP
        return {k: (sev, msg) for k, sev, msg in found}


class Healthy(unittest.TestCase):
    def test_baseline_is_quiet(self):
        r = Run()
        for _ in range(3):
            self.assertEqual(r.cycle(status()), {})

    def test_first_reading_records_counters(self):
        r = Run()
        r.cycle(status())
        self.assertEqual(r.state["faults"], {"gfcicount": 0, "nogndcount": 2, "stuckcount": 0})
        self.assertEqual(r.state["comm_sent"], 286)

    def test_charging_and_sleeping_are_not_problems(self):
        r = Run()
        self.assertEqual(r.cycle(status(state=3, amp=31500)), {})
        self.assertEqual(r.cycle(status(state=254)), {})


class Unreachable(unittest.TestCase):
    def test_urgent_only_from_the_third_miss(self):
        r = Run()
        r.cycle(status())
        self.assertEqual(r.cycle(error="GET /status: TimeoutError"), {})
        self.assertEqual(r.cycle(error="GET /status: TimeoutError"), {})
        f = r.cycle(error="GET /status: TimeoutError")
        self.assertEqual(f["unreachable"][0], "urgent")
        self.assertIn("not answering from d03", f["unreachable"][1])

    def test_one_miss_then_back_is_quiet(self):
        r = Run()
        r.cycle(status())
        r.cycle(error="GET /status: TimeoutError")
        self.assertEqual(r.cycle(status()), {})
        self.assertEqual(r.state.get("events", []), [])

    def test_a_long_spell_ends_as_a_warn_event(self):
        r = Run()
        for _ in range(4):
            r.cycle(error="GET /status: URLError")
        f = r.cycle(status())
        self.assertEqual(f[next(k for k in f if k.startswith("outage:"))][0], "warn")
        self.assertNotIn("unreachable", f)

    def test_login_refused_is_its_own_key(self):
        r = Run()
        for _ in range(3):
            f = r.cycle(error="GET /status: HTTP 401, the login was refused")
        self.assertEqual(f["login"][0], "urgent")
        self.assertNotIn("unreachable", f)


class Controller(unittest.TestCase):
    def test_rapi_link_down_after_two(self):
        r = Run()
        self.assertEqual(r.cycle(status(rapi_connected=0)), {})
        f = r.cycle(status(rapi_connected=0))
        self.assertEqual(f["rapi"][0], "urgent")

    def test_error_state_after_two(self):
        r = Run()
        self.assertEqual(r.cycle(status(state=6)), {})
        f = r.cycle(status(state=6))
        self.assertEqual(f["state:6"][0], "urgent")
        self.assertIn("GFCI fault", f["state:6"][1])

    def test_vent_required_and_later_codes_are_errors(self):
        for code in (4, 11, 14, 17):
            r = Run()
            r.cycle(status(state=code))
            self.assertIn(f"state:{code}", r.cycle(status(state=code)))

    def test_disabled_and_unknown_warn(self):
        r = Run()
        self.assertEqual(r.cycle(status(state=255))["state:disabled"][0], "warn")
        self.assertEqual(r.cycle(status(state=0))["state:unknown"][0], "warn")
        self.assertEqual(r.cycle(status(state=99))["state:unknown"][0], "warn")

    def test_missing_state_is_a_layout_warn(self):
        st = status()
        del st["state"]
        self.assertEqual(Run().cycle(st)["layout"][0], "warn")


class Events(unittest.TestCase):
    def test_fault_counter_up_is_urgent_then_drops_off(self):
        r = Run()
        r.cycle(status())
        f = r.cycle(status(nogndcount=3))
        k = next(k for k in f if k.startswith("fault:no_ground"))
        self.assertEqual(f[k][0], "urgent")
        self.assertIn("from 2 to 3", f[k][1])
        r.t += dt.timedelta(minutes=CFG["events"]["urgent_hold_minutes"])
        self.assertNotIn(k, r.cycle(status(nogndcount=3)))

    def test_counters_read_as_zero_after_a_restart_are_quiet(self):
        # 2026-10-26 13:26-13:32Z: no ground 2, then 0 in the first reading after a WiFi restart, then 2.
        r = Run()
        r.cycle(status(comm_sent=784, comm_success=784))
        self.assertEqual(r.cycle(status(comm_sent=21, comm_success=21, gfcicount=0, nogndcount=0, stuckcount=0)), {})
        self.assertEqual(r.cycle(status(comm_sent=180, comm_success=180)), {})
        self.assertEqual(r.state["faults"]["nogndcount"], 2)
        f = r.cycle(status(comm_sent=330, comm_success=330, nogndcount=3))
        self.assertIn("from 2 to 3", f[next(k for k in f if k.startswith("fault:no_ground"))][1])

    def test_wifi_restart_is_counted_not_reported(self):
        r = Run()
        r.cycle(status(comm_sent=5000, comm_success=5000))
        self.assertEqual(r.cycle(status(comm_sent=12, comm_success=12)), {})
        self.assertEqual(r.state["wifi_restarts"], 1)
        self.assertEqual(r.state["wifi_last_restart"], oc.iso(T + STEP))
        self.assertEqual(r.state.get("events", []), [])
        r.cycle(status(comm_sent=900, comm_success=900))
        r.cycle(status(comm_sent=30, comm_success=30))
        self.assertEqual(r.state["wifi_restarts"], 2)
        self.assertEqual(oc.summary(status(), 1.0, r.state)["wifi_restarts"], 2)

    def test_old_restart_events_become_the_count(self):
        r = Run()
        r.state = {"comm_sent": 145, "events": [
            {"key": "restart:2026-10-26T04:15:00Z", "kind": "restart", "message": "m", "at": "2026-10-26T04:15:00Z"},
            {"key": "outage:2026-10-26T03:00:00Z", "kind": "outage", "message": "o", "at": "2026-10-26T04:00:00Z"}]}
        f = r.cycle(status(comm_sent=200, comm_success=200))
        self.assertEqual(r.state["wifi_restarts"], 1)
        self.assertEqual([e["kind"] for e in r.state["events"]], ["outage"])
        self.assertEqual(list(f), ["outage:2026-10-26T03:00:00Z"])

    def test_counter_rising_normally_is_quiet(self):
        r = Run()
        r.cycle(status(comm_sent=286))
        self.assertEqual(r.cycle(status(comm_sent=400, comm_success=400)), {})


class Limits(unittest.TestCase):
    def test_weak_rssi_warns_low_heap_does_not(self):
        f = Run().cycle(status(srssi=-80, free_heap=5808))
        self.assertEqual(f["rssi"][0], "warn")
        self.assertEqual(list(f), ["rssi"])


class Stage(unittest.TestCase):
    def test_staged_alert_until_expiry(self):
        r = Run()
        (oc.DATA / "stage.json").write_text(json.dumps({"until": oc.iso(T + dt.timedelta(minutes=12)), "note": "test"}))
        self.assertEqual(r.cycle(status())["staged"][0], "urgent")
        r.cycle(status())
        r.cycle(status())
        self.assertNotIn("staged", r.cycle(status()))


class Output(unittest.TestCase):
    def test_prom_units_and_no_voltage(self):
        p = oc.prom(True, T, status(amp=31500), 1.5, [])
        lines = dict(l.rsplit(" ", 1) for l in p.splitlines() if not l.startswith("#"))
        self.assertEqual(lines['openevse_up{charger="openevse01"}'], "1")
        self.assertEqual(lines['openevse_charge_current_amps{charger="openevse01"}'], "31.5")
        self.assertEqual(lines['openevse_temperature_celsius{charger="openevse01",sensor="1"}'], "27.2")
        self.assertNotIn('openevse_temperature_celsius{charger="openevse01",sensor="2"}', lines)
        self.assertEqual(lines['openevse_energy_wh_total{charger="openevse01"}'], "5217395")
        self.assertEqual(lines['openevse_faults_total{charger="openevse01",kind="no_ground"}'], "2")
        self.assertEqual(lines['openevse_rapi_success_ratio{charger="openevse01"}'], "1")
        self.assertFalse(any("voltage" in k for k in lines))

    def test_prom_down(self):
        p = oc.prom(False, T, None, None, [{"severity": "urgent"}], {"wifi_restarts": 3})
        self.assertIn('openevse_up{charger="openevse01"} 0', p)
        self.assertIn('openevse_problems{charger="openevse01",severity="urgent"} 1', p)
        self.assertIn('openevse_wifi_restarts_total{charger="openevse01"} 3', p)

    def test_prom_every_line_names_the_charger(self):
        for p in (oc.prom(True, T, status(), 1.0, [], {}), oc.prom(False, T, None, None, [], {})):
            for l in p.splitlines():
                if not l.startswith("#"):
                    self.assertIn('{charger="openevse01"', l)

    def test_prom_restarts_start_at_zero(self):
        self.assertIn('openevse_wifi_restarts_total{charger="openevse01"} 0', oc.prom(True, T, status(), 1.0, [], {}))

    def test_summary(self):
        s = oc.summary(status(), 2.0, {})
        self.assertEqual((s["state"], s["state_name"], s["amps"], s["temperature_c"]),
                         (2, "B: connected, ready", 0, [27.2, None, None]))
        self.assertEqual(s["session_wh"], 5730.3)

    def test_main_without_login_writes_status(self):
        tmp = tempfile.TemporaryDirectory()
        oc.DATA = Path(tmp.name)
        oc.os.environ.pop("OPENEVSE_WWW_USER", None)
        oc.os.environ.pop("OPENEVSE_WWW_PASSWORD", None)
        self.assertEqual(oc.main(), 0)
        s = json.loads((oc.DATA / "status.json").read_text())
        self.assertEqual((s["checker"], s["ok"], s["problems"]), ("openevse-monitor", False, []))
        self.assertIn('openevse_up{charger="openevse01"} 0', (oc.DATA / "openevse.prom").read_text())


if __name__ == "__main__":
    unittest.main()
