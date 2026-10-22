#!/usr/bin/env python3
"""Offline test of d03/apps/unifi-monitor/unifi_check.py: what it calls a problem (stdlib unittest).

    python3 scripts/tests/test_unifi_check.py

The Site Manager answers are built here in the shapes read on 2026-10-22 (v1/hosts, v1/devices,
ea/isp-metrics/5m); nothing reaches the network.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

APP = Path(__file__).resolve().parents[2] / "d03" / "apps" / "unifi-monitor"
_spec = importlib.util.spec_from_file_location("unifi_check", APP / "unifi_check.py")
uc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(uc)
uc.urllib.request.urlopen = lambda *a, **kw: (_ for _ in ()).throw(AssertionError("network"))

with open(APP / "unifi-monitor.toml", "rb") as f:
    CFG = tomllib.load(f)
T = dt.datetime(2026, 10, 22, 20, 0, tzinfo=dt.timezone.utc)


def z(t: dt.datetime) -> str:
    return uc.iso(t)


def host(hid, name, state="connected"):
    return {"id": hid, "reportedState": {"name": name, "state": state},
            "lastConnectionStateChange": "2026-10-22T07:34:51Z"}


def dev(mac, name, status="online", start=T - dt.timedelta(days=10), fw="upToDate", update=None):
    return {"mac": mac, "name": name, "model": "AC LR", "status": status, "startupTime": z(start),
            "firmwareStatus": fw, "updateAvailable": update, "version": "6.8.2"}


def period(at, lat=12, loss=0, down=0):
    return {"metricTime": z(at), "data": {"wan": {"avgLatency": lat, "maxLatency": lat + 1,
                                                  "packetLoss": loss, "downtime": down, "uptime": 100}}}


def isp(hid, periods):
    return [{"hostId": hid, "metricType": "5m", "periods": periods}]


def healthy_wan(n=12):
    return [period(T - dt.timedelta(minutes=60 + 5 * i)) for i in range(n)]


HOSTS = [host("h-day", "DAY"), host("h-mke", "MKE")]


def devices(day=None, mke=None):
    return [{"hostId": "h-day", "devices": day if day is not None else [dev("AA", "AP-Hall")]},
            {"hostId": "h-mke", "devices": mke if mke is not None else [dev("BB", "UpstairsAP")]}]


def run(hosts=HOSTS, devs=None, wan=None, state=None, t=T, cfg=CFG):
    state = {} if state is None else state
    found, read, summary = uc.evaluate(cfg, hosts, devs or devices(), isp("h-day", healthy_wan() if wan is None else wan),
                                       state, t)
    return {k: (s, m) for k, s, m in found}, read, summary, state


class Findings(unittest.TestCase):
    def test_all_well_is_quiet(self):
        found, _, summary, _ = run()
        self.assertEqual(found, {})
        self.assertEqual(summary["DAY"], {"state": "connected", "devices": 1, "offline": 0})

    def test_console_disconnected_is_urgent(self):
        found, *_ = run(hosts=[host("h-day", "DAY", "disconnected"), HOSTS[1]])
        self.assertEqual(found["console:DAY:disconnected"][0], "urgent")
        self.assertIn("since 2026-10-22T07:34:51Z", found["console:DAY:disconnected"][1])

    def test_console_not_listed_is_urgent(self):
        found, *_ = run(hosts=[HOSTS[1]])
        self.assertEqual(found["console:DAY:missing"][0], "urgent")

    def test_device_offline_is_urgent(self):
        found, *_ = run(devs=devices(day=[dev("AA", "AP-Hall", status="offline")]))
        self.assertEqual(found["device:DAY:AA:offline"], ("urgent", "UniFi DAY: AP-Hall (AC LR) is offline"))

    def test_recent_restart_is_a_warning_for_a_day(self):
        found, *_ = run(devs=devices(day=[dev("AA", "AP-Hall", start=T - dt.timedelta(hours=3))]))
        self.assertEqual(found["device:DAY:AA:restarted"][0], "warn")
        found, *_ = run(devs=devices(day=[dev("AA", "AP-Hall", start=T - dt.timedelta(hours=25))]))
        self.assertNotIn("device:DAY:AA:restarted", found)

    def test_firmware_waiting_a_week_is_a_warning(self):
        state = {}
        waiting = devices(day=[dev("AA", "AP-Hall", fw="updateAvailable", update="6.8.3")])
        found, *_ = run(devs=waiting, state=state)
        self.assertNotIn("device:DAY:AA:firmware", found)
        found, *_ = run(devs=waiting, state=state, t=T + dt.timedelta(days=7))
        self.assertIn("waiting since 2026-10-22T20:00:00Z", found["device:DAY:AA:firmware"][1])
        run(state=state, t=T + dt.timedelta(days=8))
        self.assertEqual(state["firmware"], {}, "an applied update forgets its first-seen time")

    def test_a_device_that_leaves_the_list_is_warned_then_forgotten(self):
        state = {}
        run(state=state)
        found, *_ = run(devs=devices(day=[]), state=state, t=T + dt.timedelta(hours=1))
        self.assertEqual(found["device:DAY:AA:gone"][0], "warn")
        found, *_ = run(devs=devices(day=[]), state=state, t=T + dt.timedelta(hours=26))
        self.assertNotIn("device:DAY:AA:gone", found)
        self.assertNotIn("AA", state["devices"]["DAY"])

    def test_wan_downtime_in_the_last_hour(self):
        wan = [period(T - dt.timedelta(minutes=60), down=30)] + healthy_wan()[1:]
        found, *_ = run(wan=wan)
        self.assertEqual(found["wan:DAY:downtime"][0], "warn")

    def test_wan_latency_needs_three_bad_periods(self):
        bad = lambda n: [period(T - dt.timedelta(minutes=60 + 5 * i), lat=45 if i < n else 12) for i in range(12)]
        self.assertNotIn("wan:DAY:latency", run(wan=bad(2))[0])
        self.assertIn("up to 45 ms", run(wan=bad(3))[0]["wan:DAY:latency"][1])

    def test_wan_loss_needs_three_bad_periods(self):
        bad = [period(T - dt.timedelta(minutes=60 + 5 * i), loss=12 if i < 3 else 1) for i in range(12)]
        self.assertEqual(run(wan=bad)[0]["wan:DAY:loss"][0], "warn")

    def test_the_2026_10_21_baseline_is_quiet(self):
        base = [period(T - dt.timedelta(minutes=60 + 5 * i), lat=14, loss=6) for i in range(12)]
        self.assertEqual(run(wan=base)[0], {})

    def test_stale_and_missing_wan_figures(self):
        old = [period(T - dt.timedelta(hours=4))]
        self.assertIn("wan:DAY:stale", run(wan=old)[0])
        self.assertIn("wan:DAY:none", run(wan=[])[0])

    def test_mke_has_no_wan_check(self):
        found, read, *_ = run()
        self.assertEqual([w[0] for w in read["wan"]], ["DAY"])

    def test_key_expiry_warns_thirty_days_before(self):
        self.assertNotIn("key:expiry", run(t=dt.datetime(2027, 9, 20, tzinfo=dt.timezone.utc))[0])
        self.assertEqual(run(t=dt.datetime(2027, 9, 22, tzinfo=dt.timezone.utc))[0]["key:expiry"][0], "warn")


class Confirm(unittest.TestCase):
    def test_urgent_waits_for_two_checks_in_a_row(self):
        state = {}
        off = [("device:DAY:AA:offline", "urgent", "m"), ("w", "warn", "m")]
        self.assertEqual([k for k, *_ in uc.confirm(off, state, 2)], ["w"])
        self.assertEqual([k for k, *_ in uc.confirm(off, state, 2)], ["device:DAY:AA:offline", "w"])
        uc.confirm([], state, 2)
        self.assertEqual(uc.confirm(off[:1], state, 2), [], "a gap starts the count again")


class Stage(unittest.TestCase):
    def test_staged_alert_until_it_expires(self):
        with tempfile.TemporaryDirectory() as d:
            uc.DATA = Path(d)
            self.assertEqual(uc.staged(T), [])
            (Path(d) / "stage.json").write_text('{"until": "2026-10-22T21:00:00Z", "note": "proof"}')
            (key, sev, msg), = uc.staged(T)
            self.assertEqual((key, sev), ("staged", "urgent"))
            self.assertIn("not a real failure", msg)
            self.assertEqual(uc.staged(T + dt.timedelta(hours=2)), [])


class Prom(unittest.TestCase):
    def test_labels_escaped_and_values_present(self):
        _, read, *_ = run(devs=devices(day=[dev("AA", 'AP "Hall"', status="offline")]))
        text = uc.prom(True, T, read, [{"severity": "urgent"}])
        self.assertIn('unifi_device_online{console="DAY",device="AP \\"Hall\\"",model="AC LR"} 0', text)
        self.assertIn('unifi_console_connected{console="MKE"} 1', text)
        self.assertIn('unifi_wan_avg_latency_ms{console="DAY"} 12', text)
        self.assertIn('unifi_problems{severity="urgent"} 1', text)


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
