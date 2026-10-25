#!/usr/bin/env python3
"""Offline test of d03/apps/att-monitor/att_check.py: what it calls a problem (stdlib unittest).

    python3 scripts/tests/test_att_check.py

The status pages are built here in the markup the BGW320-500 (software 6.35.8) served on
2026-10-25 (cgi-bin/sysinfo.ha, broadbandstatistics.ha, fiberstat.ha), cut to the rows the checker
reads; nothing reaches the network.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import tempfile
import tomllib
import unittest
from pathlib import Path

APP = Path(__file__).resolve().parents[2] / "d03" / "apps" / "att-monitor"
_spec = importlib.util.spec_from_file_location("att_check", APP / "att_check.py")
ac = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ac)
ac.urllib.request.urlopen = lambda *a, **kw: (_ for _ in ()).throw(AssertionError("network"))

with open(APP / "att-monitor.toml", "rb") as f:
    CFG = tomllib.load(f)
T = dt.datetime(2026, 10, 25, 18, 0, tzinfo=dt.timezone.utc)
STEP = dt.timedelta(minutes=5)


def row(label, value):
    return f'<tr><th scope="row" width="47%">{label}</th>\n<td class="col2">{value}</td></tr>'


def metric(name, value, alarm=(0, 0), warning=(0, 0), limits=(-292, -90, -279, -100)):
    return (f"<h1>{name}&nbsp;&nbsp;Currently {value}</h1><table><tbody>"
            f'<tr class="a"><td class="heading" scope="row">Alarm</td><td>{alarm[0]}   (Threshold {limits[0]})</td>'
            f"<td>{alarm[1]}   (Threshold {limits[1]})</td></tr>"
            f'<tr class="b"><td class="heading" scope="row">Warning</td><td>{warning[0]}   (Threshold {limits[2]})</td>'
            f"<td>{warning[1]}   (Threshold {limits[3]})</td></tr></tbody></table>")


def pages(uptime="3848400", conn="Up", line="Up", pon="OPERATION (O5)", optical="Up", ipv4="104.4.193.82",
          gw="104.4.192.1", rx=-178, rx_alarm=(0, 0), temp=42, rx_errors="0", software="6.35.8", drop=None):
    bb = [("Broadband Connection Source", "FIBER"), ("Broadband Connection", conn),
          ("Broadband IPv4 Address", ipv4), ("Gateway IPv4 Address", gw),
          ("Primary DNS", "68.94.156.10"), ("Secondary DNS", "68.94.157.10"), ("MTU", "1500"),
          ("Line State", line), ("Current Speed (Mbps)", "10000"),
          ("Global Unicast IPv6 Address", "2001:506:7b0d:1749::1"),
          ("Default IPv6 Gateway Address", "fe80::8e90:d3ff:fe25:c801"),
          ("Primary DNS", ""), ("MTU", "1500"),   # the IPv6 section repeats labels; IPv4's must win
          ("Receive Bytes", "1306837418358"), ("Transmit Bytes", "378978095743"),
          ("Receive Drops", "0"), ("Transmit Drops", "0"), ("Receive Errors", rx_errors),
          ("Transmit Errors", "0"), ("PON Link Status", pon), ("UNI Status", "up")]
    bb = [r for r in bb if r[0] != drop]
    return {
        "sysinfo": "<table>" + "".join(row(*r) for r in [("Model Number", "BGW320-500"),
                                                         ("Software Version", software),
                                                         ("Time Since Last Reboot", uptime)]) + "</table>",
        "broadbandstatistics": "<script>var x='<tr><td>a</td><td>b</td></tr>';</script><table>"
                               + "".join(row(*r) for r in bb) + "</table>",
        "fiberstat": "<table>" + row("Optical WAN Operational Status", optical) + "</table>"
                     + metric("Temperature", temp, limits=(-50, 95, -45, 90))
                     + metric("Tx Power", 33, limits=(-10, 59, 0, 49)) + metric("Rx Power", rx, alarm=rx_alarm),
    }


class Run:
    """Successive cycles 5 minutes apart on one state, as the container runs them."""

    def __init__(self, t=T):
        self.state, self.t = {}, t

    def __call__(self, cfg=CFG, error=None, **kw):
        gw = None if error else ac.read_gateway(pages(**kw))
        found, self.down = ac.check(cfg, gw, error, self.state, self.t)
        self.t += STEP
        return {k: (s, m) for k, s, m in found}


class Parse(unittest.TestCase):
    def test_rows_first_label_wins_and_scripts_ignored(self):
        r = ac.rows(pages()["broadbandstatistics"])
        self.assertEqual(r["Primary DNS"], "68.94.156.10")
        self.assertEqual(r["Gateway IPv4 Address"], "104.4.192.1")
        self.assertNotIn("a", r)

    def test_optics(self):
        o = ac.optics(pages(rx=-250)["fiberstat"])
        self.assertEqual(o["Rx Power"], {"value": -250, "alarm": [0, 0], "warning": [0, 0],
                                         "limits": [-292, -90, -279, -100]})
        self.assertEqual(o["Temperature"]["value"], 42)

    def test_uptime_forms(self):
        self.assertEqual(ac.uptime_seconds("3848400"), 3848400)
        self.assertEqual(ac.uptime_seconds("44:13:00:00"), 44 * 86400 + 13 * 3600)
        self.assertIsNone(ac.uptime_seconds("n/a"))


class Conditions(unittest.TestCase):
    def test_healthy(self):
        run = Run()
        self.assertEqual(run(), {})
        self.assertEqual(run(), {})
        self.assertIsNone(run.down)

    def test_link_down_needs_two_cycles_then_outage_on_return(self):
        run = Run()
        run()
        self.assertEqual(run(conn="Down"), {})
        found = run(conn="Down", pon="INITIAL (O1)")
        self.assertEqual(found["link:broadband-connection"][0], "urgent")
        self.assertNotIn("link:pon-link-status", found)   # its first sighting: confirmed on the next
        back = run()
        (key, (sev, msg)), = back.items()
        self.assertTrue(key.startswith("outage:"))
        self.assertEqual(sev, "urgent")
        self.assertIn("AT&T WAN was down from about 2026-10-25 13:05 CDT (18:05Z) to 2026-10-25 13:15 CDT (18:15Z)", msg)
        self.assertIn("10 min; Broadband Connection Down", msg)
        run.t += dt.timedelta(minutes=CFG["events"]["urgent_hold_minutes"])
        self.assertEqual(run(), {})

    def test_one_down_cycle_is_not_an_outage(self):
        run = Run()
        run(), run(line="Down")
        self.assertEqual(run(), {})
        self.assertNotIn("outage", run.state)
        self.assertEqual(run.state.get("events", []), [])

    def test_unreachable(self):
        run = Run()
        run()
        self.assertEqual(run(error="GET sysinfo.ha: URLError: timed out"), {})
        found = run(error="GET sysinfo.ha: URLError: timed out")
        self.assertIn("not answering from d03 (GET sysinfo.ha: URLError: timed out)", found["unreachable"][1])
        self.assertTrue(any(k.startswith("outage:") for k in run()))

    def test_optics_alarm_and_low_rx(self):
        run = Run()
        self.assertEqual(run(rx=-215), {"optics:rx-power:low": ("warn", "AT&T gateway: fiber receive power -21.5 dBm, "
                                                                        "below -21.0 dBm (baseline -17.8 dBm)")})
        run(rx=-300, rx_alarm=(1, 0))
        found = run(rx=-300, rx_alarm=(1, 0))
        self.assertEqual(found["optics:rx-power:alarm"][0], "urgent")
        self.assertEqual(run(temp=75)["optics:temperature:high"][0], "warn")

    def test_layout_change_warns_and_does_not_call_it_down(self):
        run = Run()
        found = run(drop="Line State")
        self.assertIn("no Line State", found["layout"][1])
        self.assertIsNone(run.down)


class Events(unittest.TestCase):
    def test_first_sighting_is_recorded_not_reported(self):
        run = Run()
        run()
        self.assertEqual(run.state["values"]["Gateway IPv4 Address"], "104.4.192.1")
        self.assertEqual(run.state.get("events", []), [])

    def test_gateway_change_urgent_for_the_hold_then_gone(self):
        run = Run()
        run(gw="192.168.1.254")
        found = run()
        (key, (sev, msg)), = found.items()
        self.assertTrue(key.startswith("change:gateway-ipv4-address:"))
        self.assertEqual(sev, "urgent")
        self.assertIn("Gateway IPv4 Address changed from 192.168.1.254 to 104.4.192.1", msg)
        run.t += dt.timedelta(minutes=CFG["events"]["urgent_hold_minutes"])
        self.assertEqual(run(), {})

    def test_no_change_compared_while_down(self):
        run = Run()
        run()
        run(conn="Down", ipv4="0.0.0.0")
        run(conn="Down", ipv4="0.0.0.0")
        found = run()
        self.assertFalse(any(k.startswith("change:") for k in found))

    def test_reboot_is_a_warning(self):
        run = Run()
        run()
        found = run(uptime="120")
        (key, (sev, msg)), = found.items()
        self.assertEqual(sev, "warn")
        self.assertIn("restarted at about 2026-10-25 13:03 CDT (18:03Z)", msg)

    def test_error_counter_increase_and_reset(self):
        run = Run()
        run(rx_errors="10")
        self.assertEqual(run(rx_errors="10"), {})
        found = run(rx_errors="14")
        self.assertIn("4 WAN receive errors in the last 24 h", found["counter:receive-errors"][1])
        found = run(rx_errors="3")   # reset by a reboot: the 3 count
        self.assertIn("7 WAN receive errors", found["counter:receive-errors"][1])
        run.t += dt.timedelta(hours=24)
        self.assertNotIn("counter:receive-errors", run(rx_errors="3"))


class Main(unittest.TestCase):
    def test_writes_status_prom_and_state(self):
        with tempfile.TemporaryDirectory() as d:
            ac.DATA = Path(d)
            ac.now = lambda: T
            ac.fetch = lambda base, page, timeout: pages()[page]
            self.assertEqual(ac.main(), 0)
            s = json.loads((Path(d) / "status.json").read_text())
            self.assertEqual((s["checker"], s["ok"], s["problems"]), ("att-monitor", True, []))
            self.assertEqual(s["gateway"]["gateway_ipv4"], "104.4.192.1")
            self.assertEqual(s["gateway"]["rx_power_dbm"], -17.8)
            prom = (Path(d) / "att.prom").read_text()
            self.assertIn('att_optics{metric="rx-power"} -17.8', prom)
            self.assertIn("att_link_up 1", prom)

            (Path(d) / "stage.json").write_text(json.dumps({"until": "2026-10-25T19:00:00Z", "note": "proof"}))
            ac.main()
            s = json.loads((Path(d) / "status.json").read_text())
            self.assertEqual([(p["key"], p["severity"]) for p in s["problems"]], [("staged", "urgent")])

            def down(base, page, timeout):
                raise ac.FetchError("GET sysinfo.ha: URLError: timed out")
            ac.fetch = down
            ac.main()
            s = json.loads((Path(d) / "status.json").read_text())
            self.assertEqual((s["ok"], s["gateway"]["reachable"]), (False, False))


if __name__ == "__main__":
    unittest.main(verbosity=1)
