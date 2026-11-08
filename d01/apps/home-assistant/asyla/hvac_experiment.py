#!/usr/bin/env python3
"""The winter experiment's section of the cold-spell HVAC mail: heat pump nights against gas nights. Read-only.

packages/hvac_experiment.yaml alternates nights from 2026-11-12 to 2027-03-31: at 21:00 it sets the
house Ecobee's compressor lockout to -15 °F (a heat pump night, an even number of days after 11-12)
or 65 °F (a gas night); at 09:00 it puts back the normal 35 °F; its comfort stop sets 35 early on a
heat pump night. report_hvac_cycles.py imports this module, puts its section at the top of the mail
from 2026-11-12 through 2027-04-07 (a week past the last night) and under "experiment" in --json.

A night runs 21:00 to 08:59 Chicago time and carries its evening's date. Every number is worked out
by theOrg's trends Prometheus (GET only): each night is one query_range point at 08:59:59 whose
[12h:1m] subqueries cover the night's 720 minutes, so the whole season is a few requests, not
minute data (HA's shell_command allows 60 s). DST-change nights (2027-03-13) are 11 h; the window
is still 12 h, so it starts an hour early that night. Per night:

    kind       from sensor.hvac_experiment_lockout (kept in °C by trends): heat_pump (-15 °F),
               comfort_stopped (-15, then 35 before 09:00: the comfort stop, or the stop switch,
               which looks the same), gas (65 °F), unknown (anything else: stopped, or no data)
    outdoor    the mean of sensor.mke_temperature (Ambient station)
    °F-hours   indoor (the mean of the five Ecobee room sensors) minus outdoor, per minute
    kWh        the outdoor unit over 150 W (standby reads about 60 W) plus the air handler (over
               40 W) when it is not a furnace minute
    furnace    air handler 95-145 W (low stage, about 112 W) or 145-190 W (high, about 176 W) with
               the outdoor unit under 500 W from 2 minutes before to 2 after (the heat pump's blower
               draws 190-200 W, and its lead and run-on minutes are the heat pump's). Burner minutes
               are those less 1.5 per cycle, in the cycle's last stage (the blower runs on after the
               burner stops). Heat: 38,000 Btu/h low, 58,000 high (output, Carrier 59TP7A-01PD p.4).
    defrosts   the outdoor unit below 1.2 kW (not at standby) for 2-10 minutes inside a heat pump
               run, then back above 1.2 kW. Inference: power alone cannot see the reversing valve.
    long dip   the outdoor unit still between standby and 1 kW 15 minutes after dropping from a run
    standby    minutes the outdoor unit sat at standby while the thermostat called for heat on a
               heat pump night, the furnace not running
    08:30      the thermostat's own reading within 2 °F of its target at 08:30

Power sums are scaled to 720 minutes when Emporia is a few minutes short (its data lags about 7 min).
A night with under 95 % of its power minutes or 90 % of its temperature minutes is left out of the
band figures.

Frozen Ecobee data: the Ecobee cloud sometimes stops every Ecobee value for hours. A minute is frozen
when no Ecobee indoor value (five rooms, the thermostat) changed in the hour before it or in the
hour after it; then sensor.mke_inside_temperature (Ambient, a different cloud) stands in, shifted
by the night's median room-minus-Ambient difference over its unfrozen minutes. A freeze under two
hours long can leave some of its middle minutes unmarked. With no unfrozen minute that night, the
offset is unknown and the night is left out of the band figures.

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
import re
import urllib.parse
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
NIGHT_MIN = 720
LOCK_HP_C = -20.0          # -15 °F is -26.1 °C
LOCK_GAS_C = 15.0          # 65 °F is 18.3 °C
LOCK_NORMAL_C = (0.5, 3.0)  # 35 °F is 1.7 °C (the write test's 30 °F is -1.1)
STANDBY_W, HP_W, ICED_W, RUN_W = 150, 500, 1000, 1200
BLOWER_ON_W, LOW_W, HIGH_W, HP_BLOWER_W = 40, 95, 145, 190
FROZEN_MIN = 60
HOLD_F = 2.0
STANDBY_STOP_MIN = 20
DEFROSTS_PER_HOUR = 3      # "more than 2 defrosts in an hour"
COP_STOP = 1.0
BAND_F = 5
MIN_NIGHTS = 2
POWER_COMPLETE, TEMP_COMPLETE = 0.95, 0.90
NIGHTS_PER_QUERY = 31      # query_range points per request, so a request stays well under 10 s
URL_CHARS = 6000           # quantities per request are packed under this many characters

JOB = 'job="asyla-home-assistant"'
ROOMS = "upstairs|office|kitchen|living_room|downstairs_hallway"
E98 = 'emporia_channel_power_watts{device="House",channel="98"}'   # outdoor unit
E7 = 'emporia_channel_power_watts{device="House",channel="7"}'     # air handler
LOCK_SEL = f'homeassistant_sensor_temperature_celsius{{entity="sensor.hvac_experiment_lockout",{JOB}}}'
OUT_SEL = f'homeassistant_sensor_temperature_celsius{{entity="sensor.mke_temperature",{JOB}}}'
AMB_SEL = f'homeassistant_sensor_temperature_celsius{{entity="sensor.mke_inside_temperature",{JOB}}}'
ROOM_SEL = f'homeassistant_sensor_temperature_celsius{{entity=~"sensor.({ROOMS})_temperature",{JOB}}}'
TSTAT_SEL = f'homeassistant_climate_current_temperature_celsius{{entity="climate.downstairs_hallway",{JOB}}}'
TARGET_SEL = f'homeassistant_climate_target_temperature_celsius{{entity="climate.downstairs_hallway",{JOB}}}'
HEAT_SEL = f'homeassistant_climate_action{{entity="climate.downstairs_hallway",action="heating",{JOB}}}'
ECO_SEL = ('{__name__=~"homeassistant_sensor_temperature_celsius|homeassistant_climate_current_temperature_celsius",'
           f'entity=~"sensor.({ROOMS})_temperature|climate.downstairs_hallway",{JOB}}}')


# ---- PromQL ------------------------------------------------------------------------------------
# Every term is wrapped in max()/avg() so its labels drop (Home Assistant's instance label changed
# once) and terms combine with and/unless/- without matching clauses. k is minutes before the
# subquery step (negative: after). Emporia samples sit on whole minutes; Prometheus 2.x ranges
# include both ends, so [8m] offset 3m is the 9 samples from 11 to 3 minutes back.

def _off(k: int) -> str:
    return f" offset {k}m" if k else ""


def last(sel: str, k: int = 0, rng: str = "5m") -> str:
    return f"max(last_over_time({sel}[{rng}]{_off(k)}))"


def p98(k: int = 0) -> str:
    return last(E98, k, "59s")


def p7(k: int = 0) -> str:
    return last(E7, k, "59s")


def max98(minutes: int, k: int = 0) -> str:
    return f"max(max_over_time({E98}[{minutes}m]{_off(k)}))"


def min98(minutes: int, k: int = 0) -> str:
    return f"min(min_over_time({E98}[{minutes}m]{_off(k)}))"


LOCK = last(LOCK_SEL)
OUT = last(OUT_SEL)
AMB = last(AMB_SEL)
TSTAT = last(TSTAT_SEL)
HEAT = last(HEAT_SEL)
ROOM = f"avg(avg by (entity) (last_over_time({ROOM_SEL}[5m])))"
ON_HP = f"({LOCK} < {LOCK_HP_C})"


def furnace(k: int = 0, lo: int = LOW_W, hi: int = HP_BLOWER_W) -> str:
    """A gas furnace minute: the air handler in [lo, hi) W, the outdoor unit under 500 W within 2 min."""
    return f"(({p7(k)} >= {lo}) < {hi}) and ({max98(4, k - 2)} < {HP_W})"


def frozen(k: int = 0) -> str:
    """Present when no Ecobee indoor value changed in the hour before, or the (full) hour after."""
    back = f"sum(changes({ECO_SEL}[{FROZEN_MIN}m]{_off(k)})) == 0"
    ahead = (f"sum(changes({ECO_SEL}[{FROZEN_MIN}m]{_off(k - FROZEN_MIN)})) == 0 and "
             f"sum(count_over_time({ECO_SEL}[{FROZEN_MIN}m]{_off(k - FROZEN_MIN)})) > 100")
    return f"(({back}) or ({ahead}))"


def night_queries() -> dict[str, str]:
    """Per-night quantities, each evaluated at the night's 08:59:59."""
    def sub(agg: str, inner: str) -> str:
        return f"{agg}(({inner})[12h:1m])"
    live = f"({ROOM} - {OUT}) unless {frozen()}"
    amb = f"({AMB} - {OUT}) and {frozen()}"
    low, high = furnace(0, LOW_W, HIGH_W), furnace(0, HIGH_W, HP_BLOWER_W)
    standby = f"({p98()} < {STANDBY_W}) and ({HEAT} == 1) and {ON_HP} and ({p7()} < {LOW_W}) unless {frozen()}"
    return {
        "lock_hp_min": sub("count_over_time", ON_HP),
        "lock_gas_min": sub("count_over_time", f"{LOCK} > {LOCK_GAS_C}"),
        "lock_hp_last": sub("max_over_time", f"vector(time()) and {ON_HP}"),
        "lock_end_c": LOCK,
        "power_min": sub("count_over_time", p98()),
        "outdoor_wmin": sub("sum_over_time", f"{p98()} > {STANDBY_W}"),
        "blower_wmin": sub("sum_over_time", f"({p7()} > {BLOWER_ON_W}) unless ({furnace()})"),
        "low_min": sub("count_over_time", low),
        "high_min": sub("count_over_time", high),
        "low_ends": sub("count_over_time", f"({low}) unless ({furnace(-1)})"),
        "high_ends": sub("count_over_time", f"({high}) unless ({furnace(-1)})"),
        "outdoor_c": sub("avg_over_time", OUT),
        "outdoor_min": sub("count_over_time", OUT),
        "live_sum_c": sub("sum_over_time", live),
        "live_min": sub("count_over_time", live),
        "amb_sum_c": sub("sum_over_time", amb),
        "amb_min": sub("count_over_time", amb),
        "room_minus_amb_c": f"quantile_over_time(0.5, (({ROOM} - {AMB}) unless {frozen()})[12h:1m])",
        "tstat_minus_amb_c": f"quantile_over_time(0.5, (({TSTAT} - {AMB}) unless {frozen()})[12h:1m])",
        "standby_min": sub("count_over_time", standby),
        "tstat_0830_c": last(TSTAT_SEL, 30),
        "target_0830_c": last(TARGET_SEL, 30),
        "amb_0830_c": last(AMB_SEL, 30),
        "frozen_0830": frozen(30),
    }


def event_queries() -> dict[str, str]:
    """Minutes that mark an event, on heat pump minutes only; fetched for the season in one request."""
    return {
        # The minute the outdoor unit is back over 1.2 kW after 2-10 minutes below it, above standby
        # for the 10 minutes before (so not a restart after an off cycle). Inference, see above.
        "defrost_end": (f"({p98()} >= {RUN_W}) and ({max98(8, 3)} >= {RUN_W}) and ({max98(1, 1)} < {RUN_W}) "
                        f"and ({min98(9, 1)} > {STANDBY_W}) and {ON_HP}"),
        # 15 minutes after a drop from a run, the outdoor unit still between standby and 1 kW.
        "long_dip": f"({max98(15)} < {ICED_W}) and ({min98(15)} > {STANDBY_W}) and ({p98(16)} >= {RUN_W}) and {ON_HP}",
        # The 21st minute (and later) of standby during a heating call, the furnace off.
        "standby_call": (f"({max98(STANDBY_STOP_MIN)} < {STANDBY_W}) and "
                         f"(min(min_over_time({HEAT_SEL}[{STANDBY_STOP_MIN}m])) == 1) and {ON_HP} and "
                         f"(max(max_over_time({E7}[{STANDBY_STOP_MIN}m])) < {LOW_W}) unless {frozen()}"),
    }


def tagged(queries: dict[str, str]) -> str:
    return " or ".join(f'label_replace({e}, "q", "{n}", "", "")' for n, e in queries.items())


def packed(queries: dict[str, str]) -> list[dict[str, str]]:
    """The quantities in groups whose tagged expression stays under URL_CHARS."""
    groups: list[dict[str, str]] = [{}]
    for n, e in queries.items():
        if groups[-1] and len(tagged(groups[-1] | {n: e})) > URL_CHARS:
            groups.append({})
        groups[-1][n] = e
    return groups


# ---- fetching ----------------------------------------------------------------------------------

def eval_time(d: dt.date) -> int:
    """The night of evening d is read at 08:59:59 the next morning, Chicago time."""
    return int(dt.datetime.combine(d + dt.timedelta(days=1), dt.time(8, 59, 59), TZ).timestamp())


def night_of(ts: int) -> dt.date:
    """The evening date of the night holding minute ts (21:00-08:59 local); daytime minutes too."""
    return (dt.datetime.fromtimestamp(ts, TZ) - dt.timedelta(hours=9)).date()


def nights_until(end: int) -> list[dt.date]:
    out, d = [], FIRST_NIGHT
    while d <= LAST_NIGHT and eval_time(d) <= end:
        out.append(d)
        d += dt.timedelta(days=1)
    return out


def segments(nights: list[dt.date]) -> list[list[dt.date]]:
    """Runs of nights read exactly a day apart (a DST change breaks one), at most NIGHTS_PER_QUERY each."""
    segs: list[list[dt.date]] = []
    for d in nights:
        if (segs and len(segs[-1]) < NIGHTS_PER_QUERY
                and eval_time(d) - eval_time(segs[-1][-1]) == 86400):
            segs[-1].append(d)
        else:
            segs.append([d])
    return segs


def _result(base: str, get, path: str, params: dict) -> list[dict]:
    body = get(f"{base}/api/v1/{path}?{urllib.parse.urlencode(params)}")
    if body.get("status") != "success":
        raise RuntimeError(f"query failed: {body.get('errorType')}: {body.get('error')}")
    return body["data"]["result"]


def fetch(base: str, get, nights: list[dt.date]) -> tuple[dict, dict]:
    """(raw per night: {date: {quantity: value}}, events: {name: [minute ts]}) from Prometheus."""
    by_ts = {eval_time(d): d.isoformat() for d in nights}
    raw: dict[str, dict] = {d.isoformat(): {} for d in nights}
    for seg in segments(nights):
        for group in packed(night_queries()):
            for s in _result(base, get, "query_range", {"query": tagged(group), "start": eval_time(seg[0]),
                                                        "end": eval_time(seg[-1]), "step": 86400}):
                for ts, v in s["values"]:
                    d = by_ts.get(int(float(ts)))
                    if d:
                        raw[d][s["metric"]["q"]] = float(v)
    events: dict[str, list[int]] = {n: [] for n in event_queries()}
    if nights:
        t_end = eval_time(nights[-1])
        span = t_end - (eval_time(nights[0]) - 43200)
        for s in _result(base, get, "query", {"query": f"({tagged(event_queries())})[{span}s:1m]", "time": t_end}):
            events[s["metric"]["q"]] += sorted(int(float(ts)) for ts, _ in s["values"])
    return raw, events


# ---- per night ---------------------------------------------------------------------------------

def fahrenheit(c: float) -> float:
    return c * 9 / 5 + 32


def night_record(d: str, q: dict, events: dict[str, list[int]]) -> dict:
    """One night's figures from its raw quantities and the season's event minutes."""
    day = dt.date.fromisoformat(d)
    t_end = eval_time(day)
    mine = {n: [t for t in ts if t_end - 43200 < t <= t_end] for n, ts in events.items()}
    hp_min, gas_min, end_c = q.get("lock_hp_min", 0), q.get("lock_gas_min", 0), q.get("lock_end_c")
    stopped_at = None
    if hp_min >= 15 and end_c is not None and LOCK_NORMAL_C[0] <= end_c <= LOCK_NORMAL_C[1]:
        kind = "comfort_stopped"
        if q.get("lock_hp_last") is not None:
            stopped_at = int(q["lock_hp_last"]) + 60
    elif hp_min >= NIGHT_MIN / 2:
        kind = "heat_pump"
    elif gas_min >= NIGHT_MIN / 2:
        kind = "gas"
    else:
        kind = "unknown"
    pm = q.get("power_min", 0)
    scale = NIGHT_MIN / pm if pm else 0.0
    burner = {s: max(0.0, q.get(f"{s}_min", 0) - CYCLE_TAIL_MIN * q.get(f"{s}_ends", 0)) * scale
              for s in ("low", "high")}
    furnace_kwh = sum(burner[s] * FURNACE_KWH_MIN[s] for s in burner)
    kwh = (q.get("outdoor_wmin", 0) + q.get("blower_wmin", 0)) / 60000 * scale
    live_n, amb_n = q.get("live_min", 0), q.get("amb_min", 0)
    offset = q.get("room_minus_amb_c")
    calibrated = amb_n == 0 or offset is not None
    n = live_n + amb_n
    dfh = None
    if n:
        sum_c = q.get("live_sum_c", 0) + q.get("amb_sum_c", 0) + (offset or 0.0) * amb_n
        dfh = sum_c / n * 1.8 * NIGHT_MIN / 60
    indoor = q.get("tstat_0830_c")
    if "frozen_0830" in q:
        a, o = q.get("amb_0830_c"), q.get("tstat_minus_amb_c")
        indoor = a + o if a is not None and o is not None else None
    gap = None
    if indoor is not None and q.get("target_0830_c") is not None:
        gap = (indoor - q["target_0830_c"]) * 1.8
    defrosts = mine.get("defrost_end", [])
    burst = next((defrosts[i] for i in range(len(defrosts) - DEFROSTS_PER_HOUR + 1)
                  if defrosts[i + DEFROSTS_PER_HOUR - 1] - defrosts[i] <= 3600), None)
    stretches: list[dict] = []
    for t in mine.get("standby_call", []):
        if stretches and t - stretches[-1]["last"] == 60:
            stretches[-1]["last"] = t
        else:
            stretches.append({"first": t, "last": t})
    standby = [{"start": s["first"] - STANDBY_STOP_MIN * 60,
                "minutes": (s["last"] - s["first"]) // 60 + STANDBY_STOP_MIN + 1} for s in stretches]
    out_min = q.get("outdoor_min", 0)
    return {
        "night": d, "kind": kind, "stopped_at": stopped_at,
        "outdoor_f": None if q.get("outdoor_c") is None else round(fahrenheit(q["outdoor_c"]), 1),
        "deg_f_hours": None if dfh is None else round(dfh, 1),
        "kwh": round(kwh, 2), "furnace_low_min": round(burner["low"], 1), "furnace_high_min": round(burner["high"], 1),
        "furnace_kwh": round(furnace_kwh, 2),
        "defrosts": len(defrosts), "defrost_burst_at": burst,
        "long_dips": [t - 15 * 60 for t in mine.get("long_dip", [])],
        "standby_call_min": int(q.get("standby_min", 0)), "standby_stretches": standby,
        "gap_0830_f": None if gap is None else round(gap, 1),
        "held_0830": None if gap is None else abs(gap) <= HOLD_F,
        "frozen_min": int(amb_n), "ambient_offset_f": None if offset is None else round(offset * 1.8, 1),
        "minutes": {"power": int(pm), "indoor": int(n), "outdoor": int(out_min)},
        "complete": (pm >= POWER_COMPLETE * NIGHT_MIN and n >= TEMP_COMPLETE * NIGHT_MIN
                     and out_min >= TEMP_COMPLETE * NIGHT_MIN and calibrated and q.get("outdoor_c") is not None),
        "calibrated": calibrated,
    }


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
    if n["defrost_burst_at"]:
        why.append(f"{DEFROSTS_PER_HOUR} defrosts within an hour from {hm(n['defrost_burst_at'])}")
    if n["long_dips"]:
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
    off = [n for n in week if n["kind"] == "unknown"]
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
    short = [n for n in nights if not n["complete"] and n["kind"] != "unknown" and n["calibrated"]]
    if short:
        lines.append("- Left out of the estimates for missing data: " + ", ".join(name(n["night"]) for n in short) + ".")
    return lines


def compute(raw: dict, events: dict, start: int, end: int) -> dict:
    nights = [night_record(d, raw[d], events) for d in sorted(raw)]
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


def in_season(end: int) -> bool:
    return FIRST_NIGHT <= dt.datetime.fromtimestamp(end, TZ).date() <= SHOW_UNTIL


def section(start: int, end: int, base: str, get) -> dict | None:
    """The experiment section for a report window, None outside 2026-11-12..2027-04-07."""
    if not in_season(end):
        return None
    try:
        raw, events = fetch(base, get, nights_until(end))
        return compute(raw, events, start, end)
    except Exception as e:  # noqa: BLE001 - the rest of the mail still goes out, with this line in it
        exp = {"error": f"{type(e).__name__}: {e}"}
        exp["lines"] = text_lines(exp)
        return exp
