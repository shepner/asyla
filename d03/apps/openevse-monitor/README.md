# openevse-monitor (d03)

Watches the garage EV charger (OpenEVSE `openevse01`, 10.0.0.87; WiFi gateway firmware 2.9.1,
controller 5.0.1) from its `/status`. Asked for by the operator 2026-10-26 (asyla backlog item
`2026-10-25-network-openevse-charger-login-monitoring-and-remote-recovery`, step 3), because the
charger sometimes gets stuck and needs a power cycle. It follows att-monitor beside it: a container
with its own loop writes a status file as a collection point; host-maintenance pulls it and mails;
theOrg's trends Prometheus collects the same readings.

- **What runs:** one `python:3.12-alpine` container, read-only, no capabilities, as the `docker`
  user. Every 5 minutes (`OPENEVSE_INTERVAL`) it runs `openevse_check.py` as a fresh process, so a
  script update from the nightly scripts task applies at the next cycle. One `GET /status` a cycle,
  with the charger's web login (HTTP Digest), up to 3 tries 30 s each, since the charger has always
  been slow (operator, 2026-10-26). **Read-only:** it never sends the charger a command; recovery
  (`$FR`, `/restart`) stays a person's decision (backlog item, step 4).
- **What it writes** in `/mnt/docker/openevse-monitor/`:
  - `status.json`: `{time, checker, ok, problems: [{key, severity, message}], charger}`. The
    collection point: host-maintenance's monitor reads it on each run (`[[status]]` in its
    `config/maintenance.toml`). `urgent` mails at once, `warn` goes to the 07:00 digest. Stale or
    unreadable is urgent there. `charger` holds the current readings (state, amps, energy,
    temperatures, fault counters, RSSI, free heap, poll time), the open outage, the last 10 events and
    the WiFi restart count (`wifi_restarts`, `wifi_last_restart`).
  - `openevse.prom`: the same readings in Prometheus text format (`openevse_*`), for theOrg's trends
    Prometheus (theOrg backlog `2026-10-25-observability-asyla-openevse-charger-openevse01-into-the-trends-prometheus`),
    served with d03's other `.prom` files once that path exists.
  - `state.json`: what one cycle hands the next (fault counters, the RAPI count, confirm counts, the
    open outage, events). Rebuilt in one cycle if lost (the first values are then recorded, not reported).
- **Time:** the controller's clock battery is dead and stays dead (operator, 2026-10-26), so no
  reading uses the charger's time; all carry the checker's UTC.
- **What it calls a problem** (limits in `openevse-monitor.toml`, with the 2026-10-26 readings):

  | Finding | Severity |
  | --- | --- |
  | Charger not answering from d03 | urgent, after 3 checks in a row (15 min; it drops packets) |
  | The monitor's login refused (HTTP 401) or not given to the container | urgent, after 3 checks in a row |
  | The WiFi module answers but its link to the controller is down (`rapi_connected` 0) | urgent, after 2 checks in a row |
  | Controller in an error state (4-17: vent required, GFCI, no ground, stuck relay, over temperature, ...) | urgent, after 2 checks in a row |
  | A fault counter went above its highest seen (GFCI, no ground, stuck relay; 0, 2, 0 on 2026-10-26; a lower reading, as the 0s right after a WiFi restart, is ignored) | urgent, once (held 75 min) |
  | Charging disabled at the charger (state 255), or an unknown state | warn |
  | A not-answering spell that ended (3 checks or more): its start, end and cause | warn, for 24 h |
  | WiFi signal below -75 dBm (baseline -60) | warn |
  | `/status` without a `state` (a firmware change) | warn |
  | A staged test alert (`stage`) | urgent, at once |
  | The WiFi module restarted (its RAPI count `comm_sent` went down) | none: counted (`openevse_wifi_restarts_total`) |
  | Free heap low | none: recorded (`openevse_free_heap_bytes`) |

  The WiFi module runs out of memory and restarts about every 30 minutes on its own (2026-10-26:
  free heap 18 KB down to 6 KB, then a restart, the controller unaffected; the cycle predates this
  monitor, by its RAPI count). A warning for each would be about 46 a day, so the operator asked
  for none on restarts or free memory (2026-10-26); the count and the heap stay in the trends.

  State codes: open_evse v5.0.1 `firmware/open_evse/J1772EvseController.h` (1-4 vehicle states
  A-D, 5-11 errors, 254 sleeping, 255 disabled; 12-17 are later firmware's errors). Units: 2.9.1
  `src/web_server.cpp` and `src/emonesp.h` (`amp` in mA, `temp1..3` in tenths of a degree C, a
  missing sensor `false`); read live 2026-10-26: `amp=0`, `temp1=272`, `temp2=False`.
- **What it cannot do:** see the stuck state's own signature. It is not described yet (backlog
  item, step 2: a snapshot before the next power cycle); the controller-link and not-answering
  checks are the guesses for it. Once a wedge is read, add its signature here.
- **Start or restart** (from the workstation; also after the login changes):

  ```bash
  cd ~/local/asyla && python3 core/tools/credentials.py exec OPENEVSE_WWW_USER OPENEVSE_WWW_PASSWORD -- python3 projects/asyla-hosts/scripts/build_host.py d03 build --only apps --app openevse-monitor --apply
  ```

  `build_host.py` sends the two values over SSH stdin (`start_env` in `d03/host.toml`), and
  `openevse-monitor.sh up` refuses to start without them. They then sit in the container's
  environment, so Docker keeps them in the container's config on d03 (as for unifi-monitor's key).
  `down`, `logs`, `verify` and `status` need no login.
- **Check:** `openevse-monitor.sh verify` (container running and healthy or starting, `status.json`
  under 15 minutes old); `openevse-monitor.sh status` prints the current problems and recent events.
- **Test the alert path:** `openevse-monitor.sh stage [MINUTES] [NOTE]` on d03 adds one urgent
  problem to `status.json` until it expires (default 75 minutes, so an hourly monitor run sees it);
  the monitor mails [URGENT], then [RESOLVED] after it expires. `unstage` ends it early.
- **Backup:** `backup` mirrors the data directory to `/mnt/nas/data1/docker/openevse-monitor/mirror`
  (the d03 pattern, [../README.md](../README.md)). Nothing in it needs restoring; `restore = false`
  in the host spec.
- **Tests:** `python3 scripts/tests/test_openevse_check.py`.
