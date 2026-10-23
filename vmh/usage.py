#!/usr/bin/env python3
"""Guest usage by hour of week, from Proxmox's own RRD history: when are the quiet windows?

Read-only. One SSH to one cluster node lists every guest (/cluster/resources) and prints each one's
month of RRD data (PVE 9: 30-minute averages for 30 days, seen on vmh01 2026-10-23). The workstation
averages them by hour of week in America/Chicago and ranks the quietest windows.

    vmh/usage.py                         # through vmh01 (the cluster's guests on both nodes)
    vmh/usage.py --node vmh03            # a standalone node
    vmh/usage.py --save raw.jsonl        # keep the raw lines; --input raw.jsonl reads them instead
    vmh/usage.py --window 3 --top 5      # the 5 quietest 3-hour windows

Load per hour: guest CPU in cores (cpu x maxcpu, summed over guests) and guest network plus disk
traffic in MB/s. A window's score ranks it by both, each scaled to its own weekly peak.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import defaultdict
from datetime import datetime
from zoneinfo import ZoneInfo

NODES = {"vmh01": "10.0.0.35", "vmh02": "10.0.0.36", "vmh03": "10.0.0.37"}
TZ = ZoneInfo("America/Chicago")
DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

# Runs on the node: one line per guest, "vmid<TAB>node<TAB>type<TAB>name<TAB>status<TAB>rrd json".
REMOTE = r"""
set -eu
pvesh get /cluster/resources --type vm --output-format json \
  | python3 -c 'import json,sys
for r in json.load(sys.stdin):
    if not r.get("template"): print(r["vmid"], r["node"], r["type"], r.get("name") or "-", r["status"])' \
  | while read -r id node type name status; do
      printf '%s\t%s\t%s\t%s\t%s\t' "$id" "$node" "$type" "$name" "$status"
      pvesh get "/nodes/$node/$type/$id/rrddata" --timeframe month --cf AVERAGE --output-format json </dev/null
      echo
  done
"""


def fetch(node: str) -> list[str]:
    out = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", f"root@{NODES[node]}", "sh", "-s"],
        input=REMOTE, capture_output=True, text=True, check=True,
    ).stdout
    return [line for line in out.splitlines() if line.strip()]


def parse(lines: list[str]) -> list[dict]:
    guests = []
    for line in lines:
        vmid, node, kind, name, status, rrd = line.split("\t", 5)
        guests.append({"vmid": int(vmid), "node": node, "type": kind, "name": name, "status": status,
                       "rrd": json.loads(rrd)})
    return guests


def by_hour(guests: list[dict]):
    """hour of week (0 = Mon 00h) -> mean cores and MB/s over all guests; per-guest cores too."""
    cores = defaultdict(lambda: defaultdict(float))     # how -> slot time -> sum over guests
    io = defaultdict(lambda: defaultdict(float))
    per_guest = defaultdict(lambda: defaultdict(list))  # how -> guest -> [cores per point]
    span = [None, None]
    for g in guests:
        for p in g["rrd"]:
            if p.get("cpu") is None:
                continue
            t = datetime.fromtimestamp(p["time"], TZ)
            how = t.weekday() * 24 + t.hour
            c = p["cpu"] * (p.get("maxcpu") or 1)
            b = sum(p.get(k) or 0 for k in ("netin", "netout", "diskread", "diskwrite")) / 1e6
            cores[how][p["time"]] += c
            io[how][p["time"]] += b
            per_guest[how][g["name"]].append(c)
            span[0] = min(span[0] or p["time"], p["time"])
            span[1] = max(span[1] or p["time"], p["time"])
    mean = lambda d: sum(d.values()) / len(d) if d else 0.0  # noqa: E731
    hours = {h: (mean(cores[h]), mean(io[h])) for h in range(168)}
    tops = {h: sorted(((sum(v) / len(v), n) for n, v in per_guest[h].items()), reverse=True)[:3]
            for h in range(168)}
    return hours, tops, span


def windows(hours: dict, width: int):
    """(score, start hour of week, cores, MB/s) for every window of `width` hours, wrapping Sunday."""
    peak_c = max(c for c, _ in hours.values()) or 1
    peak_b = max(b for _, b in hours.values()) or 1
    out = []
    for s in range(168):
        hs = [(s + i) % 168 for i in range(width)]
        c = sum(hours[h][0] for h in hs) / width
        b = sum(hours[h][1] for h in hs) / width
        out.append((c / peak_c + b / peak_b, s, c, b))
    return sorted(out)


def label(how: int) -> str:
    return f"{DAYS[how // 24]} {how % 24:02d}:00"


def report(guests: list[dict], width: int, top: int) -> str:
    hours, tops, span = by_hour(guests)
    if span[0] is None:
        return "no RRD points with data"
    lines = [f"{len(guests)} guests; data {datetime.fromtimestamp(span[0], TZ):%Y-%m-%d} to "
             f"{datetime.fromtimestamp(span[1], TZ):%Y-%m-%d %H:%M %Z}, America/Chicago hours",
             "", "Guest CPU (cores, mean) by hour of week:",
             "      " + "".join(f"{h:>5}" for h in range(0, 24, 1))]
    for d in range(7):
        lines.append(f"{DAYS[d]:<6}" + "".join(f"{hours[d * 24 + h][0]:>5.1f}" for h in range(24)))
    lines += ["", "Guest network + disk (MB/s, mean) by hour of week:",
              "      " + "".join(f"{h:>5}" for h in range(24))]
    for d in range(7):
        lines.append(f"{DAYS[d]:<6}" + "".join(f"{hours[d * 24 + h][1]:>5.1f}" for h in range(24)))
    lines += ["", f"Quietest {width}-hour windows (start, cores, MB/s, busiest guests then):"]
    seen: list[int] = []
    for score, s, c, b in windows(hours, width):
        if any(min((s - o) % 168, (o - s) % 168) < width for o in seen):
            continue                                  # no overlapping windows in the list
        seen.append(s)
        busiest = ", ".join(f"{n} {v:.2f}" for v, n in tops[s])
        lines.append(f"  {label(s)}  {c:5.2f} cores  {b:6.2f} MB/s  ({busiest})")
        if len(seen) == top:
            break
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--node", default="vmh01", choices=sorted(NODES))
    ap.add_argument("--input", help="read raw lines saved by --save instead of SSH")
    ap.add_argument("--save", help="also write the raw lines to this file")
    ap.add_argument("--window", type=int, default=2, help="window width in hours (default 2)")
    ap.add_argument("--top", type=int, default=5)
    a = ap.parse_args(argv)
    if a.input:
        with open(a.input) as f:
            lines = [line for line in f.read().splitlines() if line.strip()]
    else:
        lines = fetch(a.node)
    if a.save:
        with open(a.save, "w") as f:
            f.write("\n".join(lines) + "\n")
    print(report(parse(lines), a.window, a.top))
    return 0


if __name__ == "__main__":
    sys.exit(main())
