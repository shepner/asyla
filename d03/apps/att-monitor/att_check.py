#!/usr/bin/env python3
"""One check of the home AT&T gateway (BGW320-500) from its status pages: status.json and att.prom. Read-only (GET).

The att-monitor container (compose.yml) runs this every ATT_INTERVAL seconds, a fresh process each
time, so a script update from the nightly scripts task applies at the next cycle. Three GETs a
cycle to the gateway's LAN side (http://192.168.1.254, reached through fw01), pages that need no
login (read 2026-10-25): cgi-bin/sysinfo.ha (software, time since reboot),
cgi-bin/broadbandstatistics.ha (link, WAN addresses, counters), cgi-bin/fiberstat.ha (optics).

Writes, in ATT_DATA (/data, the host's /mnt/docker/att-monitor):
  status.json  {"time", "checker", "ok", "problems": [{"key", "severity", "message"}], "gateway"}:
               the collection point the host-maintenance monitor reads on each run ([[status]] in
               its config/maintenance.toml); "urgent" mails at once, "warn" goes to the 07:00 digest
  att.prom     the same readings in Prometheus text format, for a node exporter's textfile
               collector once theOrg's observability runs on d06
  state.json   what one cycle hands the next: last values, uptime, counters, the open outage,
               recent events
Two kinds of finding:
- a condition (link down, gateway not answering, an optics alarm): written while it lasts, an
  urgent one only after confirm_cycles cycles in a row (the host-maintenance monitor then mails at
  its first sighting);
- an event (an address or setting changed, a reboot, an outage that ended, errors counted): written
  for a while after it happened ([events] in att-monitor.toml), so one monitor run sees it.
While the line is down nothing mails (the monitor runs from gitlab.com), so an outage is kept and
reported as an event once the line is back. stage.json, written by `att-monitor.sh stage`, adds one
urgent problem at once until it expires: the end-to-end test of the alert path.

Times in messages are the configured zone's local time with UTC beside it; the zone data comes from
the host's /usr/share/zoneinfo (compose.yml). Config: att-monitor.toml beside this file.
"""
from __future__ import annotations

import datetime as dt
import html
import json
import os
import re
import sys
import tomllib
import urllib.error
import urllib.request
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

DATA = Path(os.environ.get("ATT_DATA", "/data"))
CONFIG = Path(os.environ.get("ATT_CONFIG", Path(__file__).with_name("att-monitor.toml")))
PAGES = ("sysinfo", "broadbandstatistics", "fiberstat")
# The link is up only when all four read so (2026-10-25: Up, Up, OPERATION (O5), Up).
LINK = (("broadbandstatistics", "Broadband Connection", "Up"), ("broadbandstatistics", "Line State", "Up"),
        ("broadbandstatistics", "PON Link Status", "OPERATION"), ("fiberstat", "Optical WAN Operational Status", "Up"))
COUNTERS = ("Receive Errors", "Transmit Errors", "Receive Drops", "Transmit Drops")
OPTICS = ("Temperature", "Vcc", "Tx Bias", "Tx Power", "Rx Power")
EVENTS_KEPT = 50


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
    """'2026-10-25 13:04 CDT (18:04Z)'; UTC only when the zone is unknown."""
    if not tz:
        return iso(t)
    return f"{t.astimezone(tz):%Y-%m-%d %H:%M %Z} ({t.astimezone(dt.timezone.utc):%H:%MZ})"


def minutes(d: dt.timedelta) -> str:
    m = int(d.total_seconds() // 60)
    return f"{m} min" if m < 120 else f"{m // 60} h {m % 60} min"


def fetch(base: str, page: str, timeout: int) -> str:
    try:
        with urllib.request.urlopen(f"{base}/cgi-bin/{page}.ha", timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raise FetchError(f"GET {page}.ha: HTTP {e.code}") from None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise FetchError(f"GET {page}.ha: {type(e).__name__}: {getattr(e, 'reason', e)}") from None


def text(fragment: str) -> str:
    return " ".join(html.unescape(re.sub(r"(?s)<[^>]+>", " ", fragment)).split())


def rows(page: str) -> dict:
    """{label: value} from each table row with a label cell and a value cell; the first row of a
    label wins (broadbandstatistics lists IPv4 before IPv6 under the same labels: Primary DNS, MTU)."""
    page = re.sub(r"(?is)<(script|style)\b.*?</\1>", "", page)
    out = {}
    for row in re.findall(r"(?is)<tr\b.*?</tr>", page):
        cells = [text(c) for c in re.findall(r"(?is)<t[hd]\b[^>]*>(.*?)</t[hd]>", row)]
        if len(cells) >= 2 and cells[0] and cells[0] not in out:
            out[cells[0]] = cells[1]
    return out


def optics(page: str) -> dict:
    """{metric: {"value", "alarm": [low, high], "warning": [low, high], "limits": [alarm low, alarm high,
    warning low, warning high]}} from fiberstat's '<h1>Rx Power&nbsp;&nbsp;Currently -178</h1>' blocks.
    Units are the page's: tenths of a dBm for power, degrees C for temperature."""
    out = {}
    for m in re.finditer(r"(?is)<h1>(.*?)</h1>(.*?)(?=<h1>|$)", page):
        head = re.match(r"(.+?) Currently (-?\d+)$", text(m.group(1)))
        if not head or head.group(1) not in OPTICS:
            continue
        cells = [(int(f), int(lim)) for f, lim in re.findall(r"(\d+)\s*\(Threshold\s*(-?\d+)\)", m.group(2))[:4]]
        entry = {"value": int(head.group(2))}
        if len(cells) == 4:
            entry |= {"alarm": [cells[0][0], cells[1][0]], "warning": [cells[2][0], cells[3][0]],
                      "limits": [c[1] for c in cells]}
        out[head.group(1)] = entry
    return out


def uptime_seconds(v: str | None) -> int | None:
    """'3848400' (read 2026-10-25: seconds) or D:H:M:S (the page's help text says that form)."""
    if not v:
        return None
    if re.fullmatch(r"\d+", v):
        return int(v)
    parts = re.fullmatch(r"(\d+):(\d+):(\d+):(\d+)", v)
    if parts:
        d, h, m, s = map(int, parts.groups())
        return ((d * 24 + h) * 60 + m) * 60 + s
    return None


def number(v: str | None) -> int | None:
    return int(v) if v and re.fullmatch(r"\d+", v) else None


def read_gateway(pages: dict) -> dict:
    """The readings evaluate() needs, from the three pages' text."""
    info = {p: rows(pages[p]) for p in PAGES}
    flat = {}
    for p in PAGES:
        for k, v in info[p].items():
            flat.setdefault(k, v)
    return {"rows": info, "values": flat, "optics": optics(pages["fiberstat"]),
            "uptime": uptime_seconds(flat.get("Time Since Last Reboot")),
            "counters": {c: number(info["broadbandstatistics"].get(c)) for c in COUNTERS},
            "bytes": {k: number(info["broadbandstatistics"].get(k)) for k in ("Receive Bytes", "Transmit Bytes")}}


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


def evaluate(cfg: dict, gw: dict | None, error: str | None, state: dict, t: dt.datetime):
    """(conditions [(key, severity, message)], down reason or None). Updates state with the events
    this reading shows (changes, reboot, counters, an outage that ended)."""
    tz, found = zone(cfg.get("timezone")), []
    if gw is None:
        found.append(("unreachable", "urgent", f"AT&T gateway: not answering from d03 ({error})"))
        return found, f"gateway not answering from d03 ({error})"
    vals, down = gw["values"], None
    missing = [label for page, label, _ in LINK if label not in gw["rows"][page]]
    if missing:
        found.append(("layout", "warn", "AT&T gateway: status page layout changed, no "
                                        + ", ".join(missing) + " (check att_check.py)"))
    for page, label, want in LINK:
        v = gw["rows"][page].get(label)
        if v is not None and not v.startswith(want):
            found.append((f"link:{slug(label)}", "urgent", f"AT&T gateway: {label} is {v or 'empty'}"))
            down = down or f"{label} {v or 'empty'}"
    o, lim = gw["optics"], cfg["optics"]
    for metric, entry in o.items():
        if any(entry.get("alarm", [])):
            found.append((f"optics:{slug(metric)}:alarm", "urgent",
                          f"AT&T gateway: fiber {metric} alarm, now {entry['value']} (limits {entry.get('limits')})"))
        elif any(entry.get("warning", [])):
            found.append((f"optics:{slug(metric)}:warning", "warn",
                          f"AT&T gateway: fiber {metric} warning, now {entry['value']} (limits {entry.get('limits')})"))
    rx = (o.get("Rx Power") or {}).get("value")
    if rx is not None and rx < lim["rx_power_min"]:
        found.append(("optics:rx-power:low", "warn",
                      f"AT&T gateway: fiber receive power {rx / 10:.1f} dBm, below {lim['rx_power_min'] / 10:.1f} dBm "
                      f"(baseline {lim['rx_power_baseline'] / 10:.1f} dBm)"))
    temp = (o.get("Temperature") or {}).get("value")
    if temp is not None and temp > lim["temperature_max"]:
        found.append(("optics:temperature:high", "warn",
                      f"AT&T gateway: fiber module at {temp} C, above {lim['temperature_max']} C"))
    if down is None and not missing:
        changes(cfg, vals, state, t, tz)
    reboot(gw["uptime"], state, t, tz)
    counters(cfg, gw["counters"], state, t)
    if gw["counters"]:
        found += counter_findings(cfg, state, t, tz)
    return found, down


def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def changes(cfg: dict, vals: dict, state: dict, t: dt.datetime, tz: ZoneInfo | None) -> None:
    """An event for each watched value that differs from the last one seen with the link up. A
    value seen for the first time (a new install, a lost state.json) is only recorded."""
    last = state.setdefault("values", {})
    for label in cfg["watch_changes"]:
        v = vals.get(label)
        if not v:
            continue
        if label in last and last[label] != v:
            add_event(state, f"change:{slug(label)}:{iso(t)}", "change",
                      f"AT&T gateway: {label} changed from {last[label]} to {v} (seen {when(t, tz)})", t)
        last[label] = v


def reboot(up: int | None, state: dict, t: dt.datetime, tz: ZoneInfo | None) -> None:
    """A time since reboot lower than the last one read (5 minutes later it should be higher)."""
    if up is None:
        return
    before = state.get("uptime")
    if isinstance(before, int) and up < before:
        at = t - dt.timedelta(seconds=up)
        add_event(state, f"reboot:{iso(at)}", "reboot",
                  f"AT&T gateway: restarted at about {when(at, tz)} (up {minutes(dt.timedelta(seconds=up))})", t)
    state["uptime"] = up


def counters(cfg: dict, now_c: dict, state: dict, t: dt.datetime) -> None:
    """Each error or drop counter's increase since the last read (a lower count: reset, by a reboot)."""
    last = state.setdefault("counters", {})
    hist = state.setdefault("counter_increases", {})
    for name, v in now_c.items():
        if v is None:
            continue
        before = last.get(name)
        if isinstance(before, int):
            inc = v - before if v >= before else v
            if inc:
                hist.setdefault(name, []).append([iso(t), inc])
        last[name] = v
    keep = t - dt.timedelta(hours=cfg["events"]["warn_hold_hours"])
    for name in list(hist):
        hist[name] = [x for x in hist[name] if (parse_time(x[0]) or t) > keep]
        if not hist[name]:
            hist.pop(name)


def counter_findings(cfg: dict, state: dict, t: dt.datetime, tz: ZoneInfo | None) -> list:
    hours = cfg["events"]["warn_hold_hours"]
    return [(f"counter:{slug(name)}", "warn",
             f"AT&T gateway: {sum(x[1] for x in xs)} WAN {name.lower()} in the last {hours} h "
             f"(newest {when(parse_time(xs[-1][0]) or t, tz)})")
            for name, xs in sorted(state.get("counter_increases", {}).items())]


def outage(cfg: dict, down: str | None, state: dict, t: dt.datetime) -> None:
    """Keep a down spell in state; when it ends after confirm_cycles or more down cycles, an event."""
    tz, cur = zone(cfg.get("timezone")), state.get("outage")
    if down:
        if not cur:
            state["outage"] = {"start": iso(t), "cycles": 1, "why": down}
        else:
            cur["cycles"] += 1
        return
    if cur:
        start = parse_time(cur["start"]) or t
        if cur["cycles"] >= cfg["confirm_cycles"]:
            add_event(state, f"outage:{cur['start']}", "outage",
                      f"AT&T WAN was down from about {when(start, tz)} to {when(t, tz)} "
                      f"({minutes(t - start)}; {cur['why']})", t)
        state.pop("outage", None)


def confirm(found: list, state: dict, need: int) -> list:
    """Urgent conditions only once seen on `need` cycles in a row; warnings at once."""
    seen = state.get("seen", {})
    state["seen"] = {k: seen.get(k, 0) + 1 for k, sev, _ in found if sev == "urgent"}
    return [f for f in found if f[1] != "urgent" or state["seen"][f[0]] >= need]


def staged(t: dt.datetime) -> list:
    st = load_json(DATA / "stage.json", None)
    until = parse_time((st or {}).get("until"))
    if not until or until <= t:
        return []
    return [("staged", "urgent", f"AT&T monitor: staged test alert, {st.get('note') or 'no note'} "
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


def summary(gw: dict | None, down: str | None, state: dict) -> dict:
    s = {"reachable": gw is not None, "link": "down" if down else "up", "outage": state.get("outage"),
         "events": state.get("events", [])[-10:]}
    if gw:
        v, o = gw["values"], gw["optics"]
        s |= {"model": v.get("Model Number"), "software": v.get("Software Version"), "uptime_seconds": gw["uptime"],
              "wan_ipv4": v.get("Broadband IPv4 Address"), "gateway_ipv4": v.get("Gateway IPv4 Address"),
              "wan_ipv6": v.get("Global Unicast IPv6 Address"), "gateway_ipv6": v.get("Default IPv6 Gateway Address"),
              "pon": v.get("PON Link Status"), "speed_mbps": v.get("Current Speed (Mbps)"),
              "rx_power_dbm": o.get("Rx Power", {}).get("value", 0) / 10 if "Rx Power" in o else None,
              "tx_power_dbm": o.get("Tx Power", {}).get("value", 0) / 10 if "Tx Power" in o else None,
              "temperature_c": o.get("Temperature", {}).get("value")}
    return s


def esc(v) -> str:
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def prom(ok: bool, t: dt.datetime, gw: dict | None, down: str | None, problems: list) -> str:
    out = ["# AT&T gateway readings (asyla-hosts d03/apps/att-monitor/att_check.py)",
           f"att_check_success {int(ok)}", f"att_check_timestamp_seconds {int(t.timestamp())}"]
    for sev in ("urgent", "warn"):
        out.append(f'att_problems{{severity="{sev}"}} {sum(1 for p in problems if p["severity"] == sev)}')
    if not gw:
        return "\n".join(out) + "\n"
    v = gw["values"]
    out.append(f"att_link_up {int(not down)}")
    out.append('att_wan_info{' + ",".join(f'{k}="{esc(v.get(label) or "")}"' for k, label in (
        ("ipv4", "Broadband IPv4 Address"), ("gateway_ipv4", "Gateway IPv4 Address"),
        ("ipv6", "Global Unicast IPv6 Address"), ("gateway_ipv6", "Default IPv6 Gateway Address"),
        ("software", "Software Version"))) + "} 1")
    if gw["uptime"] is not None:
        out.append(f"att_uptime_seconds {gw['uptime']}")
    for metric, entry in gw["optics"].items():
        val = entry["value"] / 10 if metric.endswith("Power") else entry["value"]
        out.append(f'att_optics{{metric="{slug(metric)}"}} {val}')
    for name, n in gw["counters"].items():
        if n is not None:
            out.append(f'att_wan_counter_total{{counter="{slug(name)}"}} {n}')
    for name, n in gw["bytes"].items():
        if n is not None:
            out.append(f'att_wan_bytes_total{{direction="{name.split()[0].lower()}"}} {n}')
    return "\n".join(out) + "\n"


def check(cfg: dict, gw: dict | None, error: str | None, state: dict, t: dt.datetime):
    """One cycle on a reading (or a fetch error): (findings, down reason or None); updates state."""
    found, down = evaluate(cfg, gw, error, state, t)
    found = confirm(found, state, cfg["confirm_cycles"])
    outage(cfg, down, state, t)
    return found + event_findings(cfg, state, t) + staged(t), down


def main() -> int:
    with open(CONFIG, "rb") as f:
        cfg = tomllib.load(f)
    t = now()
    state = load_json(DATA / "state.json", {})
    gw, error = None, None
    try:
        gw = read_gateway({p: fetch(cfg["gateway"], p, cfg["timeout_seconds"]) for p in PAGES})
    except FetchError as e:
        error = str(e)
    found, down = check(cfg, gw, error, state, t)
    ok = gw is not None
    problems = [{"key": k, "severity": s, "message": m} for k, s, m in found]
    write_atomic(DATA / "state.json", json.dumps(state, indent=1, sort_keys=True))
    write_atomic(DATA / "att.prom", prom(ok, t, gw, down, problems))
    s = summary(gw, down, state)
    write_atomic(DATA / "status.json", json.dumps(
        {"time": iso(t), "checker": "att-monitor", "ok": ok, "problems": problems, "gateway": s},
        indent=1, sort_keys=True))
    print(f"{iso(t)} ok={ok} link={s['link']}"
          + (f" wan={s['wan_ipv4']} gw={s['gateway_ipv4']} rx={s['rx_power_dbm']}dBm up={s['uptime_seconds']}s" if gw else "")
          + "".join(f"\n  [{p['severity']}] {p['message']}" for p in problems), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
