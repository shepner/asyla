# unifi-monitor (d03)

Early warning of failures at the UniFi consoles **DAY** (the operator's parents' site: Cloud Key G2
Plus, UXG Lite, USW Lite 8 PoE, two AC LR APs) and **MKE** (home), through the UniFi Site Manager
API. It needs no tunnel to either site. Chosen by the operator 2026-10-22 (asyla backlog item
`2026-10-21-network-unifi-site-manager-failure-monitoring`): a container with its own loop writes a
status file as a collection point; host-maintenance pulls it hourly and mails; theOrg's Prometheus
collects the same readings later, once it is production on d06.

- **What runs:** one `python:3.12-alpine` container, read-only, no capabilities, as the `docker`
  user. Every 5 minutes (`UNIFI_INTERVAL`) it runs `unifi_check.py` as a fresh process, so a script
  update from the nightly scripts task applies at the next cycle. Three GETs a cycle to
  `https://api.ui.com/`: `v1/hosts`, `v1/devices`, `ea/isp-metrics/5m` (DAY only). Read-only.
  A fourth, `ea/isp-metrics/1h?duration=7d`, only when DAY's 5-minute series is empty: Site
  Manager served no 5-minute DAY figures after 2026-10-24 07:50Z while the hourly ones went on
  (read 2026-10-25). The WAN messages, `status.json`'s `consoles.DAY.wan` (`5-minute`, `hourly`
  or `none`), the `series` label in `unifi.prom` and the container log say which series was used.
- **What it writes** in `/mnt/docker/unifi-monitor/`:
  - `status.json`: `{time, checker, ok, problems: [{key, severity, message}], consoles}`. The
    collection point: host-maintenance's monitor reads it on each run (`[[status]]` in its
    `config/maintenance.toml`). `urgent` mails at once, `warn` goes to the 07:00 digest. Stale or
    unreadable is urgent there.
  - `unifi.prom`: the same readings in Prometheus text format, for a node exporter's textfile
    collector once theOrg's observability runs on d06.
  - `state.json`: what one cycle hands the next (sightings, firmware first-seen times, the device
    list, API failures). Rebuilt in one cycle if lost, so a rebuild does not restore it.
- **What it calls a problem** (thresholds in `unifi-monitor.toml`, with the measured baseline):

  | Finding | Severity |
  | --- | --- |
  | Console not connected, or not listed in Site Manager | urgent, after 2 checks in a row |
  | Device not online | urgent, after 2 checks in a row |
  | API failing (a revoked key, api.ui.com down) | warn, urgent from the 3rd check in a row |
  | Device restarted in the last 24 h ("during its 03:00 auto-update" when it falls in the console's update hour) | warn |
  | Firmware update waiting 7 days or more | warn |
  | Device no longer listed (warned for a day, then forgotten) | warn |
  | DAY WAN: any downtime; latency over 30 ms or loss 10+ in 3 of the hour's 5-minute periods; figures over 3 h old | warn |
  | DAY WAN from the hourly series (5-minute empty): the same limits in the newest hour; figures over 4 h old | warn |
  | DAY WAN: neither series has figures | warn |
  | Site Manager key within 30 days of expiry (`key_expires`) | warn |
  | A staged test alert (`stage`) | urgent, at once |

  Times in messages are the console's local time with UTC beside it (DAY America/New_York, MKE
  America/Chicago, from v1/hosts), e.g. `2026-10-22 03:30 EDT (07:30Z)`. The zone data is d03's
  `/usr/share/zoneinfo`, mounted read-only; without it times are UTC only.

- **Key:** `UNIFI_SITE_MANAGER_API_KEY`, the asyla organization's Site Manager key (made 2026-10-21
  for a year). It is in no file: `build_host.py` resolves it from OpenBao on the workstation and
  sends it over SSH stdin (`start_env` in `d03/host.toml`), and `unifi-monitor.sh up` refuses to
  start without it. It then sits in the container's environment, so Docker keeps it in the
  container config on d03, readable by root and by anyone who can run `docker inspect` there. The checker sends it as a
  header and never prints it.
- **Start or restart** (from the workstation; also after the key is rotated):

  ```bash
  cd ~/local/asyla && python3 core/tools/credentials.py exec UNIFI_SITE_MANAGER_API_KEY -- python3 projects/asyla-hosts/scripts/build_host.py d03 build --only apps --app unifi-monitor --apply
  ```

  `update` only pulls the image (like the other d03 apps); a new image applies on the next start
  with the key. `down`, `logs`, `verify` and `status` need no key.
- **Check:** `unifi-monitor.sh verify` (container running and healthy or starting, `status.json`
  under 15 minutes old); `unifi-monitor.sh status` prints the current problems.
- **Test the alert path:** `unifi-monitor.sh stage [MINUTES] [NOTE]` on d03 adds one urgent problem
  to `status.json` until it expires (default 75 minutes, so an hourly monitor run sees it); the
  monitor mails [URGENT], then [RESOLVED] after it expires. `unstage` ends it early.
- **Backup:** `backup` mirrors the data directory to `/mnt/nas/data1/docker/unifi-monitor/mirror`
  (the d03 pattern, [../README.md](../README.md)). Nothing in it needs restoring; `restore = false`
  in the host spec.
- **Tests:** `python3 scripts/tests/test_unifi_check.py`.
