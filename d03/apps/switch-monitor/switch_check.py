#!/usr/bin/env python3
"""One check of the switches through the snmp_exporter beside it: status.json for host-maintenance. Read-only.

The switch-monitor container (compose.yml) runs this every SWITCH_INTERVAL seconds, a fresh process
each time, so a script update from the nightly scripts task applies at the next cycle. One scrape a
switch a cycle from the snmp-exporter container (`/snmp?target=...&module=...&auth=asyla_v3`), which
walks the switch over SNMPv3 (read-only user); for a MikroTik, one GET a day of MikroTik's release
feed for its channel. The exporter is also what theOrg's Prometheus scrapes, once it can reach d03.

Writes, in SWITCH_DATA (/data, the host's /mnt/docker/switch-monitor):
  status.json  {"time", "checker", "ok", "problems": [{"key", "severity", "message"}], "switches"}:
               the collection point the host-maintenance monitor reads on each run ([[status]] in
               its config/maintenance.toml); "urgent" mails at once, "warn" goes to the 07:00 digest
  state.json   what one cycle hands the next: consecutive sightings, the last counters and uptime
               of each switch, warnings held for hold_hours, release first-seen times and the feed
An urgent finding is written only after confirm_cycles cycles in a row. stage.json, written by
`switch-monitor.sh stage`, adds one urgent problem at once until it expires: the end-to-end test.

No secret passes through here: the SNMPv3 passwords are the exporter's (snmp/auth.yml).
Config: switch-monitor.toml beside this file.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DATA = Path(os.environ.get("SWITCH_DATA", "/data"))
CONFIG = Path(os.environ.get("SWITCH_CONFIG", Path(__file__).with_name("switch-monitor.toml")))
EXPORTER_FAILS_URGENT = 3   # cycles in a row with the exporter itself not answering
UP = 1                      # IF-MIB ifAdminStatus / ifOperStatus up(1)
LAST_CHANGE_JITTER = 500    # ticks (5 s): an Aruba re-reads a steady ifLastChange 100 ticks apart
GAUGE_UNITS = {1: "temp", 2: "fan", 6: "state"}   # mtxrGaugeUnit; dV, dA, dW are not watched
ARUBA_ACTIVE = 1               # WLSX-SYSTEMEXT-MIB ArubaActiveState: 1 active, 2 inactive
ARUBA_POE_HARDWARE_ERROR = 6   # WLSX-POE-MIB wlsxPsePortStatus offHardwareError
SAMPLE = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+(\S+)")
LABEL = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')


class FetchError(Exception):
    pass


def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(t: dt.datetime) -> str:
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse(s: str | None) -> dt.datetime | None:
    if not s:
        return None
    try:
        t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def load_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)


def fetch(url: str, timeout: int = 120) -> str:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        # snmp_exporter answers 500 with the SNMP error as text (no secret in it): its first line.
        body = e.read().decode("utf-8", "replace").strip().splitlines()
        raise FetchError(f"HTTP {e.code}" + (f": {body[0][:200]}" if body else "")) from None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise FetchError(f"{type(e).__name__}: {getattr(e, 'reason', e)}") from None


def answers(url: str) -> bool:
    try:
        fetch(url, timeout=10)
    except FetchError:
        return False
    return True


def samples(text: str) -> list:
    """[(name, {label: value}, float)] from Prometheus text format; comments and NaN skipped."""
    out = []
    for line in text.splitlines():
        m = SAMPLE.match(line)
        if not m:
            continue
        try:
            v = float(m.group(3))
        except ValueError:
            continue
        if v != v:
            continue
        labels = {k: unescape(val) for k, val in LABEL.findall(m.group(2) or "")}
        out.append((m.group(1), labels, v))
    return out


def unescape(v: str) -> str:
    """A label value as Prometheus escapes it: backslash, double quote and newline only."""
    return re.sub(r"\\(.)", lambda m: "\n" if m.group(1) == "n" else m.group(1), v)


def by_name(rows: list, name: str) -> list:
    return [(lab, v) for n, lab, v in rows if n == name]


def version_tuple(s: str | None) -> tuple:
    m = re.match(r"\s*(\d+(?:\.\d+)*)", s or "")
    return tuple(int(x) for x in m.group(1).split(".")) if m else ()


def ports(rows: list) -> dict:
    """{ifName: {admin, oper, errors, discards, last_change, downs}} from IF-MIB (+ MikroTik link-downs)."""
    names = {lab.get("ifIndex"): lab.get("ifName") or lab.get("ifDescr") for lab, _ in by_name(rows, "ifOperStatus")}
    out = {n: {} for n in names.values() if n}

    def put(metric, field, add=False):
        for lab, v in by_name(rows, metric):
            n = names.get(lab.get("ifIndex"))
            if n:
                out[n][field] = out[n].get(field, 0) + v if add else v
    put("ifAdminStatus", "admin")
    put("ifOperStatus", "oper")
    put("ifLastChange", "last_change")
    for m in ("ifInErrors", "ifOutErrors"):
        put(m, "errors", add=True)
    for m in ("ifInDiscards", "ifOutDiscards"):
        put(m, "discards", add=True)
    for lab, v in by_name(rows, "mtxrInterfaceStatsLinkDowns"):
        if lab.get("ifName") in out:
            out[lab["ifName"]]["downs"] = v
    return out


def evaluate(cfg: dict, name: str, scfg: dict, rows: list, prev: dict, t: dt.datetime, release: str | None):
    """(urgent/plain findings [(key, severity, message)], counter warnings to hold, summary, new prev)."""
    found, held, label = [], [], scfg.get("ports") or {}
    up = by_name(rows, "sysUpTime")
    uptime = up[0][1] / 100 if up else None
    if uptime is None:
        found.append((f"{name}:no-uptime", "urgent", f"{name}: SNMP answered without sysUpTime"))
    elif uptime < cfg["reboot_report_hours"] * 3600:
        found.append((f"{name}:restarted", "warn",
                      f"{name}: restarted at {iso(t - dt.timedelta(seconds=uptime))} (SNMP uptime {uptime / 3600:.1f} h)"))
    pts = ports(rows)
    prev_t, prev_ports = parse(prev.get("time")), prev.get("ports") or {}
    # Counters restart with the switch: no rates across a restart, only a new baseline.
    same_boot = prev_t and uptime is not None and prev.get("uptime") is not None and uptime > prev["uptime"]
    hours = (t - prev_t).total_seconds() / 3600 if same_boot else 0
    for p, what in label.items():
        st = pts.get(p)
        if st is None:
            found.append((f"{name}:port:{p}:missing", "urgent", f"{name}: port {p} ({what}) is not listed"))
        elif st.get("admin") == UP and st.get("oper") != UP:
            found.append((f"{name}:port:{p}:down", "urgent", f"{name}: port {p} ({what}) is down"))
    for p, st in pts.items():
        was = prev_ports.get(p) or {}
        if not hours or not was:
            continue
        what = f"{p} ({label[p]})" if p in label else p
        for field, limit, words in (("errors", cfg["errors_per_hour"], "errors"),
                                    ("discards", cfg["discards_per_hour"], "discards")):
            if field == "discards" and p not in label:
                continue   # edge ports drop on purpose (a sleeping PC): watched ports only
            d = st.get(field, 0) - was.get(field, 0)
            if d > 0 and d / hours > limit:
                held.append((f"{name}:port:{p}:{field}", "warn",
                             f"{name}: port {what}: {d:.0f} {words} in {hours * 60:.0f} min "
                             f"(over {limit}/h), last seen {iso(t)}"))
        if p in label:
            downs = st.get("downs", 0) - was.get("downs", 0) if "downs" in st and "downs" in was else 0
            lc, was_lc = st.get("last_change"), was.get("last_change")
            moved = ("downs" not in st and lc is not None and was_lc is not None
                     and abs(lc - was_lc) > LAST_CHANGE_JITTER)
            if downs > 0 or moved:
                held.append((f"{name}:port:{p}:flap", "warn",
                             f"{name}: port {what} " + (f"went down {downs:.0f} time(s)" if downs else "changed state")
                             + f" between {iso(prev_t)} and {iso(t)}"))
    found += health(cfg, name, rows, label)
    found += aruba(cfg, name, rows)
    found += firmware(cfg, name, scfg, rows, prev, t, release)
    watched_up = sum(1 for p in label if (pts.get(p) or {}).get("oper") == UP)
    descr = next((lab.get("sysDescr") for lab, _ in by_name(rows, "sysDescr")), None)
    m = re.search(r"Version (\S+)", descr or "")
    summary = {"reachable": True, "uptime_hours": round(uptime / 3600, 1) if uptime is not None else None,
               "ports": len(pts), "watched_up": f"{watched_up}/{len(label)}",
               "version": next((lab.get("mtxrLicVersion") for lab, _ in by_name(rows, "mtxrLicVersion")),
                               m.group(1) if m else None)}
    new_prev = {"time": iso(t), "uptime": uptime,
                "ports": {p: {k: st[k] for k in ("errors", "discards", "downs", "last_change") if k in st}
                          for p, st in pts.items()},
                "release_seen": prev.get("release_seen") or {}}   # firmware() keeps it current
    return found, held, summary, new_prev


def gauge_kind(g: str, unit: float | None) -> str | None:
    """A MikroTik gauge by its mtxrGaugeUnit (MIKROTIK-MIB: 1 celsius, 2 rpm, 6 status), else by its name."""
    if unit is not None:
        return GAUGE_UNITS.get(int(unit))
    if "temperature" in g:
        return "temp"
    if "fan" in g and g.endswith("speed"):
        return "fan"
    return "state" if g.endswith("-state") else None


def health(cfg: dict, name: str, rows: list, label: dict) -> list:
    """MikroTik health gauges (temperature in C, fan speed in RPM, a state ok = state_ok_value) and optics."""
    found = []
    units = {lab.get("mtxrGaugeName"): v for lab, v in by_name(rows, "mtxrGaugeUnit")}
    for lab, v in by_name(rows, "mtxrGaugeValue"):
        g = lab.get("mtxrGaugeName") or "?"
        kind = gauge_kind(g, units.get(g))
        if kind == "temp":
            if v >= cfg["temp_urgent_c"]:
                found.append((f"{name}:health:{g}", "urgent", f"{name}: {g} {v:.0f} C (limit {cfg['temp_urgent_c']} C)"))
            elif v >= cfg["temp_warn_c"]:
                found.append((f"{name}:health:{g}", "warn", f"{name}: {g} {v:.0f} C (over {cfg['temp_warn_c']} C)"))
        elif kind == "fan" and v < cfg["fan_min_rpm"]:
            found.append((f"{name}:health:{g}", "urgent", f"{name}: {g} {v:.0f} RPM (under {cfg['fan_min_rpm']})"))
        elif kind == "state" and v != cfg["state_ok_value"]:
            found.append((f"{name}:health:{g}", "urgent", f"{name}: {g} is not ok (value {v:.0f})"))
    scale = cfg["optic_power_scale"]
    for metric, field in (("mtxrOpticalRxPower", "rx"), ("mtxrOpticalTxPower", "tx")):
        limit = cfg[f"optic_{field}_min_dbm"]
        for lab, v in by_name(rows, metric):
            p = lab.get("mtxrOpticalName") or "?"
            if p in label and v * scale < limit:   # an empty cage or a copper module reads nothing useful
                found.append((f"{name}:optic:{p}:{field}", "warn",
                              f"{name}: {p} ({label[p]}) optic {field} power {v * scale:.1f} dBm (under {limit} dBm)"))
    for lab, v in by_name(rows, "mtxrOpticalTemperature"):
        p = lab.get("mtxrOpticalName") or "?"
        if p in label and v > cfg["optic_max_c"]:
            found.append((f"{name}:optic:{p}:temp", "warn", f"{name}: {p} optic at {v:.0f} C (over {cfg['optic_max_c']} C)"))
    for lab, v in by_name(rows, "mtxrOpticalTxFault"):
        p = lab.get("mtxrOpticalName") or "?"
        if p in label and v == 1:
            found.append((f"{name}:optic:{p}:txfault", "warn", f"{name}: {p} ({label[p]}) optic reports a transmit fault"))
    return found


def aruba(cfg: dict, name: str, rows: list) -> list:
    """Aruba S2500 (snmp/aruba.yml): fans and power supplies active, the internal temperature (C, the
    exporter takes it from the switch's text), each PoE slot's draw against its budget, and a PoE port
    in hardware error."""
    found = []
    for metric, index, what in (("sysExtFanStatus", "sysExtFanIndex", "fan"),
                                ("sysExtPowerSupplyStatus", "sysExtPowerSupplyIndex", "psu")):
        for lab, v in by_name(rows, metric):
            if v != ARUBA_ACTIVE:
                i = lab.get(index)
                found.append((f"{name}:health:{what}{i}", "urgent", f"{name}: {what} {i} is not active (value {v:.0f})"))
    for _, c in by_name(rows, "wlsxSysExtInternalTemparature"):
        if c >= cfg["temp_urgent_c"]:
            found.append((f"{name}:health:temperature", "urgent", f"{name}: temperature {c:.0f} C (limit {cfg['temp_urgent_c']} C)"))
        elif c >= cfg["temp_warn_c"]:
            found.append((f"{name}:health:temperature", "warn", f"{name}: temperature {c:.0f} C (over {cfg['temp_warn_c']} C)"))
    budget = {lab.get("wlsxPseSlotIndex"): v for lab, v in by_name(rows, "wlsxPseSlotPowerAvailable")}
    for lab, used in by_name(rows, "wlsxPseSlotPowerConsumption"):
        s, total = lab.get("wlsxPseSlotIndex"), budget.get(lab.get("wlsxPseSlotIndex"))
        if total and used / total > cfg["poe_warn_ratio"]:
            found.append((f"{name}:poe:{s}:budget", "warn",
                          f"{name}: PoE draws {used:.0f} W of {total:.0f} W (over {cfg['poe_warn_ratio']:.0%})"))
    # wlsxPsePortIndex is the port's ifIndex: on switch2 the five ports drawing power were the five
    # copper ports up (2026-10-26).
    names = {lab.get("ifIndex"): lab.get("ifName") for lab, _ in by_name(rows, "ifOperStatus")}
    for lab, v in by_name(rows, "wlsxPsePortStatus"):
        if v == ARUBA_POE_HARDWARE_ERROR:
            p = names.get(lab.get("wlsxPsePortIndex")) or f"PoE port {lab.get('wlsxPsePortIndex')}"
            found.append((f"{name}:poe:{p}:hardware-error", "warn", f"{name}: port {p} gives no PoE: hardware error"))
    return found


def firmware(cfg: dict, name: str, scfg: dict, rows: list, prev: dict, t: dt.datetime, release: str | None) -> list:
    """MikroTik: a newer release in its channel, out release_waiting_days; routerboard firmware behind RouterOS."""
    found = []
    running = next((lab.get("mtxrLicVersion") for lab, _ in by_name(rows, "mtxrLicVersion")), None)
    fw = next((lab.get("mtxrFirmwareVersion") for lab, _ in by_name(rows, "mtxrFirmwareVersion")), None)
    fw_up = next((lab.get("mtxrFirmwareUpgradeVersion") for lab, _ in by_name(rows, "mtxrFirmwareUpgradeVersion")), None)
    seen = prev.setdefault("release_seen", {})
    newer = running and release and version_tuple(release) > version_tuple(running)
    if newer:
        first = parse(seen.setdefault(release, iso(t)))
        if t - first >= dt.timedelta(days=cfg["release_waiting_days"]):
            found.append((f"{name}:release", "warn",
                          f"{name}: RouterOS {release} ({scfg.get('routeros_channel')}) is out since at least "
                          f"{first:%Y-%m-%d}; it runs {running}"))
    for r in [r for r in seen if not newer or r != release]:   # applied or superseded: forgotten
        seen.pop(r)
    if fw and fw_up and version_tuple(fw_up) > version_tuple(fw):
        found.append((f"{name}:routerboard", "warn",
                      f"{name}: routerboard firmware {fw}, {fw_up} is installed with RouterOS: upgrade and reboot"))
    return found


def latest_release(cfg: dict, scfg: dict, running: str | None, state: dict, t: dt.datetime) -> str | None:
    """The newest release in the switch's channel (`version epoch` from MikroTik's feed), at most once
    in release_check_hours; the last answer is kept when the feed does not answer."""
    channel = scfg.get("routeros_channel")
    major = (version_tuple(running) or (7,))[0]
    if not channel:
        return None
    url = cfg["release_feed"].format(major=f"a{major}", channel=channel)
    cache = state.setdefault("feeds", {}).setdefault(url, {})
    fetched = parse(cache.get("time"))
    if not fetched or t - fetched >= dt.timedelta(hours=cfg["release_check_hours"]):
        try:
            cache.update(version=fetch(url, timeout=20).split()[0], time=iso(t))
        except (FetchError, IndexError):
            pass
    return cache.get("version")


def confirm(found: list, state: dict, need: int) -> list:
    """Urgent findings only once seen on `need` cycles in a row; warnings at once."""
    seen = state.get("seen", {})
    state["seen"] = {k: seen.get(k, 0) + 1 for k, sev, _ in found if sev == "urgent"}
    return [f for f in found if f[1] != "urgent" or state["seen"][f[0]] >= need]


def hold(new: list, state: dict, t: dt.datetime, hours: float) -> list:
    """Counter warnings kept hold_hours after their last sighting, so the morning digest lists them."""
    kept = state.setdefault("held", {})
    for k, sev, msg in new:
        kept[k] = {"severity": sev, "message": msg, "last": iso(t)}
    for k in [k for k, v in kept.items() if t - (parse(v.get("last")) or t) > dt.timedelta(hours=hours)]:
        kept.pop(k)
    return [(k, v["severity"], v["message"]) for k, v in sorted(kept.items())]


def staged(t: dt.datetime) -> list:
    st = load_json(DATA / "stage.json", None)
    until = parse((st or {}).get("until"))
    if not until or until <= t:
        return []
    return [("staged", "urgent", f"Switch monitor: staged test alert, {st.get('note') or 'no note'} "
                                 f"(until {iso(until)}; not a real failure)")]


def main() -> int:
    with open(CONFIG, "rb") as f:
        cfg = tomllib.load(f)
    t = now()
    state = load_json(DATA / "state.json", {})
    prevs = state.setdefault("switches", {})
    found, held, summary, exporter_down = [], [], {}, None
    for name, scfg in cfg.get("switches", {}).items():
        if not scfg.get("enabled", True):
            summary[name] = {"reachable": None, "note": "not watched yet (enabled = false)"}
            continue
        q = urllib.parse.urlencode({"target": scfg["target"], "module": ",".join(scfg["modules"]), "auth": cfg["auth"]})
        try:
            rows = samples(fetch(f"{cfg['exporter']}/snmp?{q}"))
        except FetchError as e:
            # The exporter answers 500 for a switch it cannot walk; no answer at all is the exporter's
            # failure only if its own page does not answer either (a slow walk can time out alone).
            if not str(e).startswith("HTTP") and not answers(f"{cfg['exporter']}/"):
                exporter_down = str(e)
                break
            found.append((f"{name}:unreachable", "urgent", f"{name} ({scfg['target']}) not answering SNMP: {e}"))
            summary[name] = {"reachable": False}
            continue
        running = next((lab.get("mtxrLicVersion") for lab, _ in by_name(rows, "mtxrLicVersion")), None)
        release = latest_release(cfg, scfg, running, state, t) if scfg.get("kind") == "mikrotik" else None
        f, h, summary[name], prevs[name] = evaluate(cfg, name, scfg, rows, prevs.get(name, {}), t, release)
        found += f
        held += h
    if exporter_down:
        state["exporter_fails"] = state.get("exporter_fails", 0) + 1
        sev = "urgent" if state["exporter_fails"] >= EXPORTER_FAILS_URGENT else "warn"
        found = [("exporter", sev, f"snmp-exporter not answering ({state['exporter_fails']} checks in a row): {exporter_down}")]
    else:
        state["exporter_fails"] = 0
        found = confirm(found, state, cfg["confirm_cycles"]) + hold(held, state, t, cfg["hold_hours"])
    found += staged(t)
    problems = [{"key": k, "severity": s, "message": m} for k, s, m in found]
    write_atomic(DATA / "state.json", json.dumps(state, indent=1, sort_keys=True))
    write_atomic(DATA / "status.json", json.dumps(
        {"time": iso(t), "checker": "switch-monitor", "ok": not exporter_down, "problems": problems,
         "switches": summary}, indent=1, sort_keys=True))
    print(f"{iso(t)} ok={not exporter_down} " + " ".join(
        f"{n}:{'up' if s.get('reachable') else ('off' if s.get('reachable') is None else 'DOWN')}"
        + (f":{s['watched_up']}" if "watched_up" in s else "") for n, s in summary.items())
        + "".join(f"\n  [{p['severity']}] {p['message']}" for p in problems), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
