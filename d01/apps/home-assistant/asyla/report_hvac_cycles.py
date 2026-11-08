#!/usr/bin/env python3
"""Report HVAC runs and short cycling from Emporia minute power and Home Assistant, findings first. Read-only.

Backlog 2026-10-27-home-automation-hvac-schedule-optimiser-lowest-energy-heating-and-cooling-sc,
step 0: count runs, run lengths and runs per hour for the house air handler, the heat pump's
outdoor unit and the garage boiler, before any setting or schedule is proposed. It reads theOrg's
trends Prometheus (ASY-TRD-1) with GET only and changes nothing.

    report_hvac_cycles.py                    # the last 7 days, per local (Chicago) day
    report_hvac_cycles.py --days 14 --json   # machine-readable, every number
    report_hvac_cycles.py --start 2026-10-21T23:08Z --end 2026-10-28T22:57Z
    report_hvac_cycles.py --selftest         # offline, against stubbed series

The text is mailed (packages/hvac.yaml). It opens with what the window shows, worked out by the
fixed rules below, then house heat by outdoor temperature, then one line per day, then how it was
read. One sentence per line, no space-aligned columns (mail shows it in a proportional font), the
operator's names for the equipment, °F only. The first mail (2026-11-07) was a per-class table the
operator found "really hard to read and Im not terribly sure if it says anything useful".

Emporia House channels are CT ports, not breakers (step 0 findings in the backlog item):
7 "Furnace" is the air handler (blower), 98 "AC" the outdoor unit (3+4 combined), 14 "Boiler" the
boiler. Emporia's sample at minute T is the mean watts over the minute starting at T. Each minute is:

    heat_pump   outdoor unit > 500 W with the air handler (heat pump heat or cool; no gas)
    outdoor     outdoor unit > 500 W, air handler off (defrost or a fault: worth a look)
    air_handler air handler > 40 W alone: the gas furnace, or fan only when Home Assistant shows
                the house Ecobee's action as fan and never as heating during the run (power cannot
                tell them apart; HA can miss a short call, so no action at all counts as furnace)
    boiler      boiler > 40 W (independent of the house classes; it heats the garage slab and the
                indirect water heater)

A run is a stretch of consecutive minutes in one class; a missing minute ends it. An air-handler run
of at most 2 minutes that starts the minute an outdoor-unit run ends (the blower running on after
the compressor stops, seen 2026-10-22 and 10-27) or ends the minute one starts (the blower starting
first, seen 2026-11-01 and 11-06) belongs to the heat pump: it is counted as an overrun or a lead,
not as an air-handler run. Findings, in this order:

- House heat: the coldest outdoor temperature (sensor.mke_temperature, the last reading at most
  30 min before the start) at a heat pump start, and the gas furnace runs that started colder.
  That split is what an Ecobee compressor lockout makes; the report cannot read Ecobee settings.
- House heat runs under 5 minutes.
- A thermostat (house Ecobee, garage Watts) in mode off for an hour or more. A missing Home
  Assistant minute keeps the last mode for up to 90 minutes.
- Boiler starts, those under 5 minutes, and bursts: 6 or more runs, each starting within 12
  minutes of the last one's stop, with how many the garage thermostat's heating call overlapped
  (within 2 minutes either side).
- Any outdoor-unit run without the blower.
- A source with data for under 95 % of the minutes.

Exit 0 report printed, 2 the Prometheus query failed or the run passed its deadline. Each request
waits at most 10 s and the whole run at most 45 s from its start, so under shell_command's 60 s
Home Assistant mails this script's own [ERROR] line instead of "did not finish".

This copy in asyla-hosts d01/apps/home-assistant/asyla/ is the only one: Home Assistant runs it at a
cold spell (packages/hvac.yaml), and the asyla hub's tools/report_hvac_cycles.py runs it from the
hub's projects/asyla-hosts clone. Standard library only: it runs on the Home Assistant image's python3.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import statistics
import sys
import time
import urllib.parse
import urllib.request
from collections import defaultdict
from zoneinfo import ZoneInfo

# theOrg's trends Prometheus on d06 since 2026-11-03 (ASY-TRD); GET only, no login.
PROM = "https://prometheus-trends.asyla.org"
TZ = ZoneInfo("America/Chicago")
STEP = 60
MAX_POINTS = 10000  # Prometheus refuses more than 11000 points per series per query

HOUSE, GARAGE = "climate.downstairs_hallway", "climate.garage_radiant"
THERMOSTATS = {HOUSE: "house thermostat", GARAGE: "garage thermostat"}
EMPORIA = 'last_over_time(emporia_channel_power_watts{device="House",channel=~"7|14|98"}[59s])'
HA_ACTION = 'last_over_time(homeassistant_climate_action{entity=~"climate\\\\..*"}[59s]) == 1'
HA_MODE = ('last_over_time(homeassistant_climate_mode'
           '{entity=~"climate\\\\.downstairs_hallway|climate\\\\.garage_radiant"}[59s]) == 1')
HA_OUTDOOR = 'last_over_time(homeassistant_sensor_temperature_celsius{entity="sensor.mke_temperature"}[59s])'
AIR_HANDLER_W, OUTDOOR_W, BOILER_W = 40.0, 500.0, 40.0
SHORT_MIN = 5
OVERRUN_MAX = 2
OUTDOOR_LOOKBACK = 30   # min: the outdoor reading at a run's start is the last one this far back
MODE_CARRY = 90         # min: a Home Assistant gap this long keeps the last thermostat mode
OFF_MIN = 60            # min: a thermostat off this long is a finding
BURST_OFF_MAX = 12      # min: a boiler start this soon after the last stop continues a burst
BURST_MIN = 6           # runs in a burst
CALL_SLACK = 2          # min either side of a boiler run that a garage call may start or end
COMPLETE = 0.95         # share of minutes below which a source's data is a finding
CLASSES = ["heat_pump", "outdoor", "air_handler", "boiler"]
HOUSE_KINDS = {"heat_pump": "heat pump", "furnace": "gas furnace", "fan_only": "fan only",
               "outdoor": "outdoor unit alone"}
QUIET = {"idle", "off"}
REQUEST_TIMEOUT = 10.0  # s per Prometheus request
DEADLINE = 45.0         # s for the whole run, from the script's start; shell_command allows 60
STARTED = time.monotonic()


class DeadlinePassed(Exception):
    pass


def fetch_json(url: str, timeout: float) -> dict:
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.load(r)


def deadline_get(deadline: float, clock=time.monotonic, fetch=fetch_json):
    """A get(url) that waits at most REQUEST_TIMEOUT per request and refuses to start past deadline."""
    def get(url: str) -> dict:
        left = deadline - clock()
        if left <= 0:
            raise DeadlinePassed(f"Prometheus did not answer within the {DEADLINE:g} s deadline "
                                 f"(each request waits at most {REQUEST_TIMEOUT:g} s)")
        return fetch(url, min(REQUEST_TIMEOUT, left))
    return get


def http_get(url: str) -> dict:
    return deadline_get(STARTED + DEADLINE)(url)


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


def split_blower(ah: list[tuple[int, int]], outdoor: list[tuple[int, int]]) -> tuple[list, int, int]:
    """Air-handler runs without the blower overruns and leads of an outdoor-unit run: (kept, overruns, leads)."""
    ends = {s + n * STEP for s, n in outdoor}
    starts = {s for s, _ in outdoor}
    kept, overrun, lead = [], 0, 0
    for s, n in ah:
        if n <= OVERRUN_MAX and s in ends:
            overrun += 1
        elif n <= OVERRUN_MAX and s + n * STEP in starts:
            lead += 1
        else:
            kept.append((s, n))
    return kept, overrun, lead


def blower_kind(run: tuple[int, int], house_action: dict[str, set[int]]) -> str:
    """furnace, or fan_only when the house thermostat shows fan and never heating during the run."""
    s, n = run
    inside = set(range(s, s + n * STEP, STEP))
    heat = inside & house_action.get("heating", set())
    fan = inside & house_action.get("fan", set())
    return "fan_only" if fan and not heat else "furnace"


def outdoor_at(temps_c: dict[int, float], ts: int) -> float | None:
    """The outdoor °F at ts: the last reading at most OUTDOOR_LOOKBACK minutes before it."""
    for back in range(OUTDOOR_LOOKBACK + 1):
        v = temps_c.get(ts - back * STEP)
        if v is not None:
            return fahrenheit(v)
    return None


def off_stretches(minutes: list[int], mode_at: dict[int, str]) -> list[dict]:
    """Stretches of mode off of at least OFF_MIN minutes; a gap up to MODE_CARRY keeps the last mode."""
    found, cur, last, last_seen, first = [], None, None, None, None
    for m in minutes:
        if m in mode_at:
            last, last_seen = mode_at[m], m
        elif last_seen is None or m - last_seen > MODE_CARRY * STEP:
            last = None
        if last == "off":
            first = m if first is None else first
            cur = m
        elif first is not None:
            found.append((first, cur))
            first = None
    if first is not None:
        found.append((first, cur))
    return [{"start": a, "end": b + STEP, "from_window_start": a == minutes[0],
             "to_window_end": b == minutes[-1]} for a, b in found if (b - a) // STEP + 1 >= OFF_MIN]


def bursts(rs: list[tuple[int, int]], calls: set[int]) -> list[dict]:
    """Boiler bursts: BURST_MIN or more runs, each starting within BURST_OFF_MAX of the last stop."""
    groups, cur = [], []
    for r in rs:
        if cur and r[0] - (cur[-1][0] + cur[-1][1] * STEP) > BURST_OFF_MAX * STEP:
            groups.append(cur)
            cur = []
        cur.append(r)
    groups.append(cur)
    out = []
    for g in groups:
        if len(g) < BURST_MIN:
            continue
        gaps = [(b[0] - a[0]) // STEP for a, b in zip(g, g[1:])]
        in_call = sum(1 for s, n in g
                      if calls & set(range(s - CALL_SLACK * STEP, s + (n + CALL_SLACK) * STEP, STEP)))
        out.append({"start": g[0][0], "end": g[-1][0] + g[-1][1] * STEP, "runs": len(g),
                    "every": statistics.median(gaps), "shortest": min(n for _, n in g),
                    "longest": max(n for _, n in g), "in_garage_call": in_call})
    return out


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
    action: dict[str, dict[str, set[int]]] = defaultdict(lambda: defaultdict(set))
    for s in query_range(base, HA_ACTION, start, end, get):
        if s["metric"]["action"] not in QUIET:
            action[s["metric"]["entity"]][s["metric"]["action"]].update(s["values"])
    modes: dict[str, dict[int, str]] = defaultdict(dict)
    for s in query_range(base, HA_MODE, start, end, get):
        modes[s["metric"]["entity"]].update({ts: s["metric"]["mode"] for ts in s["values"]})
    temps_c: dict[int, float] = {}
    for s in query_range(base, HA_OUTDOOR, start, end, get):
        temps_c.update(s["values"])

    marks = classify(minutes, power)
    days = sorted({day_of(m) for m in minutes})
    out = {"start": start, "end": end, "minutes": len(minutes),
           "data_minutes": {ch: len(power.get(ch, {})) for ch in ("7", "98", "14")},
           "outdoor_minutes": len(temps_c), "days": {d: {} for d in days}, "total": {}}
    found = {c: runs(marks[c]) for c in CLASSES}
    found["air_handler"], out["blower_overrun"], out["blower_lead"] = split_blower(
        found["air_handler"], sorted(found["heat_pump"] + found["outdoor"]))
    house = action.get(HOUSE, {})
    found["furnace"] = [r for r in found["air_handler"] if blower_kind(r, house) == "furnace"]
    found["fan_only"] = [r for r in found["air_handler"] if blower_kind(r, house) == "fan_only"]
    for c in CLASSES + ["furnace", "fan_only"]:
        rs = found[c]
        out["total"][c] = summarise(rs)
        by_day = defaultdict(list)
        for r in rs:
            by_day[day_of(r[0])].append(r)
        for d in days:
            out["days"][d][c] = summarise(by_day[d])
    out["house_runs"] = sorted(({"start": s, "minutes": n, "kind": k, "outdoor_f": outdoor_at(temps_c, s)}
                                for k in ("heat_pump", "furnace", "fan_only", "outdoor") for s, n in found[k]),
                               key=lambda x: x["start"])
    out["boiler_bursts"] = bursts(found["boiler"], action.get(GARAGE, {}).get("heating", set()))
    out["thermostat_off"] = {e: off_stretches(minutes, modes.get(e, {})) for e in THERMOSTATS}

    per_day_action: dict[str, dict[str, dict[str, int]]] = defaultdict(lambda: defaultdict(lambda: defaultdict(int)))
    for e, acts in action.items():
        for a, ms in acts.items():
            for ts in ms:
                per_day_action[day_of(ts)][e][a] += 1
    temps: dict[str, list[float]] = defaultdict(list)
    for ts, v in temps_c.items():
        temps[day_of(ts)].append(v)
    for d in days:
        if d in per_day_action:
            out["days"][d]["ha_action_minutes"] = {e: dict(a) for e, a in sorted(per_day_action[d].items())}
        if temps.get(d):
            t = temps[d]
            out["days"][d]["outdoor_c"] = {"min": round(min(t), 1), "max": round(max(t), 1),
                                           "mean": round(sum(t) / len(t), 1), "minutes": len(t)}
    out["findings"] = findings(out)
    return out


# ---- text -------------------------------------------------------------------------------------

def fahrenheit(c: float) -> float:
    """A °C reading (the trends Prometheus series) as °F to one decimal: the operator reads °F."""
    return round(c * 9 / 5 + 32, 1)


def when(ts: int, same_day_as: int | None = None) -> str:
    t = dt.datetime.fromtimestamp(ts, TZ)
    if same_day_as is not None and day_of(same_day_as) == day_of(ts):
        return t.strftime("%H:%M")
    return t.strftime("%a %m-%d %H:%M")


def span(a: int, b: int) -> str:
    return f"{when(a)} to {when(b, same_day_as=a)}"


def deg(v: float | None) -> str:
    return "unknown" if v is None else f"{v:.1f} °F"


def deg_range(vals: list[float | None]) -> str:
    known = [v for v in vals if v is not None]
    if not known:
        return "an unknown outdoor temperature"
    lo, hi = min(known), max(known)
    return deg(lo) if lo == hi else f"{lo:.1f} to {hi:.1f} °F"


def n_of(n: int, one: str, many: str | None = None) -> str:
    return f"{n} {one if n == 1 else (many or one + 's')}"


def runs_min(rs: list[dict]) -> str:
    return f"{n_of(len(rs), 'run')}, {sum(r['minutes'] for r in rs)} min"


def findings(r: dict) -> list[str]:
    """The fixed rules in the docstring, as plain sentences; a line starting with two spaces belongs to the one above."""
    out: list[str] = []
    hr = r["house_runs"]
    hp = [x for x in hr if x["kind"] == "heat_pump"]
    fu = [x for x in hr if x["kind"] == "furnace"]
    if not hp and not fu:
        out.append("The house did not call for heat.")
    elif not hp:
        out.append(f"Only the gas furnace heated the house: {runs_min(fu)}, at "
                   f"{deg_range([x['outdoor_f'] for x in fu])} outdoors. The heat pump did not run.")
    elif not fu:
        out.append(f"Only the heat pump heated the house: {runs_min(hp)}, at "
                   f"{deg_range([x['outdoor_f'] for x in hp])} outdoors. The gas furnace did not run.")
    else:
        known = [x for x in hp if x["outdoor_f"] is not None]
        coldest = min(known, key=lambda x: (x["outdoor_f"], x["start"])) if known else None
        cold = [x for x in fu if coldest and x["outdoor_f"] is not None and x["outdoor_f"] < coldest["outdoor_f"]]
        if cold:
            rest = len(fu) - len(cold)
            out.append(f"The heat pump never started below {deg(coldest['outdoor_f'])} ({when(coldest['start'])}). "
                       f"Below that, every call for house heat was the gas furnace: {runs_min(cold)}, at "
                       f"{deg_range([x['outdoor_f'] for x in cold])} outdoors."
                       + (f" The furnace also ran {'once' if rest == 1 else f'{rest} times'} at warmer "
                          "temperatures." if rest else ""))
            out.append("An Ecobee compressor lockout near that temperature would do this "
                       "(inference: the report cannot read Ecobee settings).")
        else:
            out.append(f"Heat pump {runs_min(hp)}, at {deg_range([x['outdoor_f'] for x in hp])} outdoors; "
                       f"gas furnace {runs_min(fu)}, at {deg_range([x['outdoor_f'] for x in fu])}.")
    short = [x for x in hp + fu if x["minutes"] < SHORT_MIN]
    if hp or fu:
        out.append("No house heat run was shorter than 5 minutes." if not short else
                   f"{n_of(len(short), 'house heat run')} {'was' if len(short) == 1 else 'were'} shorter than "
                   f"5 minutes: " + ", ".join(f"{when(x['start'])} ({x['minutes']} min)" for x in sorted(short, key=lambda x: x['start'])[:5])
                   + ("" if len(short) <= 5 else ", ...") + ".")
    for e, name in THERMOSTATS.items():
        for o in r["thermostat_off"].get(e, []):
            a = "from before this report" if o["from_window_start"] else f"from {when(o['start'])}"
            b = "to the end of it" if o["to_window_end"] else f"to {when(o['end'], same_day_as=o['start'])}"
            out.append(f"The {name} was off {a} {b}" + (", so no house heat ran then." if e == HOUSE else "."))
    b = r["total"]["boiler"]
    if not b["runs"]:
        out.append("The garage boiler did not run.")
    else:
        out.append(f"The garage boiler started {n_of(b['runs'], 'time')} ({b['minutes']} min), "
                   f"{b['short']} of them for under 5 minutes.")
        bs = r["boiler_bursts"]
        if bs:
            out.append(f"It ran in fast bursts, starting again within {BURST_OFF_MAX} minutes of stopping:")
            for x in bs:
                out.append(f"  {span(x['start'], x['end'])}: {x['runs']} starts, about every {x['every']:g} min, "
                           f"{x['shortest']} to {x['longest']} min each; the garage thermostat was calling "
                           f"during {x['in_garage_call']} of them.")
    alone = [x for x in hr if x["kind"] == "outdoor"]
    if alone:
        out.append(f"Worth a look: the outdoor unit ran {n_of(len(alone), 'time')} without the indoor blower "
                   "(defrost or a fault): " + ", ".join(f"{when(x['start'])} ({x['minutes']} min)" for x in alone[:5])
                   + ("" if len(alone) <= 5 else ", ...") + ".")
    gaps = [f"{name} {have} of {r['minutes']} minutes" for name, have in
            (("Emporia air handler", r["data_minutes"]["7"]), ("Emporia outdoor unit", r["data_minutes"]["98"]),
             ("Emporia boiler", r["data_minutes"]["14"]), ("outdoor temperature", r["outdoor_minutes"]))
            if have < COMPLETE * r["minutes"]]
    if gaps:
        out.append("Data is missing, so the counts are low: " + "; ".join(gaps) + ".")
    if not alone:
        out.append("Nothing here needs action now.")
    return out


def bands(r: dict) -> list[str]:
    """House heat by 5 °F band of the outdoor temperature at each run's start."""
    by: dict[float | None, dict[str, list]] = defaultdict(lambda: defaultdict(list))
    for x in r["house_runs"]:
        if x["kind"] in ("heat_pump", "furnace"):
            t = x["outdoor_f"]
            by[None if t is None else math.floor(t / 5) * 5][x["kind"]].append(x)
    lines = []
    for lo in sorted(by, key=lambda v: (v is None, v or 0)):
        label = "outdoor temperature unknown" if lo is None else f"{lo} to {lo + 5} °F"
        parts = [f"{HOUSE_KINDS[k]} {runs_min(by[lo][k])}" for k in ("heat_pump", "furnace") if by[lo][k]]
        lines.append(f"- {label}: " + "; ".join(parts))
    return lines


def day_line(d: str, v: dict, r: dict) -> str:
    name = dt.date.fromisoformat(d).strftime("%a %m-%d")
    if day_of(r["start"]) == d and when(r["start"], same_day_as=r["start"]) != "00:00":
        name += f" from {when(r['start'], same_day_as=r['start'])}"
    if day_of(r["end"] + STEP) == d:  # the window stops before midnight
        name += f" to {when(r['end'], same_day_as=r['end'])}"
    line = f"- {name}"
    if "outdoor_c" in v:
        line += f", {fahrenheit(v['outdoor_c']['min']):.1f} to {fahrenheit(v['outdoor_c']['max']):.1f} °F"
    parts = [f"{HOUSE_KINDS[k]} {n_of(v[k]['runs'], 'run')}, {v[k]['minutes']} min"
             for k in ("heat_pump", "furnace", "fan_only", "outdoor") if v[k]["runs"]]
    if not v["heat_pump"]["runs"] and not v["furnace"]["runs"]:
        parts.insert(0, "no house heat")
    b = v["boiler"]
    parts.append("garage boiler did not run" if not b["runs"] else
                 f"garage boiler {n_of(b['runs'], 'start')}, {b['minutes']} min, {b['short']} under 5 min")
    garage = v.get("ha_action_minutes", {}).get(GARAGE, {}).get("heating")
    if garage:
        parts.append(f"garage thermostat calling {garage} min")
    return line + ": " + "; ".join(parts)


def print_report(r: dict) -> None:
    print(f"HVAC report, {span(r['start'], r['end'])} (Chicago time)")
    print()
    print("What it found")
    for f in r["findings"]:
        print(f if f.startswith("  ") else f"- {f}")
    bl = bands(r)
    if bl:
        print()
        print("House heat by outdoor temperature (at the start of each run)")
        for line in bl:
            print(line)
    print()
    print("Day by day")
    for d, v in r["days"].items():
        print(day_line(d, v, r))
    print()
    print("How it was read")
    print("- Heat pump: the outdoor unit and the indoor blower ran together.")
    print("- Gas furnace: the indoor blower ran alone, unless the thermostat showed fan only.")
    print(f"- A blower run of 1-2 minutes just before or after a heat pump run is part of that run "
          f"({r['blower_lead'] + r['blower_overrun']} this time).")
    print("- Garage boiler: it heats both the garage slab and the water heater.")
    print(f"- Data: Emporia {min(r['data_minutes'].values())} of {r['minutes']} minutes, "
          f"outdoor temperature {r['outdoor_minutes']}. Every number is in --json.")


def minute(text: str) -> int:
    t = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    if t.tzinfo is None:
        t = t.replace(tzinfo=TZ)
    return int(t.timestamp()) // STEP * STEP


def selftest() -> int:
    t0 = minute("2026-10-22T13:00Z")  # Thu 08:00 CDT
    end = t0 + 179 * STEP

    def series(ch: str, on: set[int], w: float, missing: set[int] = frozenset()) -> dict:
        return {"metric": {"channel": ch}, "values": [[t0 + i * STEP, str(w if i in on else 2.0)]
                                                      for i in range(180) if i not in missing]}

    def at(entity: str, key: str, value: str, idx) -> dict:
        return {"metric": {"entity": entity, key: value}, "values": [[t0 + i * STEP, "1"] for i in idx]}
    hp = set(range(19, 29))                            # 10-minute heat pump run 08:19-08:28
    lead, overrun = {18}, {29}                         # the blower starts a minute early, runs on a minute
    furnace = set(range(60, 63)) | set(range(70, 73))  # two 3-minute blower-alone runs in one hour
    fan = set(range(150, 154))                         # blower alone with the thermostat on fan
    burst = set().union(*(set(range(s, s + 3)) for s in range(125, 176, 10)))  # 6 runs, 7 min apart
    boiler = set(range(100, 115)) | burst              # 15 min, then the burst 10 min later: 7 in it
    calls: list[str] = []

    def fake_get(url: str) -> dict:
        calls.append(url)
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        expr, s, e = q["query"][0], int(q["start"][0]), int(q["end"][0])
        if "emporia" in expr:
            res = [series("7", hp | lead | overrun | furnace | fan, 200.0), series("98", hp, 2500.0),
                   series("14", boiler, 90.0, missing={120})]
        elif "climate_action" in expr:
            res = [at(HOUSE, "action", "heating", hp | set(range(60, 63))), at(HOUSE, "action", "idle", [0]),
                   at(HOUSE, "action", "fan", fan),
                   at(GARAGE, "action", "heating", set().union(*(set(range(s, s + 3)) for s in range(135, 176, 10))))]
        elif "climate_mode" in expr:  # house off 09:20-10:20, with a 21-minute HA gap inside it
            res = [at(HOUSE, "mode", "heat", [i for i in range(180) if not 80 <= i <= 140]),
                   at(HOUSE, "mode", "off", [i for i in range(80, 141) if not 100 <= i <= 120]),
                   at(GARAGE, "mode", "heat", range(180))]
        else:  # outdoor 47.3 °F at the heat pump start, 33.8 °F from 08:50
            res = [{"metric": {"entity": "sensor.mke_temperature"},
                    "values": [[t0 + i * STEP, "6.5" if i == 0 else "8.5" if i < 50 else "1.0"] for i in range(180)]}]
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
    import contextlib
    import io
    shown = io.StringIO()
    with contextlib.redirect_stdout(shown):
        print_report(r)
    text = shown.getvalue()
    lines = text.splitlines()
    want_lines = [
        "HVAC report, Thu 10-22 08:00 to 10:59 (Chicago time)",
        "- The heat pump never started below 47.3 °F (Thu 10-22 08:19). Below that, every call for house heat "
        "was the gas furnace: 2 runs, 6 min, at 33.8 °F outdoors.",
        "- An Ecobee compressor lockout near that temperature would do this (inference: the report cannot "
        "read Ecobee settings).",
        "- 2 house heat runs were shorter than 5 minutes: Thu 10-22 09:00 (3 min), Thu 10-22 09:10 (3 min).",
        "- The house thermostat was off from Thu 10-22 09:20 to 10:21, so no house heat ran then.",
        "- The garage boiler started 7 times (33 min), 6 of them for under 5 minutes.",
        "  Thu 10-22 09:40 to 10:58: 7 starts, about every 10 min, 3 to 15 min each; "
        "the garage thermostat was calling during 5 of them.",
        "- Nothing here needs action now.",
        "- 30 to 35 °F: gas furnace 2 runs, 6 min",
        "- 45 to 50 °F: heat pump 1 run, 10 min",
        "- Thu 10-22 from 08:00 to 10:59, 33.8 to 47.3 °F: heat pump 1 run, 10 min; gas furnace 2 runs, 6 min; "
        "fan only 1 run, 4 min; garage boiler 7 starts, 33 min, 6 under 5 min; garage thermostat calling 15 min",
        "- A blower run of 1-2 minutes just before or after a heat pump run is part of that run (2 this time).",
        "- Data: Emporia 179 of 180 minutes, outdoor temperature 180. Every number is in --json.",
    ]
    checks = [
        ("chunked queries", len(calls) == 16),
        ("one heat pump run of 10 min", (tot["heat_pump"]["runs"], tot["heat_pump"]["minutes"]) == (1, 10)),
        ("heat pump minutes are not air-handler runs", tot["air_handler"]["runs"] == 3),
        ("blower lead and overrun are not air-handler runs", (r["blower_lead"], r["blower_overrun"]) == (1, 1)),
        ("blower alone is the furnace, also with no thermostat action",
         [x["start"] for x in r["house_runs"] if x["kind"] == "furnace"] == [t0 + 60 * STEP, t0 + 70 * STEP]),
        ("blower alone on thermostat fan is fan only", (tot["fan_only"]["runs"], tot["fan_only"]["minutes"]) == (1, 4)),
        ("two air-handler runs in one clock hour", tot["furnace"]["most_per_hour"] == 2),
        ("no outdoor-only minutes", tot["outdoor"]["runs"] == 0),
        ("boiler runs 15 and six of 3", tot["boiler"]["starts"][:2] == ["10-22 09:40 15m", "10-22 10:05 3m"]
         and tot["boiler"]["runs"] == 7),
        ("one boiler burst of 7", [(b["runs"], b["in_garage_call"]) for b in r["boiler_bursts"]] == [(7, 5)]),
        ("outdoor at a run start", [x["outdoor_f"] for x in r["house_runs"]] == [47.3, 33.8, 33.8, 33.8]),
        ("house off across an HA gap", [(o["start"], o["end"]) for o in r["thermostat_off"][HOUSE]]
         == [(t0 + 80 * STEP, t0 + 141 * STEP)] and r["thermostat_off"][GARAGE] == []),
        ("start in local time", tot["heat_pump"]["starts"] == ["10-22 08:19 10m"]),
        ("idle action dropped", "idle" not in day["ha_action_minutes"][HOUSE]),
        ("outdoor min/max", (day["outdoor_c"]["min"], day["outdoor_c"]["max"]) == (1.0, 8.5)),
        ("°F only", "°C" not in text),
        ("no space-aligned columns", not any("   " in ln.strip() for ln in lines)),
        ("°F on output", (fahrenheit(6.5), fahrenheit(8.5), fahrenheit(-20), fahrenheit(0)) == (43.7, 47.3, -4.0, 32.0)),
        ("missing minute splits a run", runs([1, 2, None, 4]) == [(1, 2), (4, 1)]),
    ]
    checks += [(f"line: {w[:60]}", w in lines) for w in want_lines]
    # The other house-heat rules, on stand-in runs.
    base = {"house_runs": [], "thermostat_off": {}, "total": {"boiler": {"runs": 0}}, "boiler_bursts": [],
            "data_minutes": {"7": 10, "98": 10, "14": 10}, "outdoor_minutes": 10, "minutes": 10}
    hrun = lambda k, t, m=20: {"start": t0, "minutes": m, "kind": k, "outdoor_f": t}
    only_gas = findings(base | {"house_runs": [hrun("furnace", 20.0), hrun("furnace", 25.5)]})
    only_hp = findings(base | {"house_runs": [hrun("heat_pump", 40.0)]})
    mixed = findings(base | {"house_runs": [hrun("heat_pump", 30.0), hrun("furnace", 35.0)]})
    alone = findings(base | {"house_runs": [hrun("outdoor", 30.0, 3)], "outdoor_minutes": 5})
    checks += [
        ("only the furnace", only_gas[0] == "Only the gas furnace heated the house: 2 runs, 40 min, at 20.0 to "
         "25.5 °F outdoors. The heat pump did not run."),
        ("only the heat pump", only_hp[0].startswith("Only the heat pump heated the house: 1 run, 20 min, at 40.0 °F")),
        ("furnace warmer than the heat pump: no lockout claim",
         mixed[0].startswith("Heat pump 1 run, 20 min, at 30.0 °F outdoors; gas furnace") and
         not any("lockout" in f for f in mixed)),
        ("no house heat, boiler off", findings(base)[:2] == ["The house did not call for heat.",
                                                            "The garage boiler did not run."]),
        ("outdoor unit alone is worth a look, not 'nothing needs action'",
         any(f.startswith("Worth a look: the outdoor unit ran 1 time") for f in alone)
         and "Nothing here needs action now." not in alone),
        ("missing data is said", any(f.startswith("Data is missing") and "outdoor temperature 5 of 10" in f for f in alone)),
    ]
    # The deadline: a request near it waits only what is left; past it, none is sent.
    sent: list[float] = []
    near = deadline_get(100.0, clock=lambda: 97.5, fetch=lambda u, t: sent.append(t) or {})
    near("http://stub")
    late = deadline_get(100.0, clock=lambda: 100.0, fetch=lambda u, t: sent.append(t) or {})
    try:
        late("http://stub")
        refused = False
    except DeadlinePassed:
        refused = True
    far = deadline_get(100.0, clock=lambda: 0.0, fetch=lambda u, t: sent.append(t) or {})
    far("http://stub")
    checks += [
        ("request near the deadline waits only what is left", sent[:1] == [2.5]),
        ("no request past the deadline", refused and len(sent) == 2),
        ("a request waits at most REQUEST_TIMEOUT", sent[1:] == [REQUEST_TIMEOUT]),
    ]
    bad = [name for name, ok in checks if not ok]
    for name, ok in checks:
        print(f"{'ok  ' if ok else 'FAIL'} {name}")
    if bad:
        print(text)
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
    except (DeadlinePassed, OSError, RuntimeError, ValueError) as e:
        print(f"[ERROR] {a.url}: {e}", file=sys.stderr)
        return 2
    if a.json:
        print(json.dumps(r, indent=1))
    else:
        print_report(r)
    return 0


if __name__ == "__main__":
    sys.exit(main())
