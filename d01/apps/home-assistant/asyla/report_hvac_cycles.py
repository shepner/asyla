#!/usr/bin/env python3
"""Report HVAC runs and short cycling per day from Emporia minute power and Home Assistant. Read-only.

Backlog 2026-10-27-home-automation-hvac-schedule-optimiser-lowest-energy-heating-and-cooling-sc,
step 0: count runs, run lengths and runs per hour for the house air handler, the heat pump's
outdoor unit and the garage boiler, before any setting or schedule is proposed. It reads theOrg's
trends Prometheus (ASY-TRD-1) with GET only and changes nothing.

    report_hvac_cycles.py                    # the last 7 days, per local (Chicago) day
    report_hvac_cycles.py --days 14 --json   # machine-readable
    report_hvac_cycles.py --start 2026-10-21T23:08Z --end 2026-10-28T22:57Z
    report_hvac_cycles.py --selftest         # offline, against stubbed series

Emporia House channels are CT ports, not breakers (step 0 findings in the backlog item):
7 "Furnace" is the air handler (blower), 98 "AC" the outdoor unit (3+4 combined), 14 "Boiler" the
boiler. Emporia's sample at minute T is the mean watts over the minute starting at T. Each minute is:

    heat_pump   outdoor unit > 500 W with the air handler (heat pump heat or cool; no gas)
    outdoor     outdoor unit > 500 W, air handler off (defrost or a fault: worth a look)
    air_handler air handler > 40 W alone (gas furnace or fan only; power cannot tell them apart)
    boiler      boiler > 40 W (independent of the house classes)

A run is a stretch of consecutive minutes in one class; a missing minute ends it. An air-handler run
of at most 2 minutes that starts the minute an outdoor-unit run ends is the blower running on after
the compressor stops (seen after both heat pump runs, 2026-10-22 and 10-27): it is counted as
"overrun" on the heat pump, not as an air-handler run. "Most per hour" is
the most runs starting in one clock hour. Where the window has them (from 2026-10-28), Home
Assistant's climate action minutes per entity and the outdoor temperature (sensor.mke_temperature)
are added. Every series is fetched on the same minute grid (separate queries otherwise return
different grids), with a 59 s lookback so a minute never borrows its neighbour's value.

Exit 0 report printed, 2 the Prometheus query failed.

This copy in asyla-hosts d01/apps/home-assistant/asyla/ is the only one: Home Assistant runs it at a
cold spell (packages/hvac.yaml), and the asyla hub's tools/report_hvac_cycles.py runs it from the
hub's projects/asyla-hosts clone. Standard library only: it runs on the Home Assistant image's python3.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import statistics
import sys
import urllib.parse
import urllib.request
from collections import defaultdict
from zoneinfo import ZoneInfo

# theOrg's trends Prometheus on the Mini (theOrg observability PR 240; ASY-TRD); no login.
PROM = "http://10.0.0.150:9107"
TZ = ZoneInfo("America/Chicago")
STEP = 60
MAX_POINTS = 10000  # Prometheus refuses more than 11000 points per series per query

EMPORIA = 'last_over_time(emporia_channel_power_watts{device="House",channel=~"7|14|98"}[59s])'
HA_ACTION = 'last_over_time(homeassistant_climate_action{entity=~"climate\\\\..*"}[59s]) == 1'
HA_OUTDOOR = 'last_over_time(homeassistant_sensor_temperature_celsius{entity="sensor.mke_temperature"}[59s])'
AIR_HANDLER_W, OUTDOOR_W, BOILER_W = 40.0, 500.0, 40.0
SHORT_MIN = 5
OVERRUN_MAX = 2
CLASSES = ["heat_pump", "outdoor", "air_handler", "boiler"]
QUIET = {"idle", "off"}


def http_get(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


def query_range(base: str, expr: str, start: int, end: int, get=http_get) -> list[dict]:
    """Every series of expr on the minute grid start..end (inclusive), in chunks under the point limit."""
    out: dict[tuple, dict] = {}
    t = start
    while t <= end:
        t_end = min(end, t + (MAX_POINTS - 1) * STEP)
        q = urllib.parse.urlencode({"query": expr, "start": t, "end": t_end, "step": STEP})
        body = get(f"{base}/api/v1/query_range?{q}")
        if body.get("status") != "success":
            raise RuntimeError(f"query failed: {body.get('errorType')}: {body.get('error')}")
        for s in body["data"]["result"]:
            key = tuple(sorted(s["metric"].items()))
            out.setdefault(key, {"metric": s["metric"], "values": {}})["values"].update(
                {int(float(ts)): float(v) for ts, v in s["values"]})
        t = t_end + STEP
    return list(out.values())


def classify(minutes: list[int], power: dict[str, dict[int, float]]) -> dict[str, list[int | None]]:
    """Per class, the minute timestamps in that class; None marks a minute with no data (a run break)."""
    ah, ou, bo = power.get("7", {}), power.get("98", {}), power.get("14", {})
    marks: dict[str, list] = {c: [] for c in CLASSES}
    for m in minutes:
        house = None
        if m in ah and m in ou:
            on_ah, on_ou = ah[m] > AIR_HANDLER_W, ou[m] > OUTDOOR_W
            house = "heat_pump" if on_ah and on_ou else "outdoor" if on_ou else "air_handler" if on_ah else ""
        for c in ("heat_pump", "outdoor", "air_handler"):
            marks[c].append(None if house is None else (m if house == c else 0))
        marks["boiler"].append(None if m not in bo else (m if bo[m] > BOILER_W else 0))
    return marks


def runs(marks: list[int | None]) -> list[tuple[int, int]]:
    """(start minute, length in minutes) of each stretch of consecutive on-minutes."""
    found, start, n = [], None, 0
    for m in marks + [None]:
        if m:
            start, n = (m, 1) if start is None else (start, n + 1)
        elif start is not None:
            found.append((start, n))
            start, n = None, 0
    return found


def split_overrun(ah: list[tuple[int, int]], outdoor: list[tuple[int, int]]) -> tuple[list, int]:
    """Air-handler runs without the blower overruns that directly follow an outdoor-unit run."""
    ends = {s + n * STEP for s, n in outdoor}
    kept = [r for r in ah if not (r[0] in ends and r[1] <= OVERRUN_MAX)]
    return kept, len(ah) - len(kept)


def day_of(ts: int) -> str:
    return dt.datetime.fromtimestamp(ts, TZ).strftime("%Y-%m-%d")


def summarise(rs: list[tuple[int, int]]) -> dict:
    if not rs:
        return {"runs": 0, "minutes": 0}
    lengths = [n for _, n in rs]
    per_hour = defaultdict(int)
    for s, _ in rs:
        per_hour[s // 3600] += 1
    return {"runs": len(rs), "minutes": sum(lengths), "median": statistics.median(lengths),
            "shortest": min(lengths), "longest": max(lengths),
            "short": sum(1 for n in lengths if n < SHORT_MIN), "most_per_hour": max(per_hour.values()),
            "starts": [dt.datetime.fromtimestamp(s, TZ).strftime("%m-%d %H:%M") + f" {n}m" for s, n in rs]}


def report(start: int, end: int, base: str = PROM, get=http_get) -> dict:
    minutes = list(range(start, end + 1, STEP))
    power: dict[str, dict[int, float]] = {}
    for s in query_range(base, EMPORIA, start, end, get):
        power[s["metric"]["channel"]] = s["values"]
    marks = classify(minutes, power)
    days = sorted({day_of(m) for m in minutes})
    out = {"start": start, "end": end, "minutes": len(minutes),
           "data_minutes": {ch: len(power.get(ch, {})) for ch in ("7", "98", "14")},
           "days": {d: {} for d in days}, "total": {}}
    found = {c: runs(marks[c]) for c in CLASSES}
    found["air_handler"], overrun = split_overrun(found["air_handler"],
                                                  sorted(found["heat_pump"] + found["outdoor"]))
    out["blower_overrun"] = overrun
    for c in CLASSES:
        rs = found[c]
        out["total"][c] = summarise(rs)
        by_day = defaultdict(list)
        for r in rs:
            by_day[day_of(r[0])].append(r)
        for d in days:
            out["days"][d][c] = summarise(by_day[d])

    action: dict[str, dict[str, dict[str, int]]] = defaultdict(lambda: defaultdict(lambda: defaultdict(int)))
    for s in query_range(base, HA_ACTION, start, end, get):
        a = s["metric"]["action"]
        if a in QUIET:
            continue
        for ts in s["values"]:
            action[day_of(ts)][s["metric"]["entity"]][a] += 1
    temps: dict[str, list[float]] = defaultdict(list)
    for s in query_range(base, HA_OUTDOOR, start, end, get):
        for ts, v in s["values"].items():
            temps[day_of(ts)].append(v)
    for d in days:
        if d in action:
            out["days"][d]["ha_action_minutes"] = {e: dict(a) for e, a in sorted(action[d].items())}
        if temps.get(d):
            t = temps[d]
            out["days"][d]["outdoor_c"] = {"min": round(min(t), 1), "max": round(max(t), 1),
                                           "mean": round(sum(t) / len(t), 1), "minutes": len(t)}
    return out


def fmt_row(label: str, s: dict) -> str:
    if not s["runs"]:
        return f"    {label:<12} -"
    return (f"    {label:<12} {s['runs']:>3} runs {s['minutes']:>5} min  median {s['median']:>5g}  "
            f"shortest {s['shortest']:>3}  longest {s['longest']:>4}  <{SHORT_MIN}min {s['short']:>2}  "
            f"most/h {s['most_per_hour']}")


def print_report(r: dict) -> None:
    iso = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
    print(f"HVAC runs {iso(r['start'])} to {iso(r['end'])} ({r['minutes']} minutes); days are Chicago time")
    print(f"  Emporia minutes with data: air handler (7) {r['data_minutes']['7']}, "
          f"outdoor unit (98) {r['data_minutes']['98']}, boiler (14) {r['data_minutes']['14']}")
    for d, v in r["days"].items():
        line = f"  {d}"
        if "outdoor_c" in v:
            o = v["outdoor_c"]
            line += f"  outdoor {o['min']}..{o['max']} °C (mean {o['mean']}, {o['minutes']} min)"
        print(line)
        for c in CLASSES:
            print(fmt_row(c, v[c]))
        for e, a in v.get("ha_action_minutes", {}).items():
            print(f"    HA {e}: " + ", ".join(f"{k} {n} min" for k, n in sorted(a.items())))
    print(f"  total (blower overruns after an outdoor-unit run, not counted as air-handler runs: "
          f"{r['blower_overrun']})")
    for c in CLASSES:
        print(fmt_row(c, r["total"][c]))
        if r["total"][c]["runs"] and r["total"][c]["runs"] <= 12:
            print("      starts: " + ", ".join(r["total"][c]["starts"]))


def minute(text: str) -> int:
    t = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    if t.tzinfo is None:
        t = t.replace(tzinfo=TZ)
    return int(t.timestamp()) // STEP * STEP


def selftest() -> int:
    t0 = minute("2026-10-22T13:00Z")  # 08:00 CDT
    end = t0 + 179 * STEP

    def series(ch: str, on: set[int], w: float, missing: set[int] = frozenset()) -> dict:
        return {"metric": {"channel": ch}, "values": [[t0 + i * STEP, str(w if i in on else 2.0)]
                                                      for i in range(180) if i not in missing]}
    hp = set(range(19, 29))                        # 10-minute heat pump run 08:19-08:28
    furnace = set(range(60, 63)) | set(range(70, 73))  # two 3-minute air-handler-only runs in one hour
    overrun = {29}                                     # the blower runs on one minute after the heat pump
    boiler = set(range(100, 115)) | set(range(130, 140))
    calls: list[str] = []

    def fake_get(url: str) -> dict:
        calls.append(url)
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        expr, s, e = q["query"][0], int(q["start"][0]), int(q["end"][0])
        if "emporia" in expr:
            res = [series("7", hp | furnace | overrun, 200.0), series("98", hp, 2500.0),
                   series("14", boiler, 90.0, missing={120})]
        elif "action" in expr:
            res = [{"metric": {"entity": "climate.downstairs_hallway", "action": "heating"},
                    "values": [[t0 + i * STEP, "1"] for i in hp]},
                   {"metric": {"entity": "climate.downstairs_hallway", "action": "idle"},
                    "values": [[t0, "1"]]}]
        else:
            res = [{"metric": {"entity": "sensor.mke_temperature"},
                    "values": [[t0, "6.5"], [t0 + 60, "8.5"]]}]
        for r in res:
            r["values"] = [v for v in r["values"] if s <= v[0] <= e]
        return {"status": "success", "data": {"result": res}}

    global MAX_POINTS
    saved, MAX_POINTS = MAX_POINTS, 50  # force chunking: 180 minutes in four queries per expression
    try:
        r = report(t0, end, base="http://stub", get=fake_get)
    finally:
        MAX_POINTS = saved
    tot, day = r["total"], r["days"]["2026-10-22"]
    checks = [
        ("chunked queries", len(calls) == 12),
        ("one heat pump run of 10 min", (tot["heat_pump"]["runs"], tot["heat_pump"]["minutes"]) == (1, 10)),
        ("heat pump minutes are not air-handler runs", tot["air_handler"]["runs"] == 2),
        ("short air-handler runs counted", tot["air_handler"]["short"] == 2),
        ("blower overrun is not an air-handler run", r["blower_overrun"] == 1),
        ("two air-handler runs in one clock hour", tot["air_handler"]["most_per_hour"] == 2),
        ("no outdoor-only minutes", tot["outdoor"]["runs"] == 0),
        ("boiler runs 15 and 10", tot["boiler"]["starts"] == ["10-22 09:40 15m", "10-22 10:10 10m"]),
        ("start in local time", tot["heat_pump"]["starts"] == ["10-22 08:19 10m"]),
        ("idle action dropped", day["ha_action_minutes"] == {"climate.downstairs_hallway": {"heating": 10}}),
        ("outdoor min/max", (day["outdoor_c"]["min"], day["outdoor_c"]["max"]) == (6.5, 8.5)),
        ("missing minute splits a run", runs([1, 2, None, 4]) == [(1, 2), (4, 1)]),
    ]
    bad = [name for name, ok in checks if not ok]
    for name, ok in checks:
        print(f"{'ok  ' if ok else 'FAIL'} {name}")
    return 1 if bad else 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--days", type=int, default=7, help="window ending now (default 7)")
    p.add_argument("--start", help="ISO time; no zone means Chicago (overrides --days)")
    p.add_argument("--end", help="ISO time (default now)")
    p.add_argument("--url", default=PROM, help=f"Prometheus base URL (default {PROM})")
    p.add_argument("--json", action="store_true")
    p.add_argument("--selftest", action="store_true", help="offline check against stubbed series")
    a = p.parse_args()
    if a.selftest:
        return selftest()
    end = minute(a.end) if a.end else int(dt.datetime.now(dt.timezone.utc).timestamp()) // STEP * STEP
    start = minute(a.start) if a.start else end - a.days * 86400 + STEP
    try:
        r = report(start, end, base=a.url.rstrip("/"))
    except (OSError, RuntimeError, ValueError) as e:
        print(f"[FAIL] {a.url}: {e}", file=sys.stderr)
        return 2
    if a.json:
        print(json.dumps(r, indent=1))
    else:
        print_report(r)
    return 0


if __name__ == "__main__":
    sys.exit(main())
