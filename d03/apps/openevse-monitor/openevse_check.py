#!/usr/bin/env python3
"""One check of the garage EV charger (OpenEVSE openevse01) from its /status: status.json and openevse.prom. Read-only (GET).

The openevse-monitor container (compose.yml) runs this every OPENEVSE_INTERVAL seconds, a fresh
process each time, so a script update from the nightly scripts task applies at the next cycle. One
GET a cycle, `http://10.0.0.87/status`, with the charger's web login (HTTP Digest: realm
"openevse", qop auth, read 2026-10-26). It never sends the charger a command.

The /status fields are those of the WiFi gateway firmware 2.9.1 (OpenEVSE/ESP8266_WiFi_v2.x
src/web_server.cpp handleStatus): `amp` in mA and `temp1..3` in tenths of a degree C (scale
factors in src/emonesp.h), a missing sensor reads `false`; `state` is the controller's EVSE state
(open_evse v5.0.1 firmware/open_evse/J1772EvseController.h): 1 A not connected, 2 B connected,
3 C charging, 4 D vent required, 5-11 errors, 254 sleeping, 255 disabled; 12-17 are errors that
later controller firmware defines (open_evse master), kept here for a controller update. `voltage` is not read:
the controller has no voltmeter (RAPI $GG voltage -1), so it is the 240 V setting.

The controller's clock battery is dead and stays dead (operator, 2026-10-26), so nothing here uses
the charger's time; every reading carries this checker's UTC.

Writes, in OPENEVSE_DATA (/data, the host's /mnt/docker/openevse-monitor):
  status.json   {"time", "checker", "ok", "problems": [{"key", "severity", "message"}], "charger"}:
                the collection point the host-maintenance monitor reads on each run ([[status]] in
                its config/maintenance.toml); "urgent" mails at once, "warn" goes to the 07:00 digest
  openevse.prom the same readings in Prometheus text format, for theOrg's trends Prometheus
                (theOrg backlog 2026-10-25-observability-asyla-openevse-charger-openevse01-into-the-trends-prometheus)
  state.json    what one cycle hands the next: last counters, confirm counts, the open outage, events
Two kinds of finding, as att-monitor's:
- a condition (not answering, the controller link down, an error state): written while it lasts,
  an urgent one only after its confirm count of cycles in a row;
- an event (a fault counter went up, an outage that ended): written for a while after it happened
  ([events] in openevse-monitor.toml), so one monitor run sees it.
WiFi module restarts are counted, not reported: it runs out of memory and restarts about every 30
minutes on its own (readings 2026-10-26), and the operator asked for no warning on them or on its
free memory. The count is in status.json (charger.wifi_restarts) and openevse.prom
(openevse_wifi_restarts_total), so a change in the pattern shows in the trends.
stage.json, written by `openevse-monitor.sh stage`, adds one urgent problem at once until it
expires: the end-to-end test of the alert path.

Login: OPENEVSE_WWW_USER, OPENEVSE_WWW_PASSWORD in the environment (build_host.py start_env sends
them from OpenBao at start). Config: openevse-monitor.toml beside this file.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import sys
import time
import tomllib
import urllib.error
import urllib.request
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

DATA = Path(os.environ.get("OPENEVSE_DATA", "/data"))
CONFIG = Path(os.environ.get("OPENEVSE_CONFIG", Path(__file__).with_name("openevse-monitor.toml")))
NAME = "EV charger (openevse01)"
EVENTS_KEPT = 50
STATES = {0: "unknown", 1: "A: not connected", 2: "B: connected, ready", 3: "C: charging",
          4: "D: vent required", 5: "diode check failed", 6: "GFCI fault", 7: "no ground",
          8: "stuck relay", 9: "GFI self-test failed", 10: "over temperature", 11: "over current",
          12: "pilot error", 13: "temperature sensor fault", 14: "relay closure fault",
          15: "PP pin shorted", 16: "PP resistor missing", 17: "EEPROM failure",
          254: "sleeping", 255: "disabled"}
ERROR_STATES = range(4, 18)
FAULTS = (("gfcicount", "gfci", "GFCI"), ("nogndcount", "no_ground", "no ground"), ("stuckcount", "stuck_relay", "stuck relay"))


class FetchError(Exception):
    pass


def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(t: dt.datetime) -> str:
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(s: str | None) -> dt.datetime | None:
    if not s:
        return None
    try:
        t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def zone(name: str | None) -> ZoneInfo | None:
    try:
        return ZoneInfo(name) if name else None
    except (ZoneInfoNotFoundError, ValueError):
        return None


def when(t: dt.datetime, tz: ZoneInfo | None) -> str:
    """'2026-10-25 23:04 CDT (04:04Z)'; UTC only when the zone is unknown."""
    if not tz:
        return iso(t)
    return f"{t.astimezone(tz):%Y-%m-%d %H:%M %Z} ({t.astimezone(dt.timezone.utc):%H:%MZ})"


def minutes(d: dt.timedelta) -> str:
    m = int(d.total_seconds() // 60)
    return f"{m} min" if m < 120 else f"{m // 60} h {m % 60} min"


def fetch(cfg: dict, user: str, password: str) -> tuple[dict, float]:
    """(/status as a dict, seconds taken). Up to cfg tries, since the charger is slow and drops
    packets (operator, 2026-10-26: "it has always been slow"). A 401 is not retried."""
    url = cfg["charger"].rstrip("/") + "/status"
    mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
    mgr.add_password(None, cfg["charger"], user, password)
    opener = urllib.request.build_opener(urllib.request.HTTPDigestAuthHandler(mgr))
    last = "no try made"
    for attempt in range(cfg["tries"]):
        if attempt:
            time.sleep(cfg["retry_pause_seconds"])
        start = time.monotonic()
        try:
            with opener.open(url, timeout=cfg["timeout_seconds"]) as r:
                body = json.loads(r.read().decode("utf-8", "replace"))
            if not isinstance(body, dict):
                raise ValueError("not a JSON object")
            return body, round(time.monotonic() - start, 2)
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise FetchError("GET /status: HTTP 401, the login was refused") from None
            last = f"GET /status: HTTP {e.code}"
        except ValueError as e:
            last = f"GET /status: not JSON ({e})"
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            last = f"GET /status: {type(e).__name__}: {getattr(e, 'reason', e)}"
    raise FetchError(f"{last} ({cfg['tries']} tries)")


def num(v) -> float | None:
    """A number from /status; None for false (a missing sensor), absent or not a number."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return v


def add_event(state: dict, key: str, kind: str, message: str, t: dt.datetime) -> None:
    state.setdefault("events", []).append({"key": key, "kind": kind, "message": message, "at": iso(t)})
    state["events"] = state["events"][-EVENTS_KEPT:]


def event_findings(cfg: dict, state: dict, t: dt.datetime) -> list:
    """Each event at its kind's severity while it is fresh: urgent for urgent_hold_minutes (one
    monitor run mails it), warn for warn_hold_hours (it reaches the 07:00 digest)."""
    ev, found = cfg["events"], []
    for e in state.get("events", []):
        sev = ev["severity"].get(e["kind"], "warn")
        hold = (dt.timedelta(minutes=ev["urgent_hold_minutes"]) if sev == "urgent"
                else dt.timedelta(hours=ev["warn_hold_hours"]))
        at = parse_time(e.get("at"))
        if at and t - at < hold:
            found.append((e["key"], sev, e["message"]))
    return found


def evaluate(cfg: dict, st: dict | None, error: str | None, state: dict, t: dt.datetime) -> tuple[list, str | None]:
    """(conditions [(key, severity, message)], down reason or None). Updates state with the events
    this reading shows (a fault counter up) and the WiFi restart count."""
    tz, found = zone(cfg.get("timezone")), []
    if st is None:
        if error and ("401" in error or "not set" in error):
            found.append(("login", "urgent", f"{NAME}: answers, but the monitor's login does not work ({error})"))
        else:
            found.append(("unreachable", "urgent", f"{NAME}: not answering from d03 ({error})"))
        return found, error
    lim = cfg["limits"]
    if st.get("rapi_connected") == 0:
        found.append(("rapi", "urgent", f"{NAME}: the WiFi module answers but has lost its link to the "
                                        f"charging controller (rapi_connected 0; RAPI {st.get('comm_success')}"
                                        f"/{st.get('comm_sent')} answered)"))
    code = num(st.get("state"))
    if code is None:
        found.append(("layout", "warn", f"{NAME}: /status has no state (a firmware change? check openevse_check.py)"))
    elif int(code) in ERROR_STATES:
        found.append((f"state:{int(code)}", "urgent", f"{NAME}: controller in error state {int(code)} "
                                                       f"({STATES.get(int(code), 'unknown code')})"))
    elif int(code) == 255:
        found.append(("state:disabled", "warn", f"{NAME}: charging is disabled at the charger (state 255)"))
    elif int(code) not in STATES or int(code) == 0:
        found.append(("state:unknown", "warn", f"{NAME}: controller state {int(code)} is unknown"))
    rssi = num(st.get("srssi"))
    if rssi is not None and rssi < lim["rssi_min_dbm"]:
        found.append(("rssi", "warn", f"{NAME}: WiFi signal {rssi:.0f} dBm, weaker than {lim['rssi_min_dbm']} dBm "
                                      f"(baseline {lim['rssi_baseline_dbm']} dBm)"))
    faults(st, state, t, tz)
    restart(st, state, t)
    return found, None


def faults(st: dict, state: dict, t: dt.datetime, tz: ZoneInfo | None) -> None:
    """An event for each fault counter that went above the highest seen. A first reading is only
    recorded, and a lower one is ignored: right after a restart the WiFi module serves 0 until it has
    read the controller's counters (no ground 2 -> 0 -> 2 around 13:26Z 2026-10-26 mailed a false
    [URGENT]). Cost: if the controller's counters were ever reset, a rise below the old high is missed."""
    last = state.setdefault("faults", {})
    for field, key, label in FAULTS:
        v = num(st.get(field))
        if v is None:
            continue
        before = last.get(field)
        if isinstance(before, (int, float)) and v <= before:
            continue
        if isinstance(before, (int, float)):
            add_event(state, f"fault:{key}:{iso(t)}", "fault",
                      f"{NAME}: {label} fault count went from {before:.0f} to {v:.0f} (seen {when(t, tz)})", t)
        last[field] = v


def restart(st: dict, state: dict, t: dt.datetime) -> None:
    """Count a WiFi module restart: its RAPI command count (comm_sent, counted from its start) went down."""
    if "wifi_restarts" not in state:
        # Restarts were warn events until 2026-10-26: they start the count and leave the events.
        old = [e for e in state.get("events", []) if e.get("kind") == "restart"]
        state["wifi_restarts"] = len(old)
        if old:
            state["events"] = [e for e in state["events"] if e.get("kind") != "restart"]
    v = num(st.get("comm_sent"))
    if v is None:
        return
    before = state.get("comm_sent")
    if isinstance(before, (int, float)) and v < before:
        state["wifi_restarts"] = state.get("wifi_restarts", 0) + 1
        state["wifi_last_restart"] = iso(t)
    state["comm_sent"] = v


def outage(cfg: dict, down: str | None, state: dict, t: dt.datetime) -> None:
    """Keep a not-answering spell in state; when it ends after confirm_down_cycles or more, an event."""
    tz, cur = zone(cfg.get("timezone")), state.get("outage")
    if down:
        if not cur:
            state["outage"] = {"start": iso(t), "cycles": 1, "why": down}
        else:
            cur["cycles"] += 1
        return
    if cur:
        start = parse_time(cur["start"]) or t
        if cur["cycles"] >= cfg["confirm_down_cycles"]:
            add_event(state, f"outage:{cur['start']}", "outage",
                      f"{NAME}: was not answering from about {when(start, tz)} to {when(t, tz)} "
                      f"({minutes(t - start)}; {cur['why']})", t)
        state.pop("outage", None)


def confirm(cfg: dict, found: list, state: dict) -> list:
    """Urgent conditions only once seen on their confirm count of cycles in a row; warnings at once.
    Not answering needs confirm_down_cycles (the charger drops packets); the rest confirm_cycles."""
    seen = state.get("seen", {})
    state["seen"] = {k: seen.get(k, 0) + 1 for k, sev, _ in found if sev == "urgent"}
    need = lambda k: cfg["confirm_down_cycles"] if k in ("unreachable", "login") else cfg["confirm_cycles"]
    return [f for f in found if f[1] != "urgent" or state["seen"][f[0]] >= need(f[0])]


def staged(t: dt.datetime) -> list:
    st = load_json(DATA / "stage.json", None)
    until = parse_time((st or {}).get("until"))
    if not until or until <= t:
        return []
    return [("staged", "urgent", f"EV charger monitor: staged test alert, {st.get('note') or 'no note'} "
                                 f"(until {iso(until)}; not a real failure)")]


def load_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def write_atomic(path: Path, body: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(body)
    tmp.replace(path)


def summary(st: dict | None, took: float | None, state: dict) -> dict:
    s = {"reachable": st is not None, "poll_seconds": took, "outage": state.get("outage"),
         "events": state.get("events", [])[-10:], "wifi_restarts": state.get("wifi_restarts", 0),
         "wifi_last_restart": state.get("wifi_last_restart")}
    if st:
        code = num(st.get("state"))
        temps = [num(st.get(f"temp{i}")) for i in (1, 2, 3)]
        s |= {"state": code, "state_name": STATES.get(int(code)) if code is not None else None,
              "amps": num(st.get("amp")) / 1000 if num(st.get("amp")) is not None else None,
              "pilot_amps": num(st.get("pilot")), "session_wh": round(num(st.get("wattsec")) / 3600, 1)
              if num(st.get("wattsec")) is not None else None, "lifetime_wh": num(st.get("watthour")),
              "temperature_c": [x / 10 if x is not None else None for x in temps],
              "faults": {key: num(st.get(field)) for field, key, _ in FAULTS},
              "rapi_connected": st.get("rapi_connected"), "rssi_dbm": num(st.get("srssi")),
              "free_heap": num(st.get("free_heap"))}
    return s


def prom(ok: bool, t: dt.datetime, st: dict | None, took: float | None, problems: list,
         state: dict | None = None) -> str:
    """Prometheus text, names as in the theOrg hand-off; one instance label, added by the scrape.
    openevse_wifi_restarts_total counts from state.json's start (a lost state.json is a counter reset)."""
    out = ["# EV charger readings (asyla-hosts d03/apps/openevse-monitor/openevse_check.py); times are the checker's",
           f"openevse_up {int(ok)}", f"openevse_check_timestamp_seconds {int(t.timestamp())}"]
    for sev in ("urgent", "warn"):
        out.append(f'openevse_problems{{severity="{sev}"}} {sum(1 for p in problems if p["severity"] == sev)}')
    if state is not None:
        out.append(f"openevse_wifi_restarts_total {state.get('wifi_restarts', 0)}")
    if took is not None:
        out.append(f"openevse_poll_seconds {took}")
    if not st:
        return "\n".join(out) + "\n"

    def put(name: str, v, scale: float = 1, labels: str = "") -> None:
        v = num(v)
        if v is not None:
            v = round(v * scale, 3)   # repr, not :g, which cuts a lifetime Wh count to 6 digits
            out.append(f"{name}{labels} {int(v) if v == int(v) else v}")

    put("openevse_state", st.get("state"))
    put("openevse_charge_current_amps", st.get("amp"), 1 / 1000)
    put("openevse_pilot_amps", st.get("pilot"))
    put("openevse_session_energy_wh", st.get("wattsec"), 1 / 3600)
    put("openevse_session_seconds", st.get("elapsed"))
    put("openevse_energy_wh_total", st.get("watthour"))
    for i in (1, 2, 3):
        put("openevse_temperature_celsius", st.get(f"temp{i}"), 1 / 10, f'{{sensor="{i}"}}')
    for field, key, _ in FAULTS:
        put("openevse_faults_total", st.get(field), 1, f'{{kind="{key}"}}')
    put("openevse_rapi_connected", st.get("rapi_connected"))
    sent, good = num(st.get("comm_sent")), num(st.get("comm_success"))
    if sent:
        put("openevse_rapi_success_ratio", (good or 0) / sent)
    put("openevse_wifi_rssi_dbm", st.get("srssi"))
    put("openevse_free_heap_bytes", st.get("free_heap"))
    return "\n".join(out) + "\n"


def check(cfg: dict, st: dict | None, error: str | None, state: dict, t: dt.datetime) -> tuple[list, str | None]:
    """One cycle on a reading (or a fetch error): (findings, down reason or None); updates state."""
    found, down = evaluate(cfg, st, error, state, t)
    found = confirm(cfg, found, state)
    outage(cfg, down, state, t)
    return found + event_findings(cfg, state, t) + staged(t), down


def main() -> int:
    with open(CONFIG, "rb") as f:
        cfg = tomllib.load(f)
    t = now()
    state = load_json(DATA / "state.json", {})
    user, password = os.environ.get("OPENEVSE_WWW_USER", ""), os.environ.get("OPENEVSE_WWW_PASSWORD", "")
    st, error, took = None, None, None
    if not user or not password:
        error = "OPENEVSE_WWW_USER or OPENEVSE_WWW_PASSWORD not set in the container"
    else:
        try:
            st, took = fetch(cfg, user, password)
        except FetchError as e:
            error = str(e)
    found, down = check(cfg, st, error, state, t)
    ok = st is not None
    problems = [{"key": k, "severity": s, "message": m} for k, s, m in found]
    write_atomic(DATA / "state.json", json.dumps(state, indent=1, sort_keys=True))
    write_atomic(DATA / "openevse.prom", prom(ok, t, st, took, problems, state))
    s = summary(st, took, state)
    write_atomic(DATA / "status.json", json.dumps(
        {"time": iso(t), "checker": "openevse-monitor", "ok": ok, "problems": problems, "charger": s},
        indent=1, sort_keys=True))
    print(f"{iso(t)} ok={ok}"
          + (f" state={s['state']} ({s['state_name']}) amps={s['amps']} rssi={s['rssi_dbm']} heap={s['free_heap']}"
             f" poll={took}s" if st else f" ({error})")
          + "".join(f"\n  [{p['severity']}] {p['message']}" for p in problems), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
