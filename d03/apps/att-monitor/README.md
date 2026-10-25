# att-monitor (d03)

Watches the home AT&T gateway (HUMAX BGW320-500, fiber, in front of fw01) from its status pages.
Asked for by the operator 2026-10-25 (asyla backlog item `2026-10-25-network-att-gateway-bgw320-monitoring`),
after the WAN gateway fw01 routes to changed on 2026-10-20 with nothing changed on our side. It
follows unifi-monitor beside it: a container with its own loop writes a status file as a collection
point; host-maintenance pulls it and mails; theOrg's Prometheus collects the same readings later.

- **What runs:** one `python:3.12-alpine` container, read-only, no capabilities, as the `docker`
  user. Every 5 minutes (`ATT_INTERVAL`) it runs `att_check.py` as a fresh process, so a script
  update from the nightly scripts task applies at the next cycle. Three GETs a cycle to
  `http://192.168.1.254/cgi-bin/` (`sysinfo.ha`, `broadbandstatistics.ha`, `fiberstat.ha`), pages
  that need no login. Read-only. **No secret**: the access code (`ATT_MODEM_PASSWORD`) is not used.
- **What it writes** in `/mnt/docker/att-monitor/`:
  - `status.json`: `{time, checker, ok, problems: [{key, severity, message}], gateway}`. The
    collection point: host-maintenance's monitor reads it on each run (`[[status]]` in its
    `config/maintenance.toml`). `urgent` mails at once, `warn` goes to the 07:00 digest. Stale or
    unreadable is urgent there. `gateway` holds the current readings (WAN and gateway addresses,
    software, uptime, optics), the open outage and the last 10 events.
  - `att.prom`: the same readings in Prometheus text format (`att_*`), for a node exporter's
    textfile collector once theOrg's observability runs on d06.
  - `state.json`: what one cycle hands the next (last values, uptime, counters, the open outage,
    events). Rebuilt in one cycle if lost (the first values are then recorded, not reported).
- **What it calls a problem** (limits in `att-monitor.toml`, with the 2026-10-25 readings):

  | Finding | Severity |
  | --- | --- |
  | Gateway not answering from d03 | urgent, after 2 checks in a row |
  | Broadband Connection or Line State not `Up`, PON Link Status not `OPERATION`, Optical WAN not `Up` | urgent, after 2 checks in a row |
  | The fiber module's own alarm flag (temperature, voltage, bias, Tx or Rx power) | urgent, after 2 checks in a row |
  | The fiber module's own warning flag | warn |
  | Rx power below -21.0 dBm (baseline -17.8) or module above 70 C | warn |
  | A watched value changed: WAN IPv4, gateway IPv4, IPv6 address or gateway, DNS, software, speed, source | urgent, once (held 75 min) |
  | An outage that ended (down 2 checks or more): its start, end and cause | urgent, once, when the line is back |
  | The gateway restarted (time since reboot went down) | warn, for 24 h |
  | WAN receive or transmit errors or drops counted | warn, the 24 h total |
  | A status page lost a row the checker needs (a firmware update changed the layout) | warn |
  | A staged test alert (`stage`) | urgent, at once |

- **What it cannot do:** mail during a WAN outage. The host-maintenance monitor runs from
  gitlab.com and mail leaves over the same line, so an outage is reported when the line is back.
  A live alert for a total outage is the external heartbeat's job (asyla backlog
  `2026-10-20-hosts-nas-heartbeat-monitoring`). Loss or latency past the gateway (the line up, the
  internet not) is fw01's gateway monitoring (dpinger; asyla backlog item on fw01). A down spell
  shorter than one 5-minute check can be missed; a reboot still shows by the uptime.
- **Start or restart:** no key, so from the workstation:

  ```bash
  cd ~/local/asyla && python3 projects/asyla-hosts/scripts/build_host.py d03 build --only apps --app att-monitor --apply
  ```

  or `att-monitor.sh up` on d03. The apps task refreshes it when a new image is pulled.
- **Check:** `att-monitor.sh verify` (container running and healthy or starting, `status.json`
  under 15 minutes old); `att-monitor.sh status` prints the current problems and recent events.
- **Test the alert path:** `att-monitor.sh stage [MINUTES] [NOTE]` on d03 adds one urgent problem
  to `status.json` until it expires (default 75 minutes, so an hourly monitor run sees it); the
  monitor mails [URGENT], then [RESOLVED] after it expires. `unstage` ends it early.
- **Backup:** `backup` mirrors the data directory to `/mnt/nas/data1/docker/att-monitor/mirror`
  (the d03 pattern, [../README.md](../README.md)). Nothing in it needs restoring; `restore = false`
  in the host spec.
- **Tests:** `python3 scripts/tests/test_att_check.py`.
