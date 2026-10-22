#!/usr/bin/env python3
"""One check of the UniFi consoles through the Site Manager API: status.json and unifi.prom. Read-only (GET).

The unifi-monitor container (compose.yml) runs this every UNIFI_INTERVAL seconds, a fresh process
each time, so a script update from the nightly scripts task applies at the next cycle. Three GETs
a cycle to https://api.ui.com/: v1/hosts (is each console connected), v1/devices (is each device
online, its start time, its firmware), ea/isp-metrics/5m (the WAN of a console with a gateway).

Writes, in UNIFI_DATA (/data, the host's /mnt/docker/unifi-monitor):
  status.json  {"time", "checker", "problems": [{"key", "severity", "message"}], "consoles"}: the
               collection point the host-maintenance monitor reads on each run ([[status]] in its
               config/maintenance.toml); "urgent" mails at once, "warn" goes to the 07:00 digest
  unifi.prom   the same readings in Prometheus text format, for a node exporter's textfile
               collector once theOrg's observability runs on d06
  state.json   what one cycle hands the next: consecutive sightings, firmware first-seen times,
               the device list, API failures
An urgent finding is written only after confirm_cycles cycles in a row (the host-maintenance
monitor then mails at its first sighting). stage.json, written by `unifi-monitor.sh stage`, adds
one urgent problem at once until it expires: the end-to-end test of the alert path.

Key: UNIFI_SITE_MANAGER_API_KEY from the environment (the asyla organization's Site Manager key),
sent as a header, never printed. Config: unifi-monitor.toml beside this file.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import sys
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.ui.com/"
KEY_ENV = "UNIFI_SITE_MANAGER_API_KEY"
DATA = Path(os.environ.get("UNIFI_DATA", "/data"))
CONFIG = Path(os.environ.get("UNIFI_CONFIG", Path(__file__).with_name("unifi-monitor.toml")))
API_FAILS_URGENT = 3   # cycles in a row with a failed GET before it is urgent (a revoked key)


class ApiError(Exception):
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


def get(rel: str, key: str) -> dict:
    req = urllib.request.Request(API + rel, headers={"X-API-KEY": key, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:   # the code only: a body is not ours to print
        raise ApiError(f"GET {rel.split('?')[0]}: HTTP {e.code}") from None
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:
        raise ApiError(f"GET {rel.split('?')[0]}: {type(e).__name__}: {getattr(e, 'reason', e)}") from None


def load_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)


def console_name(host: dict) -> str:
    rs = host.get("reportedState") or {}
    return str(rs.get("name") or rs.get("hostname") or host.get("id", "?"))


def evaluate(cfg: dict, hosts: list, devices: list, isp: list, state: dict, t: dt.datetime):
    """(findings [(key, severity, message)], readings for unifi.prom, summary per console)."""
    found, read, summary = [], {"consoles": [], "devices": [], "wan": []}, {}
    by_name = {console_name(h).lower(): h for h in hosts}
    devs = {d.get("hostId"): d.get("devices") or [] for d in devices}
    known = state.setdefault("devices", {})
    fw_seen = state.setdefault("firmware", {})
    for name, ccfg in cfg.get("consoles", {}).items():
        h = by_name.get(name.lower())
        if not h:
            found.append((f"console:{name}:missing", "urgent", f"UniFi {name}: console not listed in Site Manager"))
            continue
        cstate = (h.get("reportedState") or {}).get("state")
        connected = cstate == "connected"
        read["consoles"].append((name, connected))
        if not connected:
            found.append((f"console:{name}:disconnected", "urgent",
                          f"UniFi {name}: console {cstate or 'unknown'} in Site Manager "
                          f"since {h.get('lastConnectionStateChange') or '?'}"))
        listed = devs.get(h.get("id"), [])
        mem = known.setdefault(name, {})
        offline = 0
        for d in listed:
            mac = d.get("mac") or d.get("id") or d.get("name")
            label = f"{d.get('name') or mac} ({d.get('model') or '?'})"
            mem[mac] = {"name": label, "last_seen": iso(t)}
            online = d.get("status") == "online"
            start = parse(d.get("startupTime"))
            update = bool(d.get("updateAvailable")) or d.get("firmwareStatus") not in (None, "upToDate")
            read["devices"].append((name, d.get("name") or mac, d.get("model") or "", online, start, update))
            if not online:
                offline += 1
                found.append((f"device:{name}:{mac}:offline", "urgent",
                              f"UniFi {name}: {label} is {d.get('status') or 'unknown'}"))
            if start and t - start < dt.timedelta(hours=cfg["reboot_report_hours"]):
                found.append((f"device:{name}:{mac}:restarted", "warn",
                              f"UniFi {name}: {label} restarted at {iso(start)}"))
            fkey = f"{name}/{mac}"
            if update:
                first = parse(fw_seen.setdefault(fkey, iso(t)))
                if t - first >= dt.timedelta(days=cfg["firmware_waiting_days"]):
                    found.append((f"device:{name}:{mac}:firmware", "warn",
                                  f"UniFi {name}: {label} firmware {d.get('version')} has had an update "
                                  f"({d.get('updateAvailable') or d.get('firmwareStatus')}) waiting since {iso(first)}"))
            else:
                fw_seen.pop(fkey, None)
        listed_macs = {d.get("mac") or d.get("id") or d.get("name") for d in listed}
        for mac, m in list(mem.items()):
            if mac in listed_macs:
                continue
            gone = t - (parse(m.get("last_seen")) or t)
            if gone > dt.timedelta(hours=24):
                mem.pop(mac)   # removed on purpose: warned for a day, then forgotten
            else:
                found.append((f"device:{name}:{mac}:gone", "warn",
                              f"UniFi {name}: {m.get('name')} is no longer listed (last seen {m.get('last_seen')})"))
        summary[name] = {"state": cstate, "devices": len(listed), "offline": offline}
        if ccfg.get("wan"):
            found += wan_findings(cfg, name, h.get("id"), isp, read, t)
    expires = parse(cfg.get("key_expires"))
    if expires and expires - t < dt.timedelta(days=30):
        found.append(("key:expiry", "warn", f"UniFi Site Manager API key expires {cfg['key_expires']}: "
                                            "make a new one (asyla org) and store it in OpenBao"))
    return found, read, summary


def wan_findings(cfg: dict, name: str, host_id: str, isp: list, read: dict, t: dt.datetime) -> list:
    w = cfg["wan"]
    periods = [p for s in isp if s.get("hostId") == host_id for p in s.get("periods") or []]
    rows = sorted(((parse(p.get("metricTime")), (p.get("data") or {}).get("wan") or {}) for p in periods),
                  key=lambda r: r[0] or t)
    rows = [r for r in rows if r[0]]
    if not rows:
        return [(f"wan:{name}:none", "warn", f"UniFi {name}: Site Manager has no WAN figures")]
    latest_t, latest = rows[-1]
    read["wan"].append((name, latest_t, latest))
    found = []
    if t - latest_t > dt.timedelta(hours=w["stale_hours"]):
        found.append((f"wan:{name}:stale", "warn", f"UniFi {name}: newest WAN figures are from {iso(latest_t)}"))
    recent = [x for at, x in rows if latest_t - at < dt.timedelta(minutes=w["window_minutes"])]
    down = sum(x.get("downtime") or 0 for x in recent)
    if down:
        found.append((f"wan:{name}:downtime", "warn",
                      f"UniFi {name}: WAN downtime {down} in the hour to {iso(latest_t)}"))
    slow = [x.get("avgLatency") for x in recent if (x.get("avgLatency") or 0) > w["latency_ms"]]
    if len(slow) >= w["periods"]:
        found.append((f"wan:{name}:latency", "warn",
                      f"UniFi {name}: WAN latency above {w['latency_ms']} ms in {len(slow)} of {len(recent)} "
                      f"5-minute periods (up to {max(slow)} ms) in the hour to {iso(latest_t)}"))
    lossy = [x.get("packetLoss") for x in recent if (x.get("packetLoss") or 0) >= w["loss"]]
    if len(lossy) >= w["periods"]:
        found.append((f"wan:{name}:loss", "warn",
                      f"UniFi {name}: WAN packet loss {w['loss']} or more in {len(lossy)} of {len(recent)} "
                      f"5-minute periods (up to {max(lossy)}) in the hour to {iso(latest_t)}"))
    return found


def confirm(found: list, state: dict, need: int) -> list:
    """Urgent findings only once seen on `need` cycles in a row; warnings at once."""
    seen = state.get("seen", {})
    state["seen"] = {k: seen.get(k, 0) + 1 for k, sev, _ in found if sev == "urgent"}
    return [f for f in found if f[1] != "urgent" or state["seen"][f[0]] >= need]


def staged(t: dt.datetime) -> list:
    st = load_json(DATA / "stage.json", None)
    until = parse((st or {}).get("until"))
    if not until or until <= t:
        return []
    return [("staged", "urgent", f"UniFi monitor: staged test alert, {st.get('note') or 'no note'} "
                                 f"(until {iso(until)}; not a real failure)")]


def esc(v) -> str:
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def prom(ok: bool, t: dt.datetime, read: dict, problems: list) -> str:
    out = ["# UniFi Site Manager readings (asyla-hosts d03/apps/unifi-monitor/unifi_check.py)",
           f"unifi_check_success {int(ok)}", f"unifi_check_timestamp_seconds {int(t.timestamp())}"]
    for sev in ("urgent", "warn"):
        out.append(f'unifi_problems{{severity="{sev}"}} {sum(1 for p in problems if p["severity"] == sev)}')
    for name, connected in read["consoles"]:
        out.append(f'unifi_console_connected{{console="{esc(name)}"}} {int(connected)}')
    for name, dev, model, online, start, update in read["devices"]:
        lab = f'console="{esc(name)}",device="{esc(dev)}",model="{esc(model)}"'
        out.append(f"unifi_device_online{{{lab}}} {int(online)}")
        out.append(f"unifi_device_update_available{{{lab}}} {int(update)}")
        if start:
            out.append(f"unifi_device_start_timestamp_seconds{{{lab}}} {int(start.timestamp())}")
    for name, at, x in read["wan"]:
        lab = f'console="{esc(name)}"'
        out.append(f"unifi_wan_metric_timestamp_seconds{{{lab}}} {int(at.timestamp())}")
        for field, metric in (("avgLatency", "avg_latency_ms"), ("maxLatency", "max_latency_ms"),
                              ("packetLoss", "packet_loss"), ("downtime", "downtime"), ("uptime", "uptime")):
            if isinstance(x.get(field), (int, float)):
                out.append(f"unifi_wan_{metric}{{{lab}}} {x[field]}")
    return "\n".join(out) + "\n"


def main() -> int:
    key = os.environ.get(KEY_ENV, "")
    if not key:
        print(f"{KEY_ENV} is not set: the container starts only through unifi-monitor.sh up", file=sys.stderr)
        return 2
    with open(CONFIG, "rb") as f:
        cfg = tomllib.load(f)
    t = now()
    state = load_json(DATA / "state.json", {})
    summary, read = {}, {"consoles": [], "devices": [], "wan": []}
    try:
        hosts = get("v1/hosts?pageSize=100", key).get("data") or []
        devices = get("v1/devices?pageSize=100", key).get("data") or []
        isp = []
        if any(c.get("wan") for c in cfg.get("consoles", {}).values()):
            isp = get("ea/isp-metrics/5m?duration=24h", key).get("data") or []
        state["api_fails"] = 0
        found, read, summary = evaluate(cfg, hosts, devices, isp, state, t)
        found = confirm(found, state, cfg["confirm_cycles"])
        ok = True
    except ApiError as e:
        state["api_fails"] = state.get("api_fails", 0) + 1
        sev = "urgent" if state["api_fails"] >= API_FAILS_URGENT else "warn"
        found = [("api", sev, f"UniFi Site Manager API failing ({state['api_fails']} checks in a row): {e}")]
        ok = False
    found += staged(t)
    problems = [{"key": k, "severity": s, "message": m.replace(key, "<redacted>")} for k, s, m in found]
    write_atomic(DATA / "state.json", json.dumps(state, indent=1, sort_keys=True))
    write_atomic(DATA / "unifi.prom", prom(ok, t, read, problems))
    write_atomic(DATA / "status.json", json.dumps(
        {"time": iso(t), "checker": "unifi-monitor", "ok": ok, "problems": problems, "consoles": summary},
        indent=1, sort_keys=True))
    print(f"{iso(t)} ok={ok} " + " ".join(f"{n}:{s['state']}:{s['devices'] - s['offline']}/{s['devices']}"
                                         for n, s in summary.items())
          + "".join(f"\n  [{p['severity']}] {p['message']}" for p in problems), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
