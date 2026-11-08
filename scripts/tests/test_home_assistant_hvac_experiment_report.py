#!/usr/bin/env python3
"""d01 home-assistant: the winter experiment's section of the cold-spell mail (asyla/hvac_experiment.py).

    python3 scripts/tests/test_home_assistant_hvac_experiment_report.py

1. The date gate: no section on 2026-11-11 or 2027-04-08; a section from 11-12 (no night finished
   yet) through 2027-04-07, also through report_hvac_cycles.report().
2. The band math against hand values: COP 2.4 costs $0.0923 per kWh of site energy saved at gas
   $0.7083/therm and $0.0779 at $0.961, with electricity $0.19593/kWh and the furnace at 0.97; a
   band's need, COP and money from two gas and two heat pump nights (one of them mixed); a band
   short of 2+2 gives no COP.
3. The stop-rule lines: comfort stop, low COP, standby during a call, possible icing (3 defrosts in
   an hour, a long dip, both), an earlier night's stop in one line, and nothing to do.
Standard library only (no PyYAML on the host). Nothing reaches a host, Home Assistant or Prometheus.
"""
from __future__ import annotations

import datetime as dt
import sys
import unittest
from pathlib import Path

ASYLA = Path(__file__).resolve().parents[2] / "d01" / "apps" / "home-assistant" / "asyla"
sys.path.insert(0, str(ASYLA))
import report_hvac_cycles as report  # noqa: E402
import hvac_experiment as hx  # noqa: E402

TZ = hx.TZ
EMPTY = {"status": "success", "data": {"result": []}}


def local(y: int, mo: int, d: int, h: int = 0, mi: int = 0) -> int:
    return int(dt.datetime(y, mo, d, h, mi, tzinfo=TZ).timestamp())


def empty_get(url: str) -> dict:
    return EMPTY


def rec(night: str, kind: str, out_f: float = 32.0, dfh: float = 500.0, kwh: float = 0.0,
        furnace_kwh: float = 0.0, **kw) -> dict:
    """A night record as night_record() returns it, complete and calibrated."""
    r = {"night": night, "kind": kind, "stopped_at": None, "outdoor_f": out_f, "deg_f_hours": dfh, "kwh": kwh,
         "furnace_low_min": 0.0, "furnace_high_min": 0.0, "furnace_kwh": furnace_kwh,
         "furnace_minutes": {"low": 0, "high": 0, "cycles": 0}, "defrosts": [], "defrost_burst_at": None,
         "long_dips": [], "standby_call_min": 0, "standby_stretches": [], "gap_0830_f": 0.0, "held_0830": True,
         "frozen_min": 0, "frozen_spans": [], "ambient_offset_f": -1.0,
         "minutes": {"night": 720, "power": 720, "indoor": 720, "outdoor": 720}, "complete": True, "calibrated": True}
    r.update(kw)
    return r


END = local(2026, 11, 20, 9)          # a mail on Fri 11-20 09:00: the week is the nights 11-13 to 11-19
START = END - 7 * 86400 + 60


class DateGate(unittest.TestCase):
    def section(self, end: int):
        return hx.section(end - 7 * 86400 + 60, end, "http://stub", empty_get)

    def test_absent_before_and_after(self):
        self.assertIsNone(self.section(local(2026, 11, 11, 23, 59)))
        self.assertIsNone(self.section(local(2027, 4, 8)))
        self.assertIsNone(self.section(local(2026, 7, 1)))

    def test_present_from_the_first_night_to_a_week_after_the_last(self):
        first = self.section(local(2026, 11, 12, 21))
        self.assertEqual(first["nights"], [])
        self.assertEqual(first["lines"][1], "- No experiment night has finished yet; the first is Thu 11-12.")
        one = self.section(local(2026, 11, 13, 9))
        self.assertEqual([n["night"] for n in one["nights"]], ["2026-11-12"])
        self.assertEqual(one["nights"][0]["kind"], "not_running")   # no data: not counted as either kind
        last = self.section(local(2027, 4, 7, 23, 59))
        self.assertEqual(len(last["nights"]), 140)
        self.assertEqual(last["nights"][-1]["night"], "2027-03-31")
        self.assertEqual(last["week"], ["2027-03-31"])                 # the window opens 04-01 00:00
        self.assertTrue(last["lines"][0].startswith("Winter experiment: heat pump nights against gas nights"))

    def test_report_carries_it_only_in_season(self):
        self.assertIsNone(report.report(local(2026, 11, 4, 9), local(2026, 11, 11, 9), "http://stub", empty_get)
                          ["experiment"])
        r = report.report(local(2026, 11, 6, 15), local(2026, 11, 13, 15), "http://stub", empty_get)
        self.assertEqual([n["night"] for n in r["experiment"]["nights"]], ["2026-11-12"])


class BandMath(unittest.TestCase):
    def test_hand_values_at_cop_2_4(self):
        self.assertEqual((hx.E_PRICE, hx.GAS_PRICE, hx.AFUE, hx.KWH_PER_THERM), (0.19593, 0.7083, 0.97, 29.307))
        saved = 1 / 0.97 - 1 / 2.4                                   # 0.61426 kWh of site energy per kWh of heat
        self.assertAlmostEqual(hx.site_saved_per_kwh_heat(2.4), saved, places=12)
        extra = 0.19593 / 2.4 - 0.7083 / (29.307 * 0.97)             # $0.05672 per kWh of heat
        self.assertAlmostEqual(hx.extra_dollars_per_kwh_heat(2.4), extra, places=12)
        self.assertEqual(round(hx.dollars_per_kwh_saved(2.4), 4), 0.0923)
        self.assertEqual(round(hx.dollars_per_kwh_saved(2.4, g=0.961), 4), 0.0779)
        self.assertEqual(round(hx.dollars_per_kwh_saved(2.4, e=0.19593, g=0.961), 4), 0.0779)

    def nights(self) -> list[dict]:
        return [rec("2026-11-13", "gas", furnace_kwh=30.0), rec("2026-11-15", "gas", furnace_kwh=30.0),
                rec("2026-11-14", "heat_pump", kwh=12.5),                     # heat 0.06 x 500 = 30
                rec("2026-11-16", "heat_pump", kwh=10.0, furnace_kwh=6.0),    # mixed: heat 30 - 6 = 24
                rec("2026-11-17", "gas", out_f=22.0, furnace_kwh=40.0), rec("2026-11-19", "gas", out_f=24.9, furnace_kwh=40.0),
                rec("2026-11-18", "heat_pump", out_f=21.0, kwh=15.0),
                rec("2026-11-12", "heat_pump", out_f=33.0, kwh=99.0, complete=False)]  # left out: missing data

    def test_band_with_two_and_two(self):
        b = {x["band_f"][0]: x for x in hx.bands(self.nights())}
        self.assertEqual(sorted(b), [20, 30])
        b30 = b[30]
        self.assertEqual((b30["gas_nights"], b30["hp_nights"]), (2, 2))
        self.assertEqual(b30["need_kwh_per_deg_f_hour"], 0.06)        # 60 kWh / 1000 °F-hours
        self.assertEqual(b30["hp_heat_kwh"], [30.0, 24.0])
        self.assertEqual(b30["cop"], 2.4)                             # 54 / 22.5
        self.assertEqual(b30["heat_kwh_per_night"], 27.0)
        self.assertEqual(b30["site_kwh_saved_per_night"], round(27 * (1 / 0.97 - 1 / 2.4), 1))   # 16.6
        self.assertEqual(b30["extra_dollars_per_night"], 1.53)        # 27 x 0.05672
        self.assertEqual(hx.band_line(b30), "  30-35 °F: COP about 2.4 over 2 nights; it saved 17 kWh a night for "
                                            "$1.53 more, $0.09 per kWh saved; CO2 about even.")

    def test_band_short_of_two_and_two(self):
        b20 = {x["band_f"][0]: x for x in hx.bands(self.nights())}[20]
        self.assertEqual((b20["gas_nights"], b20["hp_nights"], b20["cop"]), (2, 1, None))
        self.assertEqual(b20["need_kwh_per_deg_f_hour"], 0.08)        # 80 kWh / 1000 °F-hours
        self.assertEqual(hx.band_line(b20), "  20-25 °F: 2 gas nights and 1 heat pump night so far; a COP needs 2 of each.")

    def test_season_and_left_out(self):
        exp = hx.compute(self.nights(), START, END)
        s = exp["season"]
        self.assertEqual((s["hp_nights"], s["counted"]), (4, 3))     # 11-12 is incomplete
        self.assertEqual(s["extra_dollars"], round(37.5 * 0.19593 - 94 * 0.7083 / (29.307 * 0.97), 2))
        self.assertEqual(s["site_kwh_saved"], round(94 / 0.97 - 37.5, 1))
        self.assertIn("- Left out of the estimates for missing data: Thu 11-12.", exp["lines"])


class StopRules(unittest.TestCase):
    GAS = [rec("2026-11-13", "gas", furnace_kwh=30.0), rec("2026-11-15", "gas", furnace_kwh=30.0)]

    def lines(self, nights: list[dict]) -> list[str]:
        return hx.compute(nights, START, END)["lines"]

    def test_nothing_to_do(self):
        lines = self.lines(self.GAS + [rec("2026-11-14", "heat_pump", kwh=12.5)])
        self.assertEqual(lines[1], "- Nothing in the experiment needs action now.")
        self.assertFalse(any("Earlier this season" in ln for ln in lines))

    def test_each_rule_in_order(self):
        nights = self.GAS + [
            rec("2026-11-14", "heat_pump", kwh=50.0), rec("2026-11-16", "heat_pump", kwh=50.0,   # COP 30/50 = 0.6
                                                          long_dips=[local(2026, 11, 16, 23, 40)]),
            rec("2026-11-18", "comfort_stopped", out_f=22.0, kwh=5.0, stopped_at=local(2026, 11, 19, 3),
                defrost_burst_at=local(2026, 11, 18, 22, 10), long_dips=[local(2026, 11, 18, 23, 40)],
                standby_stretches=[{"start": local(2026, 11, 19), "minutes": 21}]),
            rec("2026-11-17", "gas", out_f=22.0, defrost_burst_at=local(2026, 11, 17, 22)),   # gas night: no icing
        ]
        lines = self.lines(nights)
        self.assertEqual(lines[1:6], [
            "- The heat pump night of Wed 11-18 ended early at 03:00: the comfort stop (or the stop switch) set 35 °F "
            "and the gas furnace took over.",
            "- At 30-35 °F the heat pump's COP was about 0.6 over 2 nights, under 1.0: recommend raising the heat "
            "pump nights' floor above 35 °F; that is your call.",
            "- On the heat pump night of Wed 11-18 the outdoor unit sat at standby for 21 minutes from 00:00 while "
            "the thermostat called for heat: turn on HVAC experiment stop and check the outdoor unit.",
            "- Possible icing on the heat pump night of Mon 11-16: the outdoor unit still under 1 kW 15 minutes after "
            "a defrost at 23:40: turn on HVAC experiment stop and look at the coil.",
            "- Possible icing on the heat pump night of Wed 11-18: 3 defrosts within an hour from 22:10 and the "
            "outdoor unit still under 1 kW 15 minutes after a defrost at 23:40: turn on HVAC experiment stop and "
            "look at the coil.",
        ])
        self.assertFalse(any("11-17" in ln and "icing" in ln.lower() for ln in lines))
        self.assertIn("the comfort stop handed it to the gas furnace at 03:00", lines[6])

    def test_burst_alone_and_earlier_nights_in_one_line(self):
        nights = self.GAS + [
            rec("2026-11-12", "heat_pump", kwh=12.5, standby_stretches=[{"start": local(2026, 11, 13, 1), "minutes": 30}]),
            rec("2026-11-10", "comfort_stopped", kwh=5.0, stopped_at=None),
            rec("2026-11-14", "heat_pump", kwh=12.5, defrost_burst_at=local(2026, 11, 14, 22, 10)),
        ]
        lines = self.lines(nights)
        self.assertEqual(lines[1], "- Possible icing on the heat pump night of Sat 11-14: 3 defrosts within an hour "
                                   "from 22:10: turn on HVAC experiment stop and look at the coil.")
        self.assertEqual(lines[2], "- Earlier this season: comfort stop Tue 11-10; standby Thu 11-12.")


if __name__ == "__main__":
    unittest.main(verbosity=2)
