#!/usr/bin/env python3
"""Pick tonight's winter-experiment night, heat pump or gas, from the forecast and the season so far. Read-only.

Operator 2026-11-23: "Yes, forecast bands". Strict alternation gave each 5 °F band whatever nights it
happened to get. A band's COP needs 2 gas nights (they measure the house's heat need) and 2 heat pump
nights, and the cold bands, where the question is, had no gas night. packages/hvac_experiment.yaml
runs this at 21:00 with the hourly forecast (weather.get_forecasts on weather.forecast_home, Met.no)
and sets the Ecobee's lockout from what it prints. If this fails, the automation falls back to the
old alternation, so a night is never lost.

    hvac_experiment_pick.py --unit F --forecast 2026-11-24T03:00:00+00:00=31.0,2026-11-24T04:00:00+00:00=30.4,...
    hvac_experiment_pick.py --selftest     # offline

The forecast mean is the mean of the hourly temperatures that start from 21:00 to 08:59 Chicago
time on tonight's night (at least 9 of the 12 hours). Its band is band_of(mean), the same 5 °F bands
as the mail. The season's counts are hvac_experiment.bands() over every finished night (complete
nights only, as in the mail). In that band, with g gas nights and h heat pump nights:

    gas        when g < 2 and g <= h (the band's heat need is not measured yet), or when g >= 2,
               h >= 2 and 2g < h (after the first 2 of each, one gas night for every two heat pump
               nights keeps the heat need current)
    heat pump  otherwise

It prints one JSON line: kind (heat_pump or gas), value (-15 or 65, the lockout to set), night,
mean_f, hours, band_f, gas_nights, hp_nights. Exit 0 printed; 2 Prometheus failed or the deadline
passed; 3 the forecast had too few hours for tonight. Same Prometheus and deadline as
report_hvac_cycles.py (10 s a request, 45 s in all). Standard library only.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys

import report_hvac_cycles as report
import hvac_experiment as exp

MIN_HOURS = 9
VALUE = {"heat_pump": -15, "gas": 65}


def tonight(now: dt.datetime) -> dt.date:
    """The night's date: its evening (a night runs 21:00 to 08:59)."""
    return (now.astimezone(exp.TZ) - dt.timedelta(hours=9)).date()


def parse_forecast(text: str, unit: str) -> list[tuple[int, float]]:
    """'ISO=temp,ISO=temp' as (epoch s, °F)."""
    out = []
    for item in filter(None, (p.strip() for p in text.split(","))):
        when, _, temp = item.rpartition("=")
        t = dt.datetime.fromisoformat(when.replace("Z", "+00:00"))
        if t.tzinfo is None:
            t = t.replace(tzinfo=exp.TZ)
        v = float(temp)
        out.append((int(t.timestamp()), v if unit == "F" else v * 9 / 5 + 32))
    return out


def night_mean(forecast: list[tuple[int, float]], night: dt.date) -> tuple[float | None, int]:
    """The mean °F of the forecast hours that start inside the night, and how many there were."""
    a, b = exp.night_bounds(night)
    temps = [v for ts, v in forecast if a <= ts < b]
    return (sum(temps) / len(temps) if temps else None), len(temps)


def choose(gas: int, hp: int) -> str:
    if gas < exp.MIN_NIGHTS and gas <= hp:
        return "gas"
    if gas >= exp.MIN_NIGHTS and hp >= exp.MIN_NIGHTS and 2 * gas < hp:
        return "gas"
    return "heat_pump"


def pick(mean_f: float, bands: list[dict]) -> dict:
    lo = exp.band_of(mean_f)
    b = next((x for x in bands if x["band_f"][0] == lo), {"gas_nights": 0, "hp_nights": 0})
    kind = choose(b["gas_nights"], b["hp_nights"])
    return {"kind": kind, "value": VALUE[kind], "mean_f": round(mean_f, 1), "band_f": [lo, lo + exp.BAND_F],
            "gas_nights": b["gas_nights"], "hp_nights": b["hp_nights"]}


def selftest() -> int:
    night = dt.date(2026, 11, 23)
    a, _ = exp.night_bounds(night)
    hours = [(a + i * 3600, 30.0 + i * 0.1) for i in range(-2, 14)]  # 19:00 to 10:00: 12 inside
    mean, n = night_mean(hours, night)
    band = lambda lo, g, h: {"band_f": [lo, lo + 5], "gas_nights": g, "hp_nights": h}
    bl = [band(25, 0, 1), band(30, 2, 2), band(40, 2, 5), band(50, 0, 2), band(55, 1, 0)]
    fc = parse_forecast("2026-11-24T03:00:00+00:00=-1.0,2026-11-24T04:00:00Z=0", "C")
    checks = [
        ("the night of an evening", tonight(dt.datetime(2026, 11, 23, 21, 0, tzinfo=exp.TZ)) == night),
        ("08:59 is still last night", tonight(dt.datetime(2026, 11, 24, 8, 59, tzinfo=exp.TZ)) == night),
        ("09:00 is a new day", tonight(dt.datetime(2026, 11, 24, 9, 0, tzinfo=exp.TZ)) == dt.date(2026, 11, 24)),
        ("only the 12 night hours count", n == 12 and abs(mean - 30.55) < 1e-9),
        ("°C forecast in °F", [round(v, 1) for _, v in fc] == [30.2, 32.0]),
        ("ISO with offset and Z", [ts for ts, _ in fc] == [a, a + 3600]),
        ("no gas night yet: gas", pick(27.0, bl)["kind"] == "gas"),
        ("an unseen band: gas", pick(12.0, bl) == {"kind": "gas", "value": 65, "mean_f": 12.0,
                                                        "band_f": [10, 15], "gas_nights": 0, "hp_nights": 0}),
        ("2 of each: heat pump", pick(31.0, bl)["kind"] == "heat_pump"),
        ("2 gas and 5 heat pump: gas", pick(44.9, bl)["kind"] == "gas"),
        ("gas ahead of heat pump: heat pump", pick(57.0, bl)["kind"] == "heat_pump"),
        ("0 gas and 2 heat pump: gas", pick(50.0, bl)["kind"] == "gas"),
        ("the rule", [choose(g, h) for g, h in ((0, 0), (1, 0), (1, 1), (2, 1), (2, 2), (2, 4), (2, 5), (3, 6), (3, 7))]
         == ["gas", "heat_pump", "gas", "heat_pump", "heat_pump", "heat_pump", "gas", "heat_pump", "gas"]),
        ("values", VALUE == {"heat_pump": -15, "gas": 65}),
    ]
    for name, ok in checks:
        print(f"{'ok  ' if ok else 'FAIL'} {name}")
    return 0 if all(ok for _, ok in checks) else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--forecast", default="", help="ISO=temp,... hourly (weather.get_forecasts)")
    p.add_argument("--unit", choices=("F", "C"), default="F")
    p.add_argument("--now", help="ISO time (default now), for a dry run")
    p.add_argument("--url", default=report.PROM)
    p.add_argument("--selftest", action="store_true")
    a = p.parse_args()
    if a.selftest:
        return selftest()
    now = dt.datetime.fromisoformat(a.now) if a.now else dt.datetime.now(dt.timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=exp.TZ)
    night = tonight(now)
    mean, n = night_mean(parse_forecast(a.forecast, a.unit), night)
    if mean is None or n < MIN_HOURS:
        print(f"[ERROR] the forecast has {n} of 12 hours for the night of {night}; at least {MIN_HOURS} needed",
              file=sys.stderr)
        return 3
    try:
        nights = exp.nights(a.url.rstrip("/"), report.http_get, int(now.timestamp()))
    except (report.DeadlinePassed, OSError, RuntimeError, ValueError) as e:
        print(f"[ERROR] {a.url}: {e}", file=sys.stderr)
        return 2
    out = {"night": night.isoformat(), "hours": n} | pick(mean, exp.bands(nights))
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
