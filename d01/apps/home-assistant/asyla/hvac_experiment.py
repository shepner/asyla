#!/usr/bin/env python3
"""The winter experiment's section of the cold-spell HVAC mail: heat pump nights against gas nights. Read-only.

packages/hvac_experiment.yaml alternates nights from 2026-11-12 to 2027-03-31: at 21:00 it sets the
house Ecobee's compressor lockout to -15 °F (a heat pump night, an even number of days after 11-12)
or 65 °F (a gas night); at 09:00 it puts back the normal 35 °F; its comfort stop sets 35 early on a
heat pump night. report_hvac_cycles.py imports this module, puts its section at the top of the mail
from 2026-11-12 through 2027-04-07 (a week past the last night) and under "experiment" in --json.

A night runs 21:00 to 08:59 Chicago time and carries its evening's date (DST-change nights are 11 or
13 h). fetch() reads the season so far from theOrg's trends Prometheus (GET only) through the
report's query_range: Emporia channels 98 and 7 and the heating call per minute, the temperatures
and the lockout every 5 minutes, with an hour either side of each night. night_record() works out
one night from those series alone (no I/O), so stand-in series can test it. Per night:

    kind       from sensor.hvac_experiment_lockout (kept in °C by trends): heat_pump (-15 °F),
               comfort_stopped (-15, then 35 before 09:00: the comfort stop, or the stop switch,
               which looks the same), gas (65 °F), not_running (anything else: stopped, or no data)
    outdoor    the mean of sensor.mke_temperature (Ambient station)
    °F-hours   indoor (the mean of the five Ecobee room sensors) minus outdoor, every 5 minutes
    kWh        the outdoor unit over 150 W (standby reads about 60 W) plus the air handler (over
               40 W) when it is not a furnace minute
    furnace    air handler 95-145 W (low stage, about 112 W) or 145 W and over (high, about 176 W;
               191 and 199 W seen) with the outdoor unit under 500 W from 2 minutes before to 2 after
               (the heat pump's blower also draws 190-200 W, but only next to an outdoor-unit run:
               its lead and run-on minutes are the heat pump's). Burner minutes
               are those less 1.5 per cycle, in the cycle's last stage (the blower runs on after the
               burner stops). Heat: 38,000 Btu/h low, 58,000 high (output, Carrier 59TP7A-01PD p.4).
    defrosts   the outdoor unit below 1.2 kW (not at standby) for 2-10 minutes right after a run
               minute, then back at 1.2 kW or more. Inference: power alone cannot see the reversing
               valve. Counted on every night; only heat pump nights trip the icing stop rule.
    long dip   the outdoor unit still between standby and 1 kW 15 minutes after dropping from a run
    standby    minutes the outdoor unit sat at standby while the thermostat called for heat on a
               heat pump night's -15 °F minutes, the furnace not running and the Ecobee not frozen
    08:30      the thermostat's own reading within 2 °F of its target at 08:30

Power sums are scaled to the night's minutes when Emporia is a few minutes short (its data lags
about 7 min). A night with under 95 % of its power minutes or 90 % of its temperature readings is
left out of the band figures.

Frozen Ecobee data: the Ecobee cloud sometimes stops every Ecobee value for hours. A 5-minute reading
is frozen when it is one of a run of readings, an hour or more long, in which none of the five rooms
and the thermostat changed; then sensor.mke_inside_temperature (Ambient, a different cloud) stands
in, shifted by the night's median room-minus-Ambient difference over its unfrozen readings. With no
unfrozen reading that night, the offset is unknown and the night is left out of the band figures.

Per 5 °F band of night mean outdoor temperature, over every night since 11-12:

    need     furnace heat / °F-hours over the band's gas nights (kWh of heat per °F-hour)
    COP      over its heat pump nights (comfort-stopped ones included): the sum of need × °F-hours
             less any furnace heat that night ("mixed"), over the sum of kWh. A band needs 2 gas
             nights and 2 heat pump nights first.
    saved    site energy per kWh of heat: 1/0.97 - 1/COP (gas at 97 % against electricity)
    extra $  per kWh of heat: e/COP - g/(29.307 × 0.97)
    CO2      grid 0.4315 kg/kWh against gas 5.306 kg/therm

Stop rules, findings first: the comfort stop; a band's COP under 1.0; standby during a call for over
20 minutes; more than 2 defrosts in an hour or a long dip (possible icing). Those this week are
spelled out; earlier ones get one line.

Standard library only: it runs on the Home Assistant image's python3, next to the report.
"""
from __future__ import annotations

import datetime as dt
import math
import statistics
from zoneinfo import ZoneInfo

TZ = ZoneInfo("America/Chicago")
FIRST_NIGHT = dt.date(2026, 11, 12)
LAST_NIGHT = dt.date(2027, 3, 31)
SHOW_UNTIL = dt.date(2027, 4, 7)   # the section stays a week past the last night

# Prices and factors (the mail names the prices it used).
E_PRICE = 0.19593          # $/kWh: We Energies Rg-1 residential, 2026
GAS_PRICE = 0.7083         # $/therm: Wisconsin Gas Rg-1, sheet 93, effective 2026-11-01. It moves
GAS_PRICE_MONTH = "2026-11"  # monthly through the purchased gas adjustment (PGA): update both together.
KWH_PER_THERM = 29.307
AFUE = 0.97                # the gas furnace's efficiency in these figures
GRID_CO2 = 0.4315          # kg CO2 per kWh used: eGRID2023 RFCW average with 4.2 % grid loss
GAS_CO2 = 5.306            # kg CO2 per therm (EPA)
BTU_PER_KWH = 3412.142
FURNACE_KWH_MIN = {"low": 38000 / BTU_PER_KWH / 60, "high": 58000 / BTU_PER_KWH / 60}  # 0.186, 0.283
CYCLE_TAIL_MIN = 1.5

# Thresholds.
LOCK_HP_C = -20.0          # -15 °F is -26.1 °C
LOCK_GAS_C = 15.0          # 65 °F is 18.3 °C
LOCK_NORMAL_C = (0.5, 3.0)  # 35 °F is 1.7 °C (the write test's 30 °F is -1.1)
LOCK_HP_MIN_READINGS = 3   # 15 minutes at -15 °F before a return to 35 counts as a comfort stop
STANDBY_W, HP_W, ICED_W, RUN_W = 150, 500, 1000, 1200
BLOWER_ON_W, LOW_W, HIGH_W = 40, 95, 145
FURNACE_GUARD_MIN = 2      # the outdoor unit under HP_W this many minutes either side
DEFROST_MIN = (2, 10)
LONG_DIP_MIN = 15
FROZEN_MIN = 60
HOLD_F = 2.0
STANDBY_STOP_MIN = 20
DEFROSTS_PER_HOUR = 3      # "more than 2 defrosts in an hour"
COP_STOP = 1.0
BAND_F = 5
MIN_NIGHTS = 2
POWER_COMPLETE, TEMP_COMPLETE = 0.95, 0.90

# Fetching: power and the heating call per minute, the slow series every 5 minutes.
MINUTE, SLOW = 60, 300
MARGIN = 3600              # s fetched either side of each night: frozen runs, furnace guard, long dips
JOB = 'job="asyla-home-assistant"'
ROOMS = ("upstairs", "office", "kitchen", "living_room", "downstairs_hallway")
SENSORS = {"sensor.hvac_experiment_lockout": "lock", "sensor.mke_temperature": "out",
           "sensor.mke_inside_temperature": "amb", **{f"sensor.{r}_temperature": r for r in ROOMS}}
HOUSE = 'entity="climate.downstairs_hallway"'
# Every term is wrapped in max() so the labels drop (Home Assistant's instance label changed once).
POWER_Q = 'max by (channel) (last_over_time(emporia_channel_power_watts{device="House",channel=~"7|98"}[59s]))'
HEAT_Q = f'max(last_over_time(homeassistant_climate_action{{{HOUSE},action="heating",{JOB}}}[59s])) == 1'
SENSOR_Q = ('max by (entity) (last_over_time(homeassistant_sensor_temperature_celsius{entity=~"'
            + "|".join(SENSORS) + f'",{JOB}}}[5m]))')
TSTAT_Q = f'max(last_over_time(homeassistant_climate_current_temperature_celsius{{{HOUSE},{JOB}}}[5m]))'
TARGET_Q = f'max(last_over_time(homeassistant_climate_target_temperature_celsius{{{HOUSE},{JOB}}}[5m]))'
SERIES = ("98", "7", "heat", "tstat", "target", *SENSORS.values())


# ---- nights and fetching -----------------------------------------------------------------------

def night_bounds(d: dt.date) -> tuple[int, int]:
    """(21:00 on evening d, 09:00 the next morning), Chicago time, as epoch seconds."""
    return (int(dt.datetime.combine(d, dt.time(21), TZ).timestamp()),
            int(dt.datetime.combine(d + dt.timedelta(days=1), dt.time(9), TZ).timestamp()))


def eval_time(d: dt.date) -> int:
    """The night of evening d has finished at 08:59:59 the next morning."""
    return night_bounds(d)[1] - 1


def night_dates(end: int, first: dt.date = FIRST_NIGHT) -> list[dt.date]:
    """The experiment nights from first that finished by end."""
    out, d = [], first
    while d <= LAST_NIGHT and eval_time(d) <= end:
        out.append(d)
        d += dt.timedelta(days=1)
    return out


def fetch(base: str, get, dates: list[dt.date]) -> dict[str, dict[int, float]]:
    """{series: {epoch s: value}} for SERIES over dates (an hour either side), from Prometheus."""
    data: dict[str, dict[int, float]] = {k: {} for k in SERIES}
    if not dates:
        return data
    import report_hvac_cycles as report  # here, not at the top: the report imports this module
    t0, t1 = night_bounds(dates[0])[0] - MARGIN, night_bounds(dates[-1])[1] + MARGIN
    for s in report.query_range(base, POWER_Q, t0, t1, get, MINUTE):
        if s["metric"].get("channel") in ("7", "98"):
            data[s["metric"]["channel"]].update(s["values"])
    for s in report.query_range(base, HEAT_Q, t0, t1, get, MINUTE):
        data["heat"].update(s["values"])
    for s in report.query_range(base, SENSOR_Q, t0, t1, get, SLOW):
        if s["metric"].get("entity") in SENSORS:
            data[SENSORS[s["metric"]["entity"]]].update(s["values"])
    for key, q in (("tstat", TSTAT_Q), ("target", TARGET_Q)):
        for s in report.query_range(base, q, t0, t1, get, SLOW):
            data[key].update(s["values"])
    return data


# ---- per night (pure: series in, figures out) --------------------------------------------------

def fahrenheit(c: float) -> float:
    return c * 9 / 5 + 32


def slot(ts: int) -> int:
    """The 5-minute reading in force at minute ts."""
    return ts - ts % SLOW


def stretches(ts: list[int], step: int) -> list[tuple[int, int]]:
    """(first, last) of each run of timestamps exactly step apart."""
    out: list[list[int]] = []
    for t in ts:
        if out and t - out[-1][1] == step:
            out[-1][1] = t
        else:
            out.append([t, t])
    return [(a, b) for a, b in out]


def frozen_readings(data: dict, t_from: int, t_to: int) -> set[int]:
    """5-minute readings in t_from..t_to inside a run of FROZEN_MIN or more with no Ecobee indoor change."""
    keys = ROOMS + ("tstat",)
    out: set[int] = set()
    run: list[int] = []
    prev = None
    for t in range(t_from, t_to + 1, SLOW):
        k = tuple(data[n].get(t) for n in keys)
        if all(v is None for v in k):
            k = None
        if k is not None and k == prev:
            run.append(t)
        else:
            if len(run) * SLOW >= FROZEN_MIN * 60:
                out.update(run)
            run = [t] if k is not None else []
        prev = k
    if len(run) * SLOW >= FROZEN_MIN * 60:
        out.update(run)
    return out


def dips(p98: dict[int, float], t_from: int, t_to: int) -> list[dict]:
    """Each stretch above standby and under RUN_W that starts right after a run minute, in t_from..t_to."""
    out = []
    for m in range(t_from, t_to, MINUTE):
        before, w = p98.get(m - MINUTE), p98.get(m)
        if before is None or w is None or before < RUN_W or not STANDBY_W < w < RUN_W:
            continue
        n, t = 0, m
        while n < 2 * LONG_DIP_MIN and (v := p98.get(t)) is not None and STANDBY_W < v < RUN_W:
            n, t = n + 1, t + MINUTE
        after = p98.get(t)
        recovered = after is not None and after >= RUN_W
        out.append({"start": m, "minutes": n, "recovered": recovered,
                    "defrost": recovered and DEFROST_MIN[0] <= n <= DEFROST_MIN[1],
                    "long": n >= LONG_DIP_MIN and all(p98[m + k * MINUTE] < ICED_W for k in range(LONG_DIP_MIN))})
    return out


def lock_kind(lock: list[float | None], readings: list[int]) -> tuple[str, int | None]:
    """(kind, the reading at which a comfort stop showed) from the night's 5-minute lockout readings."""
    hp = [i for i, v in enumerate(lock) if v is not None and v < LOCK_HP_C]
    gas = sum(1 for v in lock if v is not None and v > LOCK_GAS_C)
    if len(hp) >= LOCK_HP_MIN_READINGS:
        back = [i for i in range(hp[-1] + 1, len(lock))
                if lock[i] is not None and LOCK_NORMAL_C[0] <= lock[i] <= LOCK_NORMAL_C[1]]
        if back:
            return "comfort_stopped", readings[back[0]]
    if len(hp) >= len(lock) / 2:
        return "heat_pump", None
    if gas >= len(lock) / 2:
        return "gas", None
    return "not_running", None


def night_record(d: dt.date, data: dict[str, dict[int, float]]) -> dict:
    """One night's figures from the fetched series (see fetch); no I/O."""
    t0, t1 = night_bounds(d)
    minutes = list(range(t0, t1, MINUTE))
    readings = list(range(t0, t1, SLOW))
    night_min = len(minutes)
    p98, p7, heat, lock_s = data["98"], data["7"], data["heat"], data["lock"]
    out_s, amb = data["out"], data["amb"]

    kind, stopped_at = lock_kind([lock_s.get(t) for t in readings], readings)
    frozen = frozen_readings(data, t0 - MARGIN, t1 + MARGIN)

    # Indoor, with Ambient standing in for frozen Ecobee readings.
    room = {}
    for t in readings:
        vals = [data[r][t] for r in ROOMS if t in data[r]]
        if vals:
            room[t] = sum(vals) / len(vals)
    diffs = [room[t] - amb[t] for t in readings if t not in frozen and t in room and t in amb]
    offset = statistics.median(diffs) if diffs else None
    indoor = {}
    for t in readings:
        if t in frozen:
            if offset is not None and t in amb:
                indoor[t] = amb[t] + offset
        elif t in room:
            indoor[t] = room[t]
    pairs = [indoor[t] - out_s[t] for t in readings if t in indoor and t in out_s]
    dfh = sum(pairs) / len(pairs) * 1.8 * night_min / 60 if pairs else None
    outs = [out_s[t] for t in readings if t in out_s]
    night_frozen = [t for t in readings if t in frozen]

    # Power: furnace stages, kWh.
    def stage(m: int) -> str | None:
        w7, w98 = p7.get(m), p98.get(m)
        if w7 is None or w98 is None or w7 < LOW_W:
            return None
        if any(p98.get(m + k * MINUTE, 0) >= HP_W for k in range(-FURNACE_GUARD_MIN, FURNACE_GUARD_MIN + 1)):
            return None
        return "low" if w7 < HIGH_W else "high"
    stages = {m: stage(m) for m in minutes}
    power_min = sum(1 for m in minutes if m in p98 and m in p7)
    scale = night_min / power_min if power_min else 0.0
    raw = {"low": 0, "high": 0}
    ends = {"low": 0, "high": 0}
    for a, b in stretches([m for m in minutes if stages[m]], MINUTE):
        for m in range(a, b + 1, MINUTE):
            raw[stages[m]] += 1
        ends[stages[b]] += 1
    burner = {s: max(0.0, raw[s] - CYCLE_TAIL_MIN * ends[s]) * scale for s in raw}
    furnace_kwh = sum(burner[s] * FURNACE_KWH_MIN[s] for s in burner)
    wmin = sum(p98[m] for m in minutes if p98.get(m, 0) > STANDBY_W)
    wmin += sum(p7[m] for m in minutes if p7.get(m, 0) > BLOWER_ON_W and not stages[m])
    kwh = wmin / 60000 * scale

    # Defrosts and long dips, on every night (the unit runs above 35 °F on normal nights too).
    found = dips(p98, t0, t1)
    defrosts = [{"start": x["start"], "minutes": x["minutes"],
                 "outdoor_f": None if out_s.get(slot(x["start"])) is None else round(fahrenheit(out_s[slot(x["start"])]), 1)}
                for x in found if x["defrost"]]
    starts = [x["start"] for x in defrosts]
    burst = next((starts[i] for i in range(len(starts) - DEFROSTS_PER_HOUR + 1)
                  if starts[i + DEFROSTS_PER_HOUR - 1] - starts[i] <= 3600), None)

    # Standby during a heating call, on the night's -15 °F minutes.
    standby = []
    if kind in HP_KINDS:
        standby = [m for m in minutes
                   if p98.get(m, STANDBY_W) < STANDBY_W and m in heat and p7.get(m, 0) < LOW_W
                   and lock_s.get(slot(m), 0) < LOCK_HP_C and slot(m) not in frozen]
    long_standby = [{"start": a, "minutes": (b - a) // MINUTE + 1}
                    for a, b in stretches(standby, MINUTE) if (b - a) // MINUTE + 1 > STANDBY_STOP_MIN]

    # 08:30: the thermostat's reading (Ambient plus the night's offset when frozen) against its target.
    t830 = int(dt.datetime.combine(d + dt.timedelta(days=1), dt.time(8, 30), TZ).timestamp())
    tstat, target = data["tstat"].get(t830), data["target"].get(t830)
    if t830 in frozen:
        td = [data["tstat"][t] - amb[t] for t in readings if t not in frozen and t in data["tstat"] and t in amb]
        tstat = amb[t830] + statistics.median(td) if td and t830 in amb else None
    gap = None if tstat is None or target is None else (tstat - target) * 1.8

    calibrated = not night_frozen or offset is not None
    return {
        "night": d.isoformat(), "kind": kind, "stopped_at": stopped_at,
        "outdoor_f": round(fahrenheit(sum(outs) / len(outs)), 1) if outs else None,
        "deg_f_hours": None if dfh is None else round(dfh, 1),
        "kwh": round(kwh, 2), "furnace_low_min": round(burner["low"], 1), "furnace_high_min": round(burner["high"], 1),
        "furnace_kwh": round(furnace_kwh, 2),
        "furnace_minutes": {"low": raw["low"], "high": raw["high"], "cycles": ends["low"] + ends["high"]},
        "defrosts": defrosts, "defrost_burst_at": burst,
        "long_dips": [x["start"] for x in found if x["long"]],
        "standby_call_min": len(standby), "standby_stretches": long_standby,
        "gap_0830_f": None if gap is None else round(gap, 1),
        "held_0830": None if gap is None else abs(gap) <= HOLD_F,
        "frozen_min": len(night_frozen) * SLOW // 60,
        "frozen_spans": [[a, b + SLOW] for a, b in stretches(night_frozen, SLOW)],
        "ambient_offset_f": None if offset is None else round(offset * 1.8, 1),
        "minutes": {"night": night_min, "power": power_min, "indoor": len(indoor) * SLOW // 60,
                    "outdoor": len(outs) * SLOW // 60},
        "complete": (power_min >= POWER_COMPLETE * night_min and len(indoor) >= TEMP_COMPLETE * len(readings)
                     and len(outs) >= TEMP_COMPLETE * len(readings) and calibrated),
        "calibrated": calibrated,
    }


def nights(base: str, get, end: int, first: dt.date = FIRST_NIGHT) -> list[dict]:
    """The records of every night from first that finished by end."""
    dates = night_dates(end, first)
    data = fetch(base, get, dates)
    return [night_record(d, data) for d in dates]


# ---- bands and money ---------------------------------------------------------------------------

def site_saved_per_kwh_heat(cop: float) -> float:
    """Site energy (gas plus electricity at the meters) saved per kWh of heat from the heat pump."""
    return 1 / AFUE - 1 / cop


def extra_dollars_per_kwh_heat(cop: float, e: float = E_PRICE, g: float = GAS_PRICE) -> float:
    return e / cop - g / (KWH_PER_THERM * AFUE)


def dollars_per_kwh_saved(cop: float, e: float = E_PRICE, g: float = GAS_PRICE) -> float:
    return extra_dollars_per_kwh_heat(cop, e, g) / site_saved_per_kwh_heat(cop)


def co2_extra_per_kwh_heat(cop: float) -> float:
    return GRID_CO2 / cop - GAS_CO2 / (KWH_PER_THERM * AFUE)


def band_of(f: float) -> int:
    return int(math.floor(f / BAND_F) * BAND_F)


HP_KINDS = ("heat_pump", "comfort_stopped")


def bands(nights: list[dict]) -> list[dict]:
    by: dict[int, dict] = {}
    for n in nights:
        if not n["complete"] or n["kind"] not in HP_KINDS + ("gas",) or not n["deg_f_hours"]:
            continue
        b = by.setdefault(band_of(n["outdoor_f"]), {"gas": [], "hp": []})
        b["gas" if n["kind"] == "gas" else "hp"].append(n)
    out = []
    for lo in sorted(by):
        gas, hp = by[lo]["gas"], by[lo]["hp"]
        b = {"band_f": [lo, lo + BAND_F], "gas_nights": len(gas), "hp_nights": len(hp),
             "need_kwh_per_deg_f_hour": None, "cop": None}
        if len(gas) >= MIN_NIGHTS:
            need = sum(n["furnace_kwh"] for n in gas) / sum(n["deg_f_hours"] for n in gas)
            b["need_kwh_per_deg_f_hour"] = round(need, 4)
            heat = [need * n["deg_f_hours"] - n["furnace_kwh"] for n in hp]
            b["hp_heat_kwh"] = [round(h, 2) for h in heat]
            kwh = sum(n["kwh"] for n in hp)
            if len(hp) >= MIN_NIGHTS and kwh > 0 and sum(heat) > 0:
                cop = sum(heat) / kwh
                per_night = sum(heat) / len(hp)
                b.update({"cop": round(cop, 2), "heat_kwh_per_night": round(per_night, 1),
                          "site_kwh_saved_per_night": round(per_night * site_saved_per_kwh_heat(cop), 1),
                          "extra_dollars_per_night": round(per_night * extra_dollars_per_kwh_heat(cop), 2),
                          "co2_extra_kg_per_night": round(per_night * co2_extra_per_kwh_heat(cop), 2),
                          "co2_gas_kg_per_night": round(per_night * GAS_CO2 / (KWH_PER_THERM * AFUE), 2)})
        out.append(b)
    return out


def season_totals(nights: list[dict], bl: list[dict]) -> dict:
    need = {b["band_f"][0]: b["need_kwh_per_deg_f_hour"] for b in bl}
    hp = [n for n in nights if n["kind"] in HP_KINDS]
    extra = saved = 0.0
    counted = 0
    for n in hp:
        k = need.get(band_of(n["outdoor_f"])) if n["complete"] and n["deg_f_hours"] else None
        if k is None:
            continue
        heat = k * n["deg_f_hours"] - n["furnace_kwh"]
        extra += n["kwh"] * E_PRICE - heat * GAS_PRICE / (KWH_PER_THERM * AFUE)
        saved += heat / AFUE - n["kwh"]
        counted += 1
    return {"hp_nights": len(hp), "counted": counted, "extra_dollars": round(extra, 2), "site_kwh_saved": round(saved, 1)}


# ---- text --------------------------------------------------------------------------------------

def name(d: str) -> str:
    return dt.date.fromisoformat(d).strftime("%a %m-%d")


def hm(ts: int) -> str:
    return dt.datetime.fromtimestamp(ts, TZ).strftime("%H:%M")


def plural(k: int, one: str, many: str | None = None) -> str:
    return f"{k} {one if k == 1 else (many or one + 's')}"


def stop_events(n: dict) -> list[tuple[str, str]]:
    """(rule, sentence) for each stop rule this night tripped."""
    out = []
    if n["kind"] == "comfort_stopped":
        at = f" at {hm(n['stopped_at'])}" if n["stopped_at"] else ""
        out.append(("comfort stop", f"The heat pump night of {name(n['night'])} ended early{at}: the comfort "
                                    f"stop (or the stop switch) set 35 °F and the gas furnace took over."))
    for s in n["standby_stretches"]:
        out.append(("standby", f"On the heat pump night of {name(n['night'])} the outdoor unit sat at standby for "
                               f"{s['minutes']} minutes from {hm(s['start'])} while the thermostat called for heat: "
                               f"turn on HVAC experiment stop and check the outdoor unit."))
    why = []
    if n["kind"] in HP_KINDS and n["defrost_burst_at"]:
        why.append(f"{DEFROSTS_PER_HOUR} defrosts within an hour from {hm(n['defrost_burst_at'])}")
    if n["kind"] in HP_KINDS and n["long_dips"]:
        why.append(f"the outdoor unit still under 1 kW 15 minutes after a defrost at {hm(n['long_dips'][0])}")
    if why:
        out.append(("possible icing", f"Possible icing on the heat pump night of {name(n['night'])}: "
                                      f"{' and '.join(why)}: turn on HVAC experiment stop and look at the coil."))
    return out


def band_name(b: dict) -> str:
    lo, hi = b["band_f"]
    return f"{lo} to {hi} °F" if lo < 0 else f"{lo}-{hi} °F"


def band_line(b: dict) -> str:
    if b["cop"] is None:
        return (f"  {band_name(b)}: {plural(b['gas_nights'], 'gas night')} and "
                f"{plural(b['hp_nights'], 'heat pump night')} so far; a COP needs {MIN_NIGHTS} of each.")
    saved, extra = b["site_kwh_saved_per_night"], b["extra_dollars_per_night"]
    if saved > 0 and extra > 0:
        money = f"it saved {saved:.0f} kWh a night for ${extra:.2f} more, ${extra / saved:.2f} per kWh saved"
    elif saved > 0:
        money = f"it saved {saved:.0f} kWh and ${-extra:.2f} a night"
    else:
        money = f"it used {-saved:.0f} kWh more a night and cost ${extra:.2f} more"
    co2 = b["co2_extra_kg_per_night"]
    co2_text = ("CO2 about even" if abs(co2) < 0.1 * b["co2_gas_kg_per_night"]
                else f"about {abs(co2):.1f} kg {'more' if co2 > 0 else 'less'} CO2")
    return f"  {band_name(b)}: COP about {b['cop']:.1f} over {b['hp_nights']} nights; {money}; {co2_text}."


def week_line(week: list[dict]) -> str:
    hp = [n for n in week if n["kind"] in HP_KINDS]
    gas = [n for n in week if n["kind"] == "gas"]
    text = f"This week: {plural(len(hp), 'heat pump night')} and {plural(len(gas), 'gas night')}."
    cold = min((n for n in hp if n["outdoor_f"] is not None), key=lambda n: n["outdoor_f"], default=None)
    if cold:
        parts = []
        if cold["kind"] == "comfort_stopped":
            parts.append("the comfort stop handed it to the gas furnace" +
                         (f" at {hm(cold['stopped_at'])}" if cold["stopped_at"] else ""))
        elif cold["furnace_low_min"] + cold["furnace_high_min"] >= 1:
            parts.append(f"the gas furnace also ran {cold['furnace_low_min'] + cold['furnace_high_min']:.0f} min")
        if cold["held_0830"] is False:
            parts.append(f"at 08:30 the house was {abs(cold['gap_0830_f']):.1f} °F "
                         f"{'below' if cold['gap_0830_f'] < 0 else 'above'} the setpoint")
        if not parts:
            parts.append("the heat pump held the setpoint alone" if cold["held_0830"]
                         else "the heat pump ran alone; the 08:30 reading is missing")
        text += (f" The coldest heat pump night was {name(cold['night'])} at {cold['outdoor_f']:.1f} °F; "
                 f"{'; '.join(parts)}.")
    off = [n for n in week if n["kind"] == "not_running"]
    if off:
        text += (f" {plural(len(off), 'night')} without the experiment: {', '.join(name(n['night']) for n in off)} "
                 f"(the lockout was not -15 or 65 °F: stopped, or no data).")
    return text


def text_lines(exp: dict) -> list[str]:
    lines = [f"Winter experiment: heat pump nights against gas nights ({name(FIRST_NIGHT.isoformat())} "
             f"to {name(LAST_NIGHT.isoformat())})"]
    if exp.get("error"):
        return lines + [f"- The experiment figures could not be read: {exp['error']}"]
    nights = exp["nights"]
    if not nights:
        return lines + [f"- No experiment night has finished yet; the first is {name(FIRST_NIGHT.isoformat())}."]
    stops = exp["stops"]
    now = [s for s in stops if s["this_week"] or s["rule"] == "low COP"]
    lines += [f"- {s['text']}" for s in now] or ["- Nothing in the experiment needs action now."]
    earlier = [s for s in stops if not s["this_week"] and s["rule"] != "low COP"]
    if earlier:
        lines.append("- Earlier this season: " + "; ".join(f"{s['rule']} {name(s['night'])}" for s in earlier) + ".")
    lines.append(f"- {week_line([n for n in nights if n['night'] in exp['week']])}")
    if exp["bands"]:
        lines.append("- By night mean outdoor temperature (estimates: each night's heat need is taken from "
                     "gas nights in the same 5 °F band):")
        lines += [band_line(b) for b in exp["bands"]]
    s = exp["season"]
    if s["counted"]:
        cost = f"${abs(s['extra_dollars']):.2f} {'more' if s['extra_dollars'] >= 0 else 'less'}"
        lines.append(f"- Season so far, against gas every night: the heat pump nights cost about {cost} and "
                     f"saved about {s['site_kwh_saved']:.0f} kWh of site energy (estimate, "
                     f"{s['counted']} of {plural(s['hp_nights'], 'heat pump night')}).")
    elif s["hp_nights"]:
        lines.append(f"- Season so far: no heat pump night can be priced yet; its band needs {MIN_NIGHTS} gas nights first.")
    lines.append(f"- Prices used: electricity ${E_PRICE}/kWh (We Energies Rg-1, 2026); gas ${GAS_PRICE}/therm "
                 f"(Wisconsin Gas Rg-1, {GAS_PRICE_MONTH}; it changes monthly).")
    froze = [n for n in nights if n["frozen_min"]]
    if froze:
        lines.append("- The Ecobee readings froze on " + ", ".join(
            f"{name(n['night'])} ({n['frozen_min'] / 60:.1f} h)" for n in froze) +
            "; the Ambient indoor sensor stood in, shifted by each night's median difference from the Ecobee rooms"
            + ("" if all(n["calibrated"] for n in froze) else
               " (a night with no unfrozen minute has no such difference and is left out)") + ".")
    short = [n for n in nights if not n["complete"] and n["kind"] != "not_running" and n["calibrated"]]
    if short:
        lines.append("- Left out of the estimates for missing data: " + ", ".join(name(n["night"]) for n in short) + ".")
    return lines


def compute(nights: list[dict], start: int, end: int) -> dict:
    """The section from the night records: bands, season totals, stop rules, text lines."""
    bl = bands(nights)
    week = [n["night"] for n in nights if start <= eval_time(dt.date.fromisoformat(n["night"])) <= end]
    stops = []
    for n in nights:
        for rule, text in stop_events(n):
            stops.append({"rule": rule, "night": n["night"], "text": text, "this_week": n["night"] in week})
    for b in bl:
        if b["cop"] is not None and b["cop"] < COP_STOP:
            stops.append({"rule": "low COP", "night": None, "this_week": True,
                          "text": f"At {band_name(b)} the heat pump's COP was about {b['cop']:.1f} over "
                                  f"{b['hp_nights']} nights, under {COP_STOP:.1f}: recommend raising the heat pump "
                                  f"nights' floor above {b['band_f'][1]} °F; that is your call."})
    order = ["comfort stop", "low COP", "standby", "possible icing"]
    stops.sort(key=lambda s: order.index(s["rule"]))
    exp = {"nights": nights, "bands": bl, "season": season_totals(nights, bl), "week": week, "stops": stops,
           "prices": {"electricity_per_kwh": E_PRICE, "gas_per_therm": GAS_PRICE, "gas_month": GAS_PRICE_MONTH}}
    exp["lines"] = text_lines(exp)
    return exp


def in_season(end: int, first: dt.date = FIRST_NIGHT) -> bool:
    return first <= dt.datetime.fromtimestamp(end, TZ).date() <= SHOW_UNTIL


def section(start: int, end: int, base: str, get, first: dt.date = FIRST_NIGHT) -> dict | None:
    """The experiment section for a report window, None outside first..2027-04-07."""
    if not in_season(end, first):
        return None
    try:
        return compute(nights(base, get, end, first), start, end)
    except Exception as e:  # noqa: BLE001 - the rest of the mail still goes out, with this line in it
        exp = {"error": f"{type(e).__name__}: {e}"}
        exp["lines"] = text_lines(exp)
        return exp


# ---- stand-in nights (report_hvac_cycles.py --selftest runs selftest_checks) --------------------

STANDIN_FIRST = dt.date(2026, 11, 12)
STANDIN_END = int(dt.datetime(2026, 11, 20, 9, 0, tzinfo=TZ).timestamp())  # a mail on Fri 11-20 09:00


def standin() -> dict[str, dict[int, float]]:
    """Stand-in series for the nights 11-12 to 11-19, each night one case:

    11-12 heat pump, 45.5 °F, a long dip from 23:40 (before the week: an earlier-this-season line)
    11-13 gas, 32 °F, 8 low-stage cycles of 20 min
    11-14 heat pump, 32 °F, 300 min, a 3-minute defrost at 23:00
    11-15 gas, 32 °F, 6 low cycles of 20 min and 2 high of 15 min at 199 W
    11-16 heat pump, 31.1 °F, mixed: a 20-minute low furnace cycle at 05:00; Ecobee frozen 02:00-03:55
          (the rooms read 20 °C, Ambient 18.5: the indoor figure is 19.0 there)
    11-17 gas, 22.1 °F, 6 high cycles of 25 min
    11-18 comfort-stopped at 03:00, 22.1 °F: 3 defrosts from 22:10, 25 min at standby in a call from
          00:00, then 3 high furnace cycles of 25 min
    11-19 no lockout readings: not running
    Rooms 20 °C (one room and the thermostat alternate 20.1 and 19.9), Ambient indoor 0.5 below.
    """
    first = STANDIN_FIRST
    night = {i: first + dt.timedelta(days=i) for i in range(8)}
    lo, hi = night_bounds(night[0])[0] - 2 * MARGIN, night_bounds(night[7])[1] + 2 * MARGIN
    data: dict[str, dict[int, float]] = {k: {} for k in SERIES}

    def at(i: int, h: int, m: int = 0) -> int:
        day = night[i] + dt.timedelta(days=0 if h >= 12 else 1)
        return int(dt.datetime.combine(day, dt.time(h, m), TZ).timestamp())

    def put(i, a, b, w98=None, w7=None, call=False):  # minutes a..b, (h, m) on night i, inclusive
        for m in range(at(i, *a), at(i, *b) + 1, MINUTE):
            if w98 is not None:
                data["98"][m] = w98
            if w7 is not None:
                data["7"][m] = w7
            if call:
                data["heat"][m] = 1.0

    def furnace(i, starts, minutes, w):
        for h, m in starts:
            s = at(i, h, m)
            put(i, (h, m), dt.datetime.fromtimestamp(s + (minutes - 1) * MINUTE, TZ).timetuple()[3:5], w7=w, call=True)

    hourly = [(h, 30) for h in (21, 22, 23, 0, 1, 2, 3, 4)]
    for m in range(lo, hi, MINUTE):
        data["98"][m], data["7"][m] = 60.0, 2.0
    put(0, (22, 0), (23, 39), 2400.0, 200.0, True)
    put(0, (23, 40), (23, 59), 800.0)
    furnace(1, hourly, 20, 112.0)
    put(2, (22, 0), (2, 59), 2400.0, 200.0, True)
    put(2, (23, 0), (23, 2), 800.0)
    furnace(3, hourly[:6], 20, 112.0)
    furnace(3, hourly[6:], 15, 199.0)
    put(4, (22, 0), (2, 59), 2400.0, 200.0, True)
    furnace(4, [(5, 0)], 20, 112.0)
    furnace(5, hourly[:6], 25, 176.0)
    put(6, (21, 30), (23, 59), 2400.0, 200.0, True)
    for m in (10, 25, 40):
        put(6, (22, m), (22, m + 2), 800.0)
    put(6, (0, 0), (0, 24), call=True)
    put(6, (0, 25), (2, 59), 2400.0, 200.0, True)
    furnace(6, [(3, 5), (4, 5), (5, 5)], 25, 176.0)

    out_c = {0: 7.5, 1: 0.0, 2: 0.0, 3: 0.0, 4: -0.5, 5: -5.5, 6: -5.5, 7: 4.5}
    lock_c = {0: -26.1, 1: 18.3, 2: -26.1, 3: 18.3, 4: -26.1, 5: 18.3, 6: -26.1}
    for t in range(lo, hi, SLOW):
        i = (dt.datetime.fromtimestamp(t, TZ) - dt.timedelta(hours=12)).date().toordinal() - first.toordinal()
        frozen = at(4, 2, 0) <= t <= at(4, 3, 55)
        up = 20.0 if frozen else 20.0 + (0.1 if (t // SLOW) % 2 == 0 else -0.1)
        for r in ROOMS:
            data[r][t] = up if r == ROOMS[0] else 20.0
        data["tstat"][t], data["target"][t] = up, 20.0
        data["amb"][t] = 18.5 if frozen else (up + 4 * 20.0) / 5 - 0.5
        data["out"][t] = out_c.get(i, 4.5)
        if i in night and night_bounds(night[i])[0] <= t < night_bounds(night[i])[1]:
            if i in lock_c:
                data["lock"][t] = 1.7 if i == 6 and t >= at(6, 3, 0) else lock_c[i]
        else:
            data["lock"][t] = 1.7
    return data


def standin_get(data: dict[str, dict[int, float]]):
    """A get(url) answering fetch's query_range requests from data, as Prometheus would."""
    import urllib.parse

    def get(url: str) -> dict:
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        expr, s, e, step = q["query"][0], int(q["start"][0]), int(q["end"][0]), int(q["step"][0])

        def series(metric: dict, values: dict[int, float]) -> dict:
            return {"metric": metric, "values": [[t, str(v)] for t, v in sorted(values.items())
                                                 if s <= t <= e and (t - s) % step == 0]}
        if "emporia" in expr:
            res = [series({"channel": c}, data[c]) for c in ("7", "98")]
        elif "climate_action" in expr:
            res = [series({}, data["heat"])]
        elif "sensor_temperature" in expr:
            res = [series({"entity": ent}, data[k]) for ent, k in SENSORS.items()]
        elif "current_temperature" in expr:
            res = [series({}, data["tstat"])]
        elif "target_temperature" in expr:
            res = [series({}, data["target"])]
        else:
            raise ValueError(f"unexpected query {expr}")
        return {"status": "success", "data": {"result": res}}
    return get


def selftest_checks() -> list[tuple[str, bool]]:
    """(name, passed) for the stand-in nights, through fetch with a stub get."""
    end = STANDIN_END
    start = end - 7 * 86400 + MINUTE
    exp = section(start, end, "http://stub", standin_get(standin()), STANDIN_FIRST)
    if exp.get("error"):
        return [(f"stand-in section runs: {exp['error']}", False)]
    n = {x["night"][5:]: x for x in exp["nights"]}
    b = {x["band_f"][0]: x for x in exp["bands"]}
    when = lambda ts: hm(ts) if ts else None  # noqa: E731
    checks = [
        ("kinds", [(k, x["kind"]) for k, x in n.items()] == [
            ("11-12", "heat_pump"), ("11-13", "gas"), ("11-14", "heat_pump"), ("11-15", "gas"), ("11-16", "heat_pump"),
            ("11-17", "gas"), ("11-18", "comfort_stopped"), ("11-19", "not_running")]),
        ("comfort stop at 03:00", when(n["11-18"]["stopped_at"]) == "03:00"),
        ("heat pump night: kWh, no furnace", (n["11-14"]["kwh"], n["11-14"]["furnace_kwh"]) == (12.92, 0.0)),
        ("gas night: 8 low cycles, burner 148 min", (n["11-13"]["furnace_minutes"], n["11-13"]["furnace_low_min"],
                                                     n["11-13"]["furnace_kwh"]) == ({"low": 160, "high": 0, "cycles": 8}, 148.0, 27.47)),
        ("high stage at 199 W counts", (n["11-15"]["furnace_minutes"], n["11-15"]["furnace_kwh"])
         == ({"low": 120, "high": 30, "cycles": 8}, 28.25)),
        ("mixed night: furnace minutes on a heat pump night", (n["11-16"]["furnace_minutes"], n["11-16"]["furnace_low_min"],
                                                              n["11-16"]["furnace_kwh"], n["11-16"]["kwh"])
         == ({"low": 20, "high": 0, "cycles": 1}, 18.5, 3.43, 13.0)),
        ("furnace after a comfort stop, guard kept", n["11-18"]["furnace_minutes"] == {"low": 0, "high": 75, "cycles": 3}),
        ("a defrost", [(hm(x["start"]), x["minutes"], x["outdoor_f"]) for x in n["11-14"]["defrosts"]] == [("23:00", 3, 32.0)]
         and n["11-14"]["defrost_burst_at"] is None),
        ("3 defrosts in an hour", when(n["11-18"]["defrost_burst_at"]) == "22:10" and len(n["11-18"]["defrosts"]) == 3),
        ("long dip, not a defrost", ([hm(t) for t in n["11-12"]["long_dips"]], n["11-12"]["defrosts"]) == (["23:40"], [])),
        ("standby in a call", [(hm(x["start"]), x["minutes"]) for x in n["11-18"]["standby_stretches"]] == [("00:00", 25)]),
        ("frozen Ecobee: span and Ambient offset", (n["11-16"]["frozen_min"], [[hm(a), hm(z)] for a, z in n["11-16"]["frozen_spans"]],
                                                   n["11-16"]["ambient_offset_f"]) == (120, [["02:00", "04:00"]], 0.9)),
        ("frozen Ecobee: Ambient stands in (19.0 °C there, not 20)", n["11-16"]["deg_f_hours"] == 439.2
         and n["11-16"]["complete"]),
        ("°F-hours", [n[k]["deg_f_hours"] for k in ("11-12", "11-13", "11-17")] == [270.0, 432.0, 550.8]),
        ("08:30 held", all(x["held_0830"] and x["gap_0830_f"] == 0.2 for x in n.values())),
        ("band 30-35 has 2+2: need and COP", (b[30]["gas_nights"], b[30]["hp_nights"], b[30]["need_kwh_per_deg_f_hour"],
                                              b[30]["hp_heat_kwh"], b[30]["cop"]) == (2, 2, 0.0645, [27.86, 24.89], 2.04)),
        ("band 20-25 has 1+1: no COP", (b[20]["gas_nights"], b[20]["hp_nights"], b[20]["cop"]) == (1, 1, None)),
        ("week", exp["week"] == [f"2026-11-{d}" for d in range(13, 20)]),
    ]
    want = [
        "Winter experiment: heat pump nights against gas nights (Thu 11-12 to Wed 03-31)",
        "- The heat pump night of Wed 11-18 ended early at 03:00: the comfort stop (or the stop switch) set 35 °F and "
        "the gas furnace took over.",
        "- On the heat pump night of Wed 11-18 the outdoor unit sat at standby for 25 minutes from 00:00 while the "
        "thermostat called for heat: turn on HVAC experiment stop and check the outdoor unit.",
        "- Possible icing on the heat pump night of Wed 11-18: 3 defrosts within an hour from 22:10: turn on HVAC "
        "experiment stop and look at the coil.",
        "- Earlier this season: possible icing Thu 11-12.",
        "- This week: 3 heat pump nights and 3 gas nights. The coldest heat pump night was Wed 11-18 at 22.1 °F; the "
        "comfort stop handed it to the gas furnace at 03:00. 1 night without the experiment: Thu 11-19 (the lockout "
        "was not -15 or 65 °F: stopped, or no data).",
        "- By night mean outdoor temperature (estimates: each night's heat need is taken from gas nights in the same "
        "5 °F band):",
        "  20-25 °F: 1 gas night and 1 heat pump night so far; a COP needs 2 of each.",
        "  30-35 °F: COP about 2.0 over 2 nights; it saved 14 kWh a night for $1.88 more, $0.13 per kWh saved; "
        "about 0.7 kg more CO2.",
        "  45-50 °F: 0 gas nights and 1 heat pump night so far; a COP needs 2 of each.",
        "- Season so far, against gas every night: the heat pump nights cost about $3.76 more and saved about 28 kWh "
        "of site energy (estimate, 2 of 4 heat pump nights).",
        f"- Prices used: electricity ${E_PRICE}/kWh (We Energies Rg-1, 2026); gas ${GAS_PRICE}/therm "
        f"(Wisconsin Gas Rg-1, {GAS_PRICE_MONTH}; it changes monthly).",
        "- The Ecobee readings froze on Mon 11-16 (2.0 h); the Ambient indoor sensor stood in, shifted by each "
        "night's median difference from the Ecobee rooms.",
    ]
    checks.append(("section lines, in order", exp["lines"] == want))
    checks += [(f"line: {w[:50]}", w in exp["lines"]) for w in want if w not in exp["lines"]]
    # The low COP stop: the same nights with three times the heat pump kWh.
    low = compute([dict(x, kwh=x["kwh"] * 3) if x["kind"] in HP_KINDS else x for x in exp["nights"]], start, end)
    checks.append(("low COP stop line", low["lines"][2] == (
        "- At 30-35 °F the heat pump's COP was about 0.7 over 2 nights, under 1.0: recommend raising the heat pump "
        "nights' floor above 35 °F; that is your call.")))
    checks.append(("low COP band line", "  30-35 °F: COP about 0.7 over 2 nights; it used 12 kWh more a night and "
                                         "cost $6.96 more; about 11.8 kg more CO2." in low["lines"]))
    # No stop tripped; the coldest heat pump night is the mixed one.
    calm = compute([n[k] for k in ("11-13", "11-14", "11-15", "11-16")], start, end)
    checks.append(("nothing needs action", calm["lines"][1] == "- Nothing in the experiment needs action now."))
    checks.append(("mixed night in the week line", calm["lines"][2] == (
        "- This week: 2 heat pump nights and 2 gas nights. The coldest heat pump night was Mon 11-16 at 31.1 °F; "
        "the gas furnace also ran 18 min.")))
    return [(f"experiment: {name}", ok) for name, ok in checks]
