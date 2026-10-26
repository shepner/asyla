#!/usr/bin/env python3
"""Offline test of d03/apps/switch-monitor/switch_check.py: what it calls a problem (stdlib unittest).

    python3 scripts/tests/test_switch_check.py

The exporter answers are built here with the metric and label names of snmp_exporter v0.30.1's
stock modules (system, if_mib, mikrotik; read from the image's snmp.yml 2026-10-25) and our
aruba module; the values are switch1's as read over SSH that day, and switch2's as walked from d03
on 2026-10-26. Nothing reaches the network.
"""
from __future__ import annotations

import contextlib
import datetime as dt
import importlib.util
import io
import json
import re
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

APP = Path(__file__).resolve().parents[2] / "d03" / "apps" / "switch-monitor"
_spec = importlib.util.spec_from_file_location("switch_check", APP / "switch_check.py")
sc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sc)
sc.urllib.request.urlopen = lambda *a, **kw: (_ for _ in ()).throw(AssertionError("network"))

with open(APP / "switch-monitor.toml", "rb") as f:
    CFG = tomllib.load(f)
S1 = CFG["switches"]["switch1"]
S2 = CFG["switches"]["switch2"]
UPLINK2 = "gigabitethernet0/1/0"
T = dt.datetime(2026, 10, 25, 20, 0, tzinfo=dt.timezone.utc)
FIVE = dt.timedelta(minutes=5)
DAY = 86400
WATCHED = list(S1["ports"])


def lab(**kw) -> str:
    return "{" + ",".join(f'{k}="{v}"' for k, v in kw.items()) + "}"


def port(ifname, admin=1, oper=1, errors=0, discards=0, last_change=100, downs=0):
    return {"name": ifname, "admin": admin, "oper": oper, "errors": errors, "discards": discards,
            "last_change": last_change, "downs": downs}


def scrape(uptime=153 * DAY, ports=None, gauges=None, units=True, optics=None, version="7.21.4",
           fw=("7.21.4", "7.21.4"), aruba=None, mikrotik=True) -> str:
    """The exporter's text for one switch: uptime in seconds, ports as port() dicts."""
    ports = ports if ports is not None else [port(p) for p in WATCHED] + [port("ether2")]
    out = ["# HELP sysUpTime The time (in hundredths of a second) since ... - 1.3.6.1.2.1.1.3",
           "# TYPE sysUpTime gauge", f"sysUpTime {uptime * 100:.6g}"]
    for i, p in enumerate(ports, 1):
        il = lab(ifAlias=p["name"], ifDescr=p["name"], ifIndex=i, ifName=p["name"])
        out += [f"ifAdminStatus{il} {p['admin']}", f"ifOperStatus{il} {p['oper']}",
                f"ifLastChange{il} {p['last_change']}",
                f"ifInErrors{il} {p['errors']}", f"ifOutErrors{il} 0",
                f"ifInDiscards{il} {p['discards']}", f"ifOutDiscards{il} 0"]
        if mikrotik:
            out.append(f"mtxrInterfaceStatsLinkDowns{lab(ifName=p['name'], mtxrInterfaceStatsIndex=i)} {p['downs']}")
    if mikrotik:
        g = gauges if gauges is not None else {"sfp-temperature": (48, 1), "switch-temperature": (49, 1),
                                               "fan1-speed": (3870, 2), "fan2-speed": (3960, 2),
                                               "fan-state": (0, 6), "psu1-state": (0, 6), "psu2-state": (0, 6)}
        for name, (v, unit) in g.items():
            out.append(f"mtxrGaugeValue{lab(mtxrGaugeName=name)} {v}")
            if units:
                out.append(f"mtxrGaugeUnit{lab(mtxrGaugeName=name)} {unit}")
        o = optics if optics is not None else {"sfp-sfpplus9": (-2754, -2150, 44, 0),
                                               "sfp-sfpplus17": (-2800, -2400, 48, 0)}
        for name, (rx, tx, temp, fault) in o.items():
            ol = lab(mtxrOpticalIndex=9, mtxrOpticalName=name)
            out += [f"mtxrOpticalRxPower{ol} {rx}", f"mtxrOpticalTxPower{ol} {tx}",
                    f"mtxrOpticalTemperature{ol} {temp}", f"mtxrOpticalTxFault{ol} {fault}"]
        out += [f"mtxrLicVersion{lab(mtxrLicVersion=version)} 1",
                f"mtxrFirmwareVersion{lab(mtxrFirmwareVersion=fw[0])} 1",
                f"mtxrFirmwareUpgradeVersion{lab(mtxrFirmwareUpgradeVersion=fw[1])} 1"]
    if aruba is not None:
        a = {"fans": [1, 1, 1, 1], "psus": [1], "temp": 52.5, "slot": (400, 38), "poe_ports": {1: 1, 3: 1, 14: 7}} | aruba
        out.append(f'sysDescr{lab(sysDescr="ArubaOS (MODEL: ArubaS2500-48P-US), Version 7.4.1.10 (65516)")} 1')
        out += [f"sysExtFanStatus{lab(sysExtFanIndex=i)} {v}" for i, v in enumerate(a["fans"])]
        out += [f"sysExtPowerSupplyStatus{lab(sysExtPowerSupplyIndex=i)} {v}" for i, v in enumerate(a["psus"])]
        out.append(f"wlsxSysExtInternalTemparature {a['temp']}")
        out += [f"wlsxPseSlotPowerAvailable{lab(wlsxPseSlotIndex=0)} {a['slot'][0]}",
                f"wlsxPseSlotPowerConsumption{lab(wlsxPseSlotIndex=0)} {a['slot'][1]}"]
        out += [f"wlsxPsePortStatus{lab(wlsxPsePortIndex=i)} {v}" for i, v in a["poe_ports"].items()]
    return "\n".join(out) + "\n"


def aruba_scrape(ports=None, **aruba) -> str:
    """switch2 as walked from d03 on 2026-10-26: its uplink and some copper ports, health, PoE."""
    ports = ports if ports is not None else [port("gigabitethernet0/0/0"), port("gigabitethernet0/0/1", oper=2),
                                             port("gigabitethernet0/0/2"), port(UPLINK2)]
    return scrape(uptime=399 * DAY, ports=ports, mikrotik=False, aruba=aruba)


def aged(text: str, seconds: float) -> str:
    """The same scrape `seconds` later: sysUpTime moved on, as on a switch that did not restart."""
    return re.sub(r"^sysUpTime (\S+)$", lambda m: f"sysUpTime {float(m.group(1)) + seconds * 100:.6g}",
                  text, flags=re.M)


def run(text=None, prev=None, t=T, release=None, cfg=CFG, scfg=S1):
    """One evaluate() of switch1: ({key: (severity, message)} of found + held, summary, new prev)."""
    found, held, summary, new = sc.evaluate(cfg, "switch1", scfg, sc.samples(text or scrape()),
                                            {} if prev is None else prev, t, release)
    return {k: (s, m) for k, s, m in found + held}, summary, new


def two(first, second, **kw):
    """Two cycles five minutes apart: the findings of the second."""
    _, _, prev = run(aged(first, -300), t=T - FIVE)
    return run(second, prev=prev, **kw)[0]


class Samples(unittest.TestCase):
    def test_comments_nan_and_exponents(self):
        rows = sc.samples("# HELP x y\n# TYPE x gauge\nx 1.326e+09\ny NaN\nz{a=\"b\"} -2754\n")
        self.assertEqual(rows, [("x", {}, 1.326e9), ("z", {"a": "b"}, -2754.0)])

    def test_escaped_labels(self):
        line = r'ifOperStatus{ifAlias="nas \"01\" C:\\x} 3\nnext",ifIndex="9",ifName="sfp-sfpplus9"} 1'
        (name, labels, v), = sc.samples(line)
        self.assertEqual((name, v), ("ifOperStatus", 1.0))
        self.assertEqual(labels, {"ifAlias": 'nas "01" C:\\x} 3\nnext', "ifIndex": "9", "ifName": "sfp-sfpplus9"})


class Ports(unittest.TestCase):
    def test_all_well_is_quiet(self):
        found, summary, _ = run()
        self.assertEqual(found, {})
        self.assertEqual(summary, {"reachable": True, "uptime_hours": 3672.0, "ports": 10,
                                   "watched_up": "9/9", "version": "7.21.4"})

    def test_watched_port_down_is_urgent(self):
        text = scrape(ports=[port(p, oper=2 if p == "sfp-sfpplus9" else 1) for p in WATCHED])
        found, summary, _ = run(text)
        self.assertEqual(found, {"switch1:port:sfp-sfpplus9:down": ("urgent", "switch1: port sfp-sfpplus9 (nas01 ix0) is down")})
        self.assertEqual(summary["watched_up"], "8/9")

    def test_admin_down_and_unwatched_ports_are_quiet(self):
        text = scrape(ports=[port(p, admin=2 if p == "sfp-sfpplus9" else 1, oper=2 if p == "sfp-sfpplus9" else 1)
                             for p in WATCHED] + [port("ether2", oper=2)])
        self.assertEqual(run(text)[0], {})

    def test_missing_watched_port_is_urgent(self):
        found, *_ = run(scrape(ports=[port(p) for p in WATCHED if p != "sfp-sfpplus1"]))
        self.assertEqual(found["switch1:port:sfp-sfpplus1:missing"][0], "urgent")

    def test_errors_rate_on_any_port(self):
        found = two(scrape(), scrape(ports=[port(p) for p in WATCHED] + [port("ether2", errors=5)]))
        self.assertEqual(found["switch1:port:ether2:errors"][0], "warn")
        self.assertIn("5 errors in 5 min (over 10/h)", found["switch1:port:ether2:errors"][1])

    def test_errors_under_the_rate_are_quiet(self):
        later = scrape(ports=[port(p) for p in WATCHED] + [port("ether2", errors=5)])
        _, _, prev = run(aged(scrape(), -3600), t=T - dt.timedelta(hours=1))
        self.assertEqual(run(later, prev=prev)[0], {}, "5 in an hour is under 10/h")

    def test_discards_on_watched_ports_only(self):
        busy = scrape(ports=[port(p, discards=200 if p == "sfp-sfpplus10" else 0) for p in WATCHED]
                      + [port("ether2", discards=5000)])
        found = two(scrape(), busy)
        self.assertEqual(list(found), ["switch1:port:sfp-sfpplus10:discards"])
        self.assertIn("sfp-sfpplus10 (nas01 ix1): 200 discards", found["switch1:port:sfp-sfpplus10:discards"][1])

    def test_flap_by_link_downs(self):
        found = two(scrape(), scrape(ports=[port(p, downs=2 if p == "sfp-sfpplus19" else 0) for p in WATCHED]))
        self.assertEqual(found["switch1:port:sfp-sfpplus19:flap"][0], "warn")
        self.assertIn("went down 2 time(s) between 2026-10-25T19:55:00Z and 2026-10-25T20:00:00Z",
                      found["switch1:port:sfp-sfpplus19:flap"][1])

    def test_flap_by_last_change_without_link_downs(self):
        before = scrape(ports=[port(p) for p in WATCHED], mikrotik=False)
        after = scrape(ports=[port(p, last_change=999 if p == "sfp-sfpplus5" else 100) for p in WATCHED], mikrotik=False)
        found = two(before, after)
        self.assertEqual(list(found), ["switch1:port:sfp-sfpplus5:flap"])
        self.assertIn("changed state", found["switch1:port:sfp-sfpplus5:flap"][1])

    def test_link_downs_win_over_last_change(self):
        after = scrape(ports=[port(p, last_change=999) for p in WATCHED])
        self.assertEqual(two(scrape(), after), {}, "a MikroTik port with no new link-down is not a flap")

    def test_first_cycle_has_no_rates(self):
        self.assertEqual(run(scrape(ports=[port(p, errors=10 ** 6, downs=50) for p in WATCHED]))[0], {})


class Restart(unittest.TestCase):
    def test_recent_restart_is_a_warning_for_a_day(self):
        found, *_ = run(scrape(uptime=3 * 3600))
        self.assertEqual(found["switch1:restarted"],
                         ("warn", "switch1: restarted at 2026-10-25T17:00:00Z (SNMP uptime 3.0 h)"))
        self.assertNotIn("switch1:restarted", run(scrape(uptime=25 * 3600))[0])

    def test_counters_reset_across_a_restart_give_no_rate(self):
        _, _, prev = run(scrape(ports=[port(p, errors=500, downs=3) for p in WATCHED]), t=T - FIVE)
        found, *_ = run(scrape(uptime=120, ports=[port(p, errors=600, downs=9) for p in WATCHED]), prev=prev)
        self.assertEqual(list(found), ["switch1:restarted"], "a new baseline, not a rate across the reboot")

    def test_missing_uptime_is_urgent(self):
        text = "\n".join(l for l in scrape().splitlines() if not l.startswith("sysUpTime"))
        self.assertEqual(run(text)[0]["switch1:no-uptime"][0], "urgent")


class Health(unittest.TestCase):
    def gauges(self, **over):
        g = {"sfp-temperature": (48, 1), "switch-temperature": (49, 1), "fan1-speed": (3870, 2),
             "fan-state": (0, 6), "psu1-state": (0, 6), "psu2-state": (0, 6), "voltage": (240, 3)}
        g.update({k.replace("_", "-"): v for k, v in over.items()})
        return g

    def test_temperature_warn_then_urgent(self):
        self.assertEqual(run(scrape(gauges=self.gauges(switch_temperature=(66, 1))))[0]["switch1:health:switch-temperature"][0], "warn")
        self.assertEqual(run(scrape(gauges=self.gauges(switch_temperature=(75, 1))))[0]["switch1:health:switch-temperature"],
                         ("urgent", "switch1: switch-temperature 75 C (limit 75 C)"))

    def test_fan_slow_and_states_not_ok_are_urgent(self):
        found, *_ = run(scrape(gauges=self.gauges(fan1_speed=(0, 2), psu2_state=(1, 6))))
        self.assertEqual(found["switch1:health:fan1-speed"][0], "urgent")
        self.assertEqual(found["switch1:health:psu2-state"], ("urgent", "switch1: psu2-state is not ok (value 1)"))
        self.assertEqual(len(found), 2, "voltage (dV) is not watched")

    def test_state_ok_value_is_configurable(self):
        cfg = CFG | {"state_ok_value": 1}
        found, *_ = run(scrape(gauges=self.gauges(fan_state=(1, 6), psu1_state=(1, 6), psu2_state=(1, 6))), cfg=cfg)
        self.assertEqual(found, {})

    def test_unit_wins_over_name(self):
        found, *_ = run(scrape(gauges={"board-temperature1": (80, 1), "odd-state": (90, 1)}))
        self.assertEqual(found["switch1:health:board-temperature1"][0], "urgent")
        self.assertEqual(found["switch1:health:odd-state"][0], "urgent", "unit celsius: a temperature")

    def test_names_when_units_are_absent(self):
        found, *_ = run(scrape(gauges=self.gauges(fan2_speed=(10, 2), psu1_state=(1, 6)), units=False))
        self.assertEqual(sorted(found), ["switch1:health:fan2-speed", "switch1:health:psu1-state"])

    def test_optics_scaled_and_watched_ports_only(self):
        o = {"sfp-sfpplus9": (-12000, -2150, 44, 0), "sfp-sfpplus17": (-2800, -7000, 71, 1),
             "sfp-sfpplus24": (-40000, -40000, 90, 1)}
        found, *_ = run(scrape(optics=o))
        self.assertEqual(found["switch1:optic:sfp-sfpplus9:rx"],
                         ("warn", "switch1: sfp-sfpplus9 (nas01 ix0) optic rx power -12.0 dBm (under -10.0 dBm)"))
        self.assertEqual(sorted(k for k in found if "sfpplus17" in k),
                         ["switch1:optic:sfp-sfpplus17:temp", "switch1:optic:sfp-sfpplus17:tx",
                          "switch1:optic:sfp-sfpplus17:txfault"])
        self.assertFalse([k for k in found if "sfpplus24" in k], "an unwatched cage")


class Firmware(unittest.TestCase):
    def test_release_waits_seven_days_from_first_sight(self):
        _, _, prev = run(release="7.23.8")
        self.assertEqual(prev["release_seen"], {"7.23.8": "2026-10-25T20:00:00Z"})
        found, _, prev = run(prev=prev, t=T + dt.timedelta(days=6, hours=23), release="7.23.8")
        self.assertNotIn("switch1:release", found)
        found, _, prev = run(prev=prev, t=T + dt.timedelta(days=7), release="7.23.8")
        self.assertEqual(found["switch1:release"],
                         ("warn", "switch1: RouterOS 7.23.8 (long-term) is out since at least 2026-10-25; it runs 7.21.4"))
        _, _, prev = run(scrape(version="7.23.8", fw=("7.23.8", "7.23.8")), prev=prev,
                         t=T + dt.timedelta(days=8), release="7.23.8")
        self.assertEqual(prev["release_seen"], {}, "an applied upgrade forgets the first sight")

    def test_a_newer_release_starts_its_own_wait(self):
        _, _, prev = run(release="7.23.8")
        found, _, prev = run(prev=prev, t=T + dt.timedelta(days=8), release="7.23.9")
        self.assertNotIn("switch1:release", found)
        self.assertEqual(list(prev["release_seen"]), ["7.23.9"])

    def test_same_or_older_release_is_quiet(self):
        self.assertEqual(run(release="7.21.4")[0], {})
        self.assertEqual(run(release="7.20.8")[0], {})
        self.assertEqual(run(release=None)[0], {})

    def test_routerboard_behind(self):
        found, *_ = run(scrape(fw=("7.21.4", "7.23.8")))
        self.assertEqual(found["switch1:routerboard"][0], "warn")

    def test_version_compare_is_numeric(self):
        self.assertGreater(sc.version_tuple("7.10.1"), sc.version_tuple("7.9.3"))
        self.assertEqual(sc.version_tuple("7.21.4 (long-term)"), (7, 21, 4))


class Aruba(unittest.TestCase):
    """switch2's findings (evaluate() names every switch switch1 here; the keys say so)."""

    def test_as_read_is_quiet(self):
        found, summary, _ = run(aruba_scrape(), scfg=S2)
        self.assertEqual(found, {})
        self.assertEqual(summary, {"reachable": True, "uptime_hours": 9576.0, "ports": 4,
                                   "watched_up": "1/1", "version": "7.4.1.10"})

    def test_uplink_down_is_urgent(self):
        found, *_ = run(aruba_scrape(ports=[port("gigabitethernet0/0/0"), port(UPLINK2, oper=2)]), scfg=S2)
        self.assertEqual(found, {f"switch1:port:{UPLINK2}:down":
                                 ("urgent", f"switch1: port {UPLINK2} (trunk: switch1 sfp-sfpplus5) is down")})

    def test_uplink_flap_by_last_change(self):
        later = aruba_scrape(ports=[port("gigabitethernet0/0/0"), port(UPLINK2, last_change=999)])
        found = two(aruba_scrape(ports=[port("gigabitethernet0/0/0"), port(UPLINK2)]), later, scfg=S2)
        self.assertEqual(list(found), [f"switch1:port:{UPLINK2}:flap"])

    def test_fan_or_psu_inactive_is_urgent(self):
        found, *_ = run(aruba_scrape(fans=[1, 2, 1, 1], psus=[2]), scfg=S2)
        self.assertEqual(found, {"switch1:health:fan1": ("urgent", "switch1: fan 1 is not active (value 2)"),
                                 "switch1:health:psu0": ("urgent", "switch1: psu 0 is not active (value 2)")})

    def test_temperature_warn_then_urgent(self):
        self.assertEqual(run(aruba_scrape(temp=65.5), scfg=S2)[0],
                         {"switch1:health:temperature": ("warn", "switch1: temperature 66 C (over 65 C)")})
        self.assertEqual(run(aruba_scrape(temp=75), scfg=S2)[0]["switch1:health:temperature"][0], "urgent")

    def test_poe_budget(self):
        found, *_ = run(aruba_scrape(slot=(400, 330)), scfg=S2)
        self.assertEqual(found, {"switch1:poe:0:budget": ("warn", "switch1: PoE draws 330 W of 400 W (over 80%)")})
        self.assertEqual(run(aruba_scrape(slot=(400, 320)), scfg=S2)[0], {}, "80 % is not over 80 %")
        self.assertEqual(run(aruba_scrape(slot=(0, 0)), scfg=S2)[0], {}, "no budget, no ratio")

    def test_poe_port_hardware_error_named_by_ifindex(self):
        found, *_ = run(aruba_scrape(poe_ports={1: 6, 3: 1, 9: 6}), scfg=S2)
        self.assertEqual(found, {
            "switch1:poe:gigabitethernet0/0/0:hardware-error":
                ("warn", "switch1: port gigabitethernet0/0/0 gives no PoE: hardware error"),
            "switch1:poe:PoE port 9:hardware-error": ("warn", "switch1: port PoE port 9 gives no PoE: hardware error")})

    def test_non_standard_device_and_searching_ports_are_quiet(self):
        self.assertEqual(run(aruba_scrape(poe_ports={i: v for i, v in enumerate((1, 2, 3, 5, 7), 1)}), scfg=S2)[0], {})


class Confirm(unittest.TestCase):
    def test_urgent_waits_for_two_checks_in_a_row(self):
        state = {}
        off = [("switch1:port:x:down", "urgent", "m"), ("w", "warn", "m")]
        self.assertEqual([k for k, *_ in sc.confirm(off, state, 2)], ["w"])
        self.assertEqual([k for k, *_ in sc.confirm(off, state, 2)], ["switch1:port:x:down", "w"])
        sc.confirm([], state, 2)
        self.assertEqual(sc.confirm(off[:1], state, 2), [], "a gap starts the count again")


class Hold(unittest.TestCase):
    def test_counter_warning_kept_for_hold_hours(self):
        state = {}
        self.assertEqual(sc.hold([("k", "warn", "m")], state, T, 24), [("k", "warn", "m")])
        self.assertEqual(sc.hold([], state, T + dt.timedelta(hours=24), 24), [("k", "warn", "m")])
        self.assertEqual(sc.hold([], state, T + dt.timedelta(hours=24, minutes=5), 24), [])
        self.assertEqual(state["held"], {})


class Main(unittest.TestCase):
    """Whole cycles through main(): the exporter faked by URL, files in a temporary SWITCH_DATA."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.data = Path(self.tmp.name)
        sc.DATA, sc.CONFIG, self.t = self.data, APP / "switch-monitor.toml", T
        sc.now = lambda: self.t
        self.answer = scrape()   # switch1's text, or a FetchError to raise for it
        self.answer2 = aruba_scrape()   # switch2's
        self.exporter_up = True
        self.urls = []
        sc.fetch = self.fetch

    def tearDown(self):
        self.tmp.cleanup()

    def fetch(self, url, timeout=120):
        self.urls.append(url)
        if url.startswith("https://upgrade.mikrotik.com/"):
            return "7.23.8 1791452776\n"
        if not self.exporter_up:
            raise sc.FetchError("URLError: [Errno 111] Connection refused")
        if url.endswith("/"):
            return "<html>snmp exporter</html>"
        answer = self.answer2 if "target=10.0.0.41&" in url else self.answer
        if isinstance(answer, Exception):
            raise answer
        return aged(answer, (self.t - T).total_seconds())

    def cycle(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(sc.main(), 0)
        self.t += FIVE
        return json.loads((self.data / "status.json").read_text())

    def test_healthy_cycle_writes_status(self):
        s = self.cycle()
        self.assertEqual((s["checker"], s["ok"], s["problems"]), ("switch-monitor", True, []))
        self.assertEqual(s["switches"]["switch1"]["watched_up"], "9/9")
        self.assertEqual(s["switches"]["switch2"]["watched_up"], "1/1")
        self.assertEqual(s["switches"]["switch3"], {"reachable": None, "note": "not watched yet (enabled = false)"})
        self.assertEqual([u for u in self.urls if "snmp?" in u],
                         ["http://snmp-exporter:9116/snmp?target=192.168.88.1&module=system%2Cif_mib%2Cmikrotik&auth=asyla_v3",
                          "http://snmp-exporter:9116/snmp?target=10.0.0.41&module=system%2Cif_mib%2Caruba&auth=asyla_v3"])
        self.assertIn("https://upgrade.mikrotik.com/routeros/NEWESTa7.long-term", self.urls)
        state = json.loads((self.data / "state.json").read_text())
        self.assertEqual(state["switches"]["switch1"]["release_seen"], {"7.23.8": "2026-10-25T20:00:00Z"})

    def test_feed_read_once_a_day(self):
        self.cycle()
        self.cycle()
        self.assertEqual(sum(u.startswith("https://") for u in self.urls), 1)

    def test_switch_not_answering_is_urgent_on_the_second_check(self):
        self.answer = sc.FetchError("HTTP 500: error walking target 192.168.88.1: request timeout (after 3 retries)")
        self.assertEqual(self.cycle()["problems"], [])
        s = self.cycle()
        self.assertEqual([(p["key"], p["severity"]) for p in s["problems"]], [("switch1:unreachable", "urgent")])
        self.assertIn("not answering SNMP: HTTP 500", s["problems"][0]["message"])
        self.assertTrue(s["ok"])

    def test_a_walk_that_times_out_is_the_switch_not_the_exporter(self):
        self.answer = sc.FetchError("TimeoutError: timed out")
        self.cycle()
        s = self.cycle()
        self.assertEqual([p["key"] for p in s["problems"]], ["switch1:unreachable"])
        self.assertTrue(s["ok"])

    def test_exporter_down_is_urgent_at_the_third_check(self):
        self.exporter_up = False
        sev = [[p["severity"] for p in self.cycle()["problems"]] for _ in range(3)]
        self.assertEqual(sev, [["warn"], ["warn"], ["urgent"]])
        self.exporter_up = True
        s = self.cycle()
        self.assertEqual((s["ok"], s["problems"]), (True, []))

    def test_held_warning_survives_quiet_cycles(self):
        self.cycle()
        self.answer = scrape(ports=[port(p) for p in WATCHED] + [port("ether2", errors=50)])
        self.cycle()
        self.answer = scrape(ports=[port(p) for p in WATCHED] + [port("ether2", errors=50)])
        s = self.cycle()
        self.assertEqual([p["key"] for p in s["problems"]], ["switch1:port:ether2:errors"])

    def test_staged_alert(self):
        (self.data / "stage.json").write_text('{"until": "2026-10-25T21:00:00Z", "note": "proof"}')
        s = self.cycle()
        self.assertEqual([(p["key"], p["severity"]) for p in s["problems"]], [("staged", "urgent")])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
