#!/usr/bin/env python3
"""d01 home-assistant: the dry-air advice (packages/dry_air.yaml).

    python3 scripts/tests/test_home_assistant_dry_air.py

1. home-assistant.sh up and verify against stubs (as test_home_assistant_hvac.py): up installs
   packages/dry_air.yaml as an exact copy (600); verify passes, then fails once it is edited.
2. With docker and the image pinned in compose.yml present (docker pull it first), in that image
   with no network: Home Assistant's check_config accepts the installed config, and every template
   in the package renders as intended in Home Assistant's own template engine (a bare
   HomeAssistant object with stand-in states: the d01 sensors in °F, and in °C). That covers the
   unit conversion, the indoor dew point, the RH outdoor air reaches indoors, "outdoor air can dry
   the house" and its reasons (wet outside: rain rate, last rain within 60 min, outdoor RH 95%; and
   that every render calls now(), so Home Assistant renders it again each minute), the humidity
   thresholds, the notice gates on the "last sent"
   helpers, the messages and the readings every notice carries (°F only); and the automations' shape
   (triggers, 08:00-21:00 window, helper set before the send).
3. In that image, one boot of Home Assistant with the package alone (a stand-in notify action, the
   event loop's clock moved on for the holds): station readings out for 15 minutes within 3 hours
   of an air notice send one stop notice, and not before; a last rain that turns 60 minutes old at
   the next whole minute clears "wet outside" then, with no state change (a real wait of up to a
   minute).
   Without docker and the image, 2 and 3 say skip.
Nothing reaches a host or Home Assistant.
"""
from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_home_assistant_hvac import APP, IMAGE, Stage, image_present, in_image, mode  # noqa: E402

PACKAGE = "packages/dry_air.yaml"


class UpAndVerify(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.s = Stage(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def test_up_installs_and_verify_compares_the_package(self):
        r = self.s.run("up")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.s.config / PACKAGE).read_bytes(), (APP / PACKAGE).read_bytes())
        self.assertEqual(mode(self.s.config / PACKAGE), "600")
        r = self.s.run("verify")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("packages/ matches the repo", r.stdout)
        with open(self.s.config / PACKAGE, "a") as f:
            f.write("# edited on the host\n")
        r = self.s.run("verify")
        self.assertEqual(r.returncode, 1)
        self.assertIn("packages/ differs from the repo", r.stdout)


TEMPLATES = r'''
import asyncio, datetime, math, re, sys, time, yaml
from homeassistant.core import HomeAssistant
from homeassistant.helpers.template import Template

TEXT = open("/config/packages/dry_air.yaml", encoding="utf-8").read()
PKG = yaml.safe_load(TEXT)
ENT = {i["default_entity_id"]: i for b in PKG["template"] for items in b.values() for i in items}
AUTO = {a["id"]: a for a in PKG["automation"]}
SCRIPT = PKG["script"]["dry_air_notice"]
HELPERS = PKG["input_datetime"]
A, B = 17.62, 243.12
def f2c(f): return (f - 32) * 5 / 9
def dew(t, rh):
    g = math.log(rh / 100) + A * t / (B + t)
    return B * g / (A - g)
def rh_in(dp_out, t_in): return min(100, 100 * math.exp(A * dp_out / (B + dp_out) - A * t_in / (B + t_in)))

T_IN, RH_IN = "sensor.downstairs_hallway_temperature", "sensor.downstairs_hallway_humidity"
T_OUT, RH_OUT, DP_OUT = "sensor.mke_temperature", "sensor.mke_humidity", "sensor.mke_dew_point"
RAIN, LAST_RAIN = "sensor.mke_precipitation_intensity", "sensor.mke_last_rain"
def ago(seconds):
    """The station's last-rain state as d01 shows it (ISO 8601 in UTC), this long before now."""
    return datetime.datetime.fromtimestamp(time.time() - seconds, datetime.timezone.utc).isoformat(timespec="seconds")
DP_IN, RHI = "sensor.indoor_dew_point", "sensor.outdoor_air_rh_indoors"
DRY, HIGH, LOW = ("binary_sensor.outdoor_air_can_dry_the_house", "binary_sensor.indoor_humidity_high",
                  "binary_sensor.indoor_humidity_dry_enough")
AIR_H, STOP_H, ON_H, OFF_H = (f"input_datetime.dry_air_last_{n}_notice"
                              for n in ("air", "stop", "dehumidifier_on", "dehumidifier_off"))
# The 2026-11-04 22:32Z readings as d01 shows them (°F; asyla backlog item, Findings).
BASE = {T_IN: ("74.5", "°F"), RH_IN: ("72", "%"), T_OUT: ("54.0", "°F"), RH_OUT: ("83", "%"),
        DP_OUT: ("48.9", "°F"), RAIN: ("0.0", "in/h"), LAST_RAIN: (ago(8 * 3600), None)}

cases = []
def check(name, got, want): cases.append((name, got, want))

async def main():
    hass = HomeAssistant("/config")
    def r(text, **v):
        return Template(text, hass).async_render(v, parse_result=False).strip()
    def put(states):
        for e in list(hass.states.async_entity_ids()):
            hass.states.async_remove(e)
        for e, (s, u) in states.items():
            hass.states.async_set(e, s, {"unit_of_measurement": u} if u else {})
    def derived(states):
        """BASE-style states plus the two template sensors as Home Assistant would compute them."""
        put(states)
        out = dict(states)
        out[DP_IN] = (r(ENT[DP_IN]["state"]), "°C")
        out[RHI] = (r(ENT[RHI]["state"]), "%")
        put(out)
        return out
    def ev(ent, keys, states):
        put(states)
        return tuple(r(ENT[ent][k]) if k != "reasons" else r(ENT[ent]["attributes"]["reasons"]) for k in keys)

    # --- shape -----------------------------------------------------------------------------------
    texts = [i[k] for i in ENT.values() for k in ("state", "availability") if k in i]
    texts += [ENT[DRY]["attributes"]["reasons"]]
    # Folded scalars: each template is one line. The macro, wherever used, is one text.
    macros = [m for t in texts for m in re.findall(r"\{%- macro c\(e\) -%\}.*?\{%- endmacro -%\}", t)]
    check("the unit macro c: one text, in all templates but the two RH-only ones",
          (len(set(macros)), len(macros)), (1, len(texts) - 4))
    pre = [t.rsplit("{{", 1)[0] for t in (ENT[DRY]["state"], ENT[DRY]["availability"], ENT[DRY]["attributes"]["reasons"])]
    check("can-dry state, availability and reasons share one preamble",
          (pre[0] == pre[1] == pre[2], "set r = " in pre[0]), (True, True))
    check("template ids", sorted(ENT), sorted([DP_IN, RHI, DRY, HIGH, LOW]))
    check("unique ids", all(i["unique_id"].startswith("asyla_dry_air_") for i in ENT.values()), True)
    check("indoor dew point: °C, temperature class",
          (ENT[DP_IN]["unit_of_measurement"], ENT[DP_IN]["device_class"]), ("°C", "temperature"))
    check("delays", [ENT[e]["delay_on"] for e in (DRY, HIGH, LOW)], [{"minutes": 30}, {"hours": 6}, {"hours": 3}])
    check("off delays: can dry 15 min, the RH sensors none",
          [ENT[e].get("delay_off") for e in (DRY, HIGH, LOW)], [{"minutes": 15}, None, None])
    check("helpers", sorted(f"input_datetime.{k}" for k in HELPERS), sorted([AIR_H, STOP_H, ON_H, OFF_H]))
    check("helpers: date and time, no initial (restored at start)",
          {(h.get("has_date"), h.get("has_time"), "initial" in h) for h in HELPERS.values()}, {(True, True, False)})
    inputs = set(BASE) | set(ENT) | {f"input_datetime.{k}" for k in HELPERS} | {"script.dry_air_notice",
                                                                               "notify.hvac_report"}
    inputs |= {"input_datetime.set_datetime", "notify.send_message"}  # actions, not entities
    refs = set(re.findall(r"\b(?:sensor|binary_sensor|input_datetime|script|notify)\.[a-z0-9_]+", TEXT))
    check("every entity named is an input or made here", sorted(refs - inputs), [])

    # --- indoor dew point --------------------------------------------------------------------------
    put(BASE)
    check("dew point from °F: Magnus", float(r(ENT[DP_IN]["state"])), round(dew(f2c(74.5), 72), 1))
    check("dew point available", r(ENT[DP_IN]["availability"]), "True")
    put(BASE | {T_IN: ("23.6", "°C")})
    check("dew point from °C", float(r(ENT[DP_IN]["state"])), round(dew(23.6, 72), 1))
    for name, over in (("temperature unavailable", {T_IN: ("unavailable", "°F")}),
                       ("unknown temperature unit", {T_IN: ("296.8", "K")}),
                       ("RH 0", {RH_IN: ("0", "%")}), ("RH missing", {RH_IN: ("unknown", "%")})):
        put(BASE | over)
        check(f"dew point: {name}", (r(ENT[DP_IN]["availability"]), r(ENT[DP_IN]["state"])), ("False", "None"))

    # --- RH outdoor air reaches indoors ------------------------------------------------------------
    put(BASE | {T_IN: ("23.6", "°C"), DP_OUT: ("9.4", "°C")})
    check("RH indoors: 9.4 °C dew point at 23.6 °C indoors is about 41%", r(ENT[RHI]["state"]), "41")
    put(BASE)
    check("RH indoors from °F", r(ENT[RHI]["state"]), str(round(rh_in(f2c(48.9), f2c(74.5)))))
    put(BASE | {T_IN: ("20", "°C"), DP_OUT: ("25", "°C")})
    check("RH indoors at most 100", r(ENT[RHI]["state"]), "100")
    put(BASE | {DP_OUT: ("unavailable", "°F")})
    check("RH indoors: dew point unavailable", (r(ENT[RHI]["availability"]), r(ENT[RHI]["state"])), ("False", "None"))

    # --- outdoor air can dry the house --------------------------------------------------------------
    keys = ("availability", "state", "reasons")
    base = derived(BASE)
    check("11-04 reading: can dry", ev(DRY, keys, base), ("True", "True", ""))
    dp_f = "%.1f" % (float(base[DP_IN][0]) * 9 / 5 + 32)
    check("indoor dew point shown in °F (as on d01): same", ev(DRY, keys, base | {DP_IN: (dp_f, "°F")}),
          ("True", "True", ""))
    check("11-04 indoor dew point: 64.9 °F", dp_f, "64.9")
    check("humid: outdoor dew point 66 °F, over the indoor 64.9 °F",
          ev(DRY, keys, base | {DP_OUT: ("66.0", "°F")}), ("True", "False", "humid"))
    near = "house nearly as dry as outdoors"
    check("near: outdoor dew point 62 °F, under the indoor 64.9 °F by less than 5.4 °F",
          ev(DRY, keys, base | {DP_OUT: ("62.0", "°F")}), ("True", "False", near))
    wet = "wet outside"
    check("wet: rain rate 0.02 in/h", ev(DRY, keys, base | {RAIN: ("0.02", "in/h")}), ("True", "False", wet))
    no_last_rain = {k: v for k, v in base.items() if k != LAST_RAIN}
    for name, states, want in (
            ("wet: outdoor RH 95%", base | {RH_OUT: ("95", "%")}, wet),
            ("outdoor RH 94.9%: not wet", base | {RH_OUT: ("94.9", "%")}, ""),
            ("11-04 mist (0 in/h, 88% RH, last rain 8 h ago): not wet, the stated limit",
             base | {RH_OUT: ("88", "%")}, ""),
            ("wet: last rain 1 min ago, rain rate back to 0", base | {LAST_RAIN: (ago(60), None)}, wet),
            ("wet: last rain 59 min ago", base | {LAST_RAIN: (ago(59 * 60), None)}, wet),
            ("last rain 61 min ago: not wet", base | {LAST_RAIN: (ago(61 * 60), None)}, ""),
            ("wet: last rain 2 min ahead (station clock ahead)", base | {LAST_RAIN: (ago(-120), None)}, wet),
            ("last rain unknown: not wet, still available", base | {LAST_RAIN: ("unknown", None)}, ""),
            ("last rain unavailable: not wet, still available", base | {LAST_RAIN: ("unavailable", None)}, ""),
            ("no last-rain entity: not wet, still available", no_last_rain, ""),
            ("wet: RH 96% and last rain 10 min ago, one reason", base | {RH_OUT: ("96", "%"), LAST_RAIN: (ago(600), None)}, wet)):
        check(name, ev(DRY, keys, states), ("True", "False" if want else "True", want))
    # now() in every render (before any branch): Home Assistant then renders it again at each minute.
    for name, states in (("readings ok", base), ("wet", base | {RH_OUT: ("96", "%")}),
                         ("readings unavailable", base | {DP_OUT: ("unavailable", "°F")})):
        put(states)
        infos = [Template(x, hass).async_render_to_info() for x in
                 (ENT[DRY]["availability"], ENT[DRY]["state"], ENT[DRY]["attributes"]["reasons"])]
        check(f"can dry: availability, state and reasons re-render each minute, {name}",
              [i.has_time for i in infos], [True, True, True])
    check("can dry: tracks the outdoor RH and last-rain sensors", {RH_OUT, LAST_RAIN} <= infos[2].entities, True)
    check("too cold", ev(DRY, keys, base | {T_OUT: ("40.0", "°F"), DP_OUT: ("30.0", "°F")}),
          ("True", "False", "too cold"))
    check("warmer outside", ev(DRY, keys, base | {T_OUT: ("78.0", "°F")}), ("True", "False", "warmer outside"))
    check("humid and wet", ev(DRY, keys, base | {DP_OUT: ("66.0", "°F"), RAIN: ("0.1", "in/h")}),
          ("True", "False", "humid, wet outside"))
    check("near and wet", ev(DRY, keys, base | {DP_OUT: ("62.0", "°F"), RAIN: ("0.1", "in/h")}),
          ("True", "False", near + ", wet outside"))
    edge = {T_IN: ("22.0", "°C"), DP_IN: ("18.5", "°C"), T_OUT: ("5.0", "°C"), DP_OUT: ("15.5", "°C"), RAIN: ("0", "in/h"),
            RH_OUT: ("80", "%")}
    check("bounds: dew point 3 °C under, 5 °C outdoors", ev(DRY, keys, edge), ("True", "True", ""))
    check("bounds: as warm as indoors", ev(DRY, keys, edge | {T_OUT: ("22.0", "°C")}), ("True", "True", ""))
    check("bounds: 4.9 °C", ev(DRY, keys, edge | {T_OUT: ("4.9", "°C")}), ("True", "False", "too cold"))
    for dp, want in (("15.6", near), ("18.4", near), ("18.5", "humid"), ("18.6", "humid")):
        check(f"bounds: outdoor dew point {dp} °C against 18.5 °C indoors",
              ev(DRY, keys, edge | {DP_OUT: (dp, "°C")}), ("True", "False", want))
    for name, over in (("station dew point unavailable", {DP_OUT: ("unavailable", "°F")}),
                       ("rain unknown", {RAIN: ("unknown", "in/h")}),
                       ("outdoor RH unavailable", {RH_OUT: ("unavailable", "%")}),
                       ("indoor dew point missing", {DP_IN: ("unknown", "°C")}),
                       ("unknown unit", {T_OUT: ("285.4", "K")})):
        check(f"can dry: {name}", ev(DRY, keys, base | over), ("False", "False", "readings unavailable"))

    # --- humidity thresholds -----------------------------------------------------------------------
    for rh, hi, lo in (("72", "True", "False"), ("60", "True", "False"), ("59.9", "False", "False"),
                       ("51", "False", "False"), ("50.5", "False", "False"), ("50", "False", "True"),
                       ("45", "False", "True")):
        put(BASE | {RH_IN: (rh, "%")})
        check(f"RH {rh}%: high, dry enough", (r(ENT[HIGH]["state"]), r(ENT[LOW]["state"])), (hi, lo))
    put(BASE | {RH_IN: ("unavailable", "%")})
    check("RH unavailable: both unavailable", (r(ENT[HIGH]["availability"]), r(ENT[LOW]["availability"])),
          ("False", "False"))

    # --- automations: shape ------------------------------------------------------------------------
    plan = {"asyla_dry_air_air_the_house": (AIR_H, "airing"), "asyla_dry_air_stop_airing": (STOP_H, "airing"),
            "asyla_dry_air_dehumidifier_on": (ON_H, "dehumidifier"),
            "asyla_dry_air_dehumidifier_off": (OFF_H, "dehumidifier")}
    check("automation ids", sorted(AUTO), sorted(plan))
    for aid, (helper, thread) in plan.items():
        a = AUTO[aid]
        check(f"{aid}: single, silent", (a["mode"], a["max_exceeded"]), ("single", "silent"))
        check(f"{aid}: 08:00 trigger", {"trigger": "time", "at": "08:00:00"} in a["triggers"], True)
        check(f"{aid}: 08:00-21:00 only", a["conditions"][0], {"condition": "time", "after": "08:00:00", "before": "21:00:00"})
        s, n = a["actions"][0], a["actions"][1]
        check(f"{aid}: sets its helper, then sends",
              (len(a["actions"]), s["action"], s["target"]["entity_id"], n["action"], n["data"]["thread"]),
              (2, "input_datetime.set_datetime", helper, "script.dry_air_notice", thread))
        ts = r(s["data"]["timestamp"])
        check(f"{aid}: helper set to now (whole seconds)", ts.isdigit() and abs(int(ts) - time.time()) < 5, True)
    air = AUTO["asyla_dry_air_air_the_house"]
    check("air: re-check 3 h after the last air notice",
          {"trigger": "time", "at": {"entity_id": AIR_H, "offset": "03:00:00"}} in air["triggers"], True)
    check("air: RH trigger and condition are one test", air["triggers"][1]["value_template"],
          air["conditions"][2]["value_template"])
    check("air: re-check at start", {"trigger": "homeassistant", "event": "start"} in air["triggers"], True)
    stop = AUTO["asyla_dry_air_stop_airing"]
    check("stop: to off from any state (off is held 15 min by delay_off)", stop["triggers"][0],
          {"trigger": "state", "entity_id": DRY, "to": "off"})
    check("stop: unavailable held 15 min", stop["triggers"][1],
          {"trigger": "state", "entity_id": DRY, "to": "unavailable", "for": {"minutes": 15}})
    check("stop: three triggers", len(stop["triggers"]), 3)
    check("stop: can dry off or unavailable", stop["conditions"][1],
          {"condition": "state", "entity_id": DRY, "state": ["off", "unavailable"]})
    on = AUTO["asyla_dry_air_dehumidifier_on"]
    off = AUTO["asyla_dry_air_dehumidifier_off"]
    check("dehumidifier on: re-check 3 h after the last air notice",
          {"trigger": "time", "at": {"entity_id": AIR_H, "offset": "03:00:00"}} in on["triggers"], True)
    check("dehumidifier on: re-check at start, trigger id start",
          {"trigger": "homeassistant", "event": "start", "id": "start"} in on["triggers"], True)
    check("dehumidifier on: no other trigger ids", [t.get("id") for t in on["triggers"]].count(None),
          len(on["triggers"]) - 1)

    # --- the RH >= 55 test -------------------------------------------------------------------------
    for rh, want in (("55", "True"), ("54.9", "False"), ("unavailable", "False")):
        put({RH_IN: (rh, "%")})
        check(f"air: RH {rh}", r(air["conditions"][2]["value_template"]), want)

    # --- gates on the helpers (timestamps relative to the real clock) -------------------------------
    now = time.time()
    def gate(cond_text, **helpers):
        put({})
        for e, ago in helpers.items():
            hass.states.async_set(e, "2026-11-04 10:00:00", {"timestamp": now - ago})
        return r(cond_text)
    H = 3600
    air_gate = air["conditions"][3]["value_template"]
    check("air gate: never sent", gate(air_gate), "True")
    check("air gate: 8 h ago (also the start value: today 00:00, notices from 08:00)",
          gate(air_gate, **{AIR_H: 8 * H}), "True")
    check("air gate: 2 h 58 min ago", gate(air_gate, **{AIR_H: 3 * H - 120}), "False")
    check("air gate: 3 h ago (the +3 h trigger)", gate(air_gate, **{AIR_H: 3 * H}), "True")
    stop_gate = stop["conditions"][2]["value_template"]
    check("stop gate: air 1 h ago, no stop since", gate(stop_gate, **{AIR_H: H, STOP_H: 48 * H}), "True")
    check("stop gate: air 1 h ago, stop already sent", gate(stop_gate, **{AIR_H: H, STOP_H: H / 2}), "False")
    check("stop gate: air 3 h 1 min ago", gate(stop_gate, **{AIR_H: 3 * H + 60, STOP_H: 48 * H}), "False")
    check("stop gate: start values (equal)", gate(stop_gate, **{AIR_H: 8 * H, STOP_H: 8 * H}), "False")
    check("stop gate: never sent", gate(stop_gate), "False")
    on_air_gate = on["conditions"][3]["value_template"]
    check("dehumidifier on: the air gate is the air automation's", on_air_gate, air_gate)
    for name, h, want in (("never sent", {}, "True"), ("air 1 h ago", {AIR_H: H}, "False"),
                          ("air 2 h 58 min ago", {AIR_H: 3 * H - 120}, "False"),
                          ("air 3 h ago (the +3 h trigger)", {AIR_H: 3 * H}, "True")):
        check(f"dehumidifier on, air gate: {name}", gate(on_air_gate, **h), want)
    on_gate, off_gate = on["conditions"][4]["value_template"], off["conditions"][2]["value_template"]
    for name, h, want_on, want_off in (("never sent", {}, "True", "False"),
                                       ("start values (equal)", {ON_H: 8 * H, OFF_H: 8 * H}, "True", "False"),
                                       ("on outstanding", {ON_H: H, OFF_H: 30 * H}, "False", "True"),
                                       ("off after on", {ON_H: 30 * H, OFF_H: H}, "True", "False"),
                                       ("on sent, off never", {ON_H: H}, "False", "True")):
        check(f"dehumidifier gates: {name}", (gate(on_gate, **h), gate(off_gate, **h)), (want_on, want_off))
    # A state or time trigger's id is its index as a string; at start only a known off counts.
    for st, want, want_start in (("on", "False", "False"), ("off", "True", "True"),
                                 ("unavailable", "True", "False"), ("unknown", "True", "False")):
        put({DRY: (st, None)})
        got = tuple(r(on["conditions"][2]["value_template"], trigger={"id": i}) for i in ("1", "start"))
        check(f"dehumidifier on: can dry {st} (other trigger, start)", got, (want, want_start))
    # The live readings agree: "on" held through delay_off, or resumed, still has reasons.
    air_live = air["conditions"][4]["value_template"]
    for name, st, attrs, want in (("no reasons", "on", {"reasons": ""}, "True"),
                                  ("on in the off hold", "on", {"reasons": near}, "False"),
                                  ("on, wet now", "on", {"reasons": "wet outside"}, "False")):
        put({})
        hass.states.async_set(DRY, st, attrs)
        check(f"air: live readings, {name}", r(air_live), want)

    # --- messages ----------------------------------------------------------------------------------
    put({})
    hass.states.async_set(DRY, "off", {"reasons": "humid, wet outside"})
    stop_msg = stop["actions"][1]["data"]["message"]
    check("stop message names why", r(stop_msg),
          "Close the windows: the outdoor air no longer dries the house (humid, wet outside).")
    check("dehumidifier on message",
          r(on["actions"][1]["data"]["message"]),
          "Turn the basement dehumidifier on, set to 50%: indoor RH has been 60% or more for 6 hours and the "
          "outdoor air cannot dry the house (humid, wet outside).")
    for name, st, attrs, want in (
            ("near", "off", {"reasons": near},
             "Close the windows: the house is now about as dry as the outdoor air can make it (its dew point "
             "is within 5.4 °F of the outdoor one)."),
            ("near and wet, too cold", "off", {"reasons": near + ", wet outside, too cold"},
             "Close the windows: the house is now about as dry as the outdoor air can make it (its dew point "
             "is within 5.4 °F of the outdoor one; also wet outside, too cold)."),
            ("wet outside", "off", {"reasons": "wet outside"},
             "Close the windows: the outdoor air no longer dries the house (wet outside)."),
            ("no reasons", "off", {"reasons": ""},
             "Close the windows: the outdoor air no longer dries the house (reason unknown)."),
            ("unavailable", "unavailable", {},
             "Close the windows: the outdoor readings are unavailable, so the outdoor air cannot be counted "
             "on to dry the house."),
            ("unavailable, stale reasons", "unavailable", {"reasons": near},
             "Close the windows: the outdoor readings are unavailable, so the outdoor air cannot be counted "
             "on to dry the house.")):
        put({})
        hass.states.async_set(DRY, st, attrs)
        check(f"stop message: {name}", r(stop_msg), want)
    put({})
    check("dehumidifier on message, station down", r(on["actions"][1]["data"]["message"])[-23:],
          "(readings unavailable).")
    check("air message", r(air["actions"][1]["data"]["message"])[:78],
          "The outdoor air can dry the house. Leave the heat on. Open windows wide with a cr")

    # --- the script: readings in °F only, persistent then mail -------------------------------------
    seq = SCRIPT["sequence"]
    check("script: queued", SCRIPT["mode"], "queued")
    check("script: readings, persistent notification, then mail",
          [list(seq[0])[0], seq[1]["action"], seq[2]["action"], seq[2]["target"]["entity_id"],
           seq[2].get("continue_on_error")],
          ["variables", "persistent_notification.create", "notify.send_message", "notify.hvac_report", True])
    check("script: notification id per thread", r(seq[1]["data"]["notification_id"], thread="airing"),
          "asyla_dry_air_airing")
    check("script: same message both ways", seq[1]["data"]["message"], seq[2]["data"]["message"])
    readings = seq[0]["variables"]["readings"]
    s = derived(BASE)
    dp_c = float(s[DP_IN][0])
    want = ("Outdoors 54.0 °F, 83% RH, dew point 48.9 °F.\n"
            f"Indoors 74.5 °F, 72% RH, dew point {dp_c * 9 / 5 + 32:.1f} °F.\n"
            f"Outdoor air warmed to the indoor temperature: {s[RHI][0]}% RH.")
    check("readings, 11-04 in °F", r(readings), want)
    check("readings: no °C", "°C" in r(readings), False)
    s = derived({T_IN: ("23.6", "°C"), RH_IN: ("72", "%"), T_OUT: ("12.2", "°C"), RH_OUT: ("83", "%"),
                 DP_OUT: ("9.4", "°C"), RAIN: ("0", "mm/h")})
    check("readings, from °C sensors: shown in °F", r(readings).splitlines()[0], "Outdoors 54.0 °F, 83% RH, dew point 48.9 °F.")
    check("readings: 41%", r(readings).splitlines()[2], "Outdoor air warmed to the indoor temperature: 41% RH.")
    put(BASE | {DP_OUT: ("unavailable", "°F"), RH_OUT: ("unknown", "%")})
    check("readings: missing values", r(readings).splitlines()[0], "Outdoors 54.0 °F, RH unavailable, dew point unavailable.")
    check("script: body is message, blank line, readings",
          r(seq[1]["data"]["message"], message="Do this.", readings="R1\nR2"), "Do this.\n\nR1\nR2")

asyncio.run(main())
bad = 0
for name, got, want in cases:
    ok = got == want
    bad += not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": got {got!r}, want {want!r}"))
print(f"{len(cases)} cases, {bad} failed")
sys.exit(1 if bad else 0)
'''


@unittest.skipUnless(image_present(), f"needs docker and {IMAGE} (docker pull it)")
class InPinnedImage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        s = Stage(Path(cls._tmp.name))
        r = s.run("up")
        assert r.returncode == 0, r.stdout + r.stderr
        cls.cfg = s.config
        shutil.rmtree(cls.cfg / ".storage")

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def test_check_config_accepts_it(self):
        import re
        r = in_image(self.cfg, "-m", "homeassistant", "--script", "check_config", "-c", "/config", "--info", "all")
        out = re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr)
        self.assertEqual(r.returncode, 0, out)
        self.assertNotRegex(out, r"Incorrect config|Failed config|Invalid config|Error", out)
        for want in ("id: asyla_dry_air_air_the_house", "id: asyla_dry_air_stop_airing",
                     "id: asyla_dry_air_dehumidifier_on", "id: asyla_dry_air_dehumidifier_off",
                     "dry_air_notice:", "dry_air_last_air_notice:", "dry_air_last_dehumidifier_off_notice:",
                     "- notify.hvac_report"):
            self.assertIn(want, out)

    def test_templates(self):
        r = in_image(self.cfg, "-", stdin=TEMPLATES)
        print(r.stdout, end="")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("FAIL", r.stdout)


LIVE = r'''
import asyncio, datetime, sys, time
from homeassistant import bootstrap, runner

DRY = "binary_sensor.outdoor_air_can_dry_the_house"
AIR_H, STOP_H = "input_datetime.dry_air_last_air_notice", "input_datetime.dry_air_last_stop_notice"
# The 2026-11-04 reading in °F, as on d01: the outdoor air can dry the house.
READ = {"sensor.downstairs_hallway_temperature": ("74.5", "°F"), "sensor.downstairs_hallway_humidity": ("72", "%"),
        "sensor.mke_temperature": ("54.0", "°F"), "sensor.mke_humidity": ("83", "%"),
        "sensor.mke_dew_point": ("48.9", "°F"), "sensor.mke_precipitation_intensity": ("0", "in/h")}
bad = []
def check(name, got, want):
    bad.extend([] if got == want else [name])
    print(("ok   " if got == want else "FAIL ") + name + ("" if got == want else f": got {got!r}, want {want!r}"),
          flush=True)

async def main():
    # Timers (delay_on/off, a state trigger's for:) are loop.call_at deadlines: skip() moves the
    # loop's clock on. The wall clock, which the time window and the helper gates read, does not move.
    loop = asyncio.get_running_loop()
    real, skew = loop.time, [0.0]
    loop.time = lambda: real() + skew[0]
    async def skip(minutes):
        skew[0] += minutes * 60
        for _ in range(10):
            await asyncio.sleep(0.05)
    hass = await bootstrap.async_setup_hass(runner.RuntimeConfig(config_dir="/config", skip_pip=True))
    sent = []
    async def stand_in(call): sent.append(dict(call.data))
    hass.services.async_register("notify", "send_message", stand_in)
    await hass.async_start()
    for e, (s, u) in READ.items():
        hass.states.async_set(e, s, {"unit_of_measurement": u})
    await hass.services.async_call("input_datetime", "set_datetime",
                                   {"entity_id": AIR_H, "timestamp": int(time.time()) - 3600}, blocking=True)
    await skip(0)
    stop0 = hass.states.get(STOP_H).attributes.get("timestamp")
    check("live: an air notice 1 h ago, can dry not yet on (30 min delay_on)", hass.states.get(DRY).state != "on", True)
    hass.states.async_set("sensor.mke_dew_point", "unavailable", {"unit_of_measurement": "°F"})
    await skip(0)
    check("live: station dew point unavailable: can dry unavailable at once", hass.states.get(DRY).state,
          "unavailable")
    await skip(14)
    check("live: 14 min unavailable: no stop notice", (len(sent), hass.states.get(STOP_H).attributes.get("timestamp")),
          (0, stop0))
    await skip(2)
    check("live: 16 min unavailable: one stop notice", [(s.get("entity_id"), s.get("title")) for s in sent],
          [(["notify.hvac_report"], "Stop airing")])
    check("live: stop notice, unavailable branch", (sent[0].get("message", "") if sent else "").split("\n")[0],
          "Close the windows: the outdoor readings are unavailable, so the outdoor air cannot be counted on to "
          "dry the house.")
    check("live: stop helper set", hass.states.get(STOP_H).attributes.get("timestamp") != stop0, True)
    await skip(30)
    check("live: still one stop notice 30 min on", len(sent), 1)
    # Wet outside from the last rain runs out with the clock alone: now() makes Home Assistant
    # render the templates again at each whole minute (wall clock; a real wait, under a minute).
    hass.states.async_set("sensor.mke_dew_point", "48.9", {"unit_of_measurement": "°F"})
    if 60 - time.time() % 60 < 3:
        await asyncio.sleep(60 - time.time() % 60 + 0.5)
    m = int(time.time() // 60 * 60 + 60)  # the next whole minute, at least 3 s ahead
    last = datetime.datetime.fromtimestamp(m - 3601, datetime.timezone.utc).isoformat(timespec="seconds")
    hass.states.async_set("sensor.mke_last_rain", last)
    await skip(0)
    check("live: last rain 60 min old in under a minute: wet outside",
          hass.states.get(DRY).attributes.get("reasons"), "wet outside")
    await asyncio.sleep(max(0, m - time.time()) + 3)
    check("live: past that minute, no state change: wet outside cleared",
          hass.states.get(DRY).attributes.get("reasons"), "")
    await hass.async_stop(force=True)

asyncio.run(main())
print(f"live: {len(bad)} failed")
sys.exit(1 if bad else 0)
'''


@unittest.skipUnless(image_present(), f"needs docker and {IMAGE} (docker pull it)")
class LiveInPinnedImage(unittest.TestCase):
    """One boot of the pinned image with the package alone: readings out for 15 min send the stop notice."""

    def test_unavailable_15_min_sends_stop(self):
        import datetime
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp)
            (cfg / "packages").mkdir()
            shutil.copy(APP / PACKAGE, cfg / PACKAGE)
            # A fixed-offset zone where it is now about 14:00, inside the 08:00-21:00 window.
            n = 14 - datetime.datetime.now(datetime.timezone.utc).hour
            tz = "Etc/GMT" if n == 0 else f"Etc/GMT{-n:+d}"
            (cfg / "configuration.yaml").write_text(
                f"homeassistant:\n  time_zone: {tz}\n  packages:\n    dry_air: !include {PACKAGE}\n")
            r = in_image(cfg, "-", stdin=LIVE)
        print(r.stdout, end="")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr[-3000:])
        self.assertIn("live: 0 failed", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
