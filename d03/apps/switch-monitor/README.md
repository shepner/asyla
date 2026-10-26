# switch-monitor (d03)

Monitoring of the three switches, with a mail when one needs maintenance: **switch1** (MikroTik
CRS326-24S+2Q+, the home core, every 10G path), **switch2** (Aruba S2500-48P, house) and **switch3**
(Aruba S2500-24P, garage). Asked for by the operator 2026-10-25 (asyla backlog item
`2026-10-25-network-switch-monitoring-snmp-exporter-on-d03`): SNMP, all three, and data theOrg can
receive. It follows unifi-monitor's pattern: a container with its own loop writes a status file;
host-maintenance pulls it hourly and mails. theOrg's trends Prometheus scrapes the exporter here once it
can reach d03 (section theOrg below).

- **What runs:** two containers, read-only, no capabilities.
  - `switch-snmp-exporter`: Prometheus's own `prom/snmp-exporter:v0.30.1`, as uid 65534. It walks a
    switch over SNMPv3 when asked (`/snmp?target=...&module=...&auth=asyla_v3`) and answers in
    Prometheus text. Modules: the image's stock `system`, `if_mib` and `mikrotik`, plus `poe_mib`
    from `snmp/poe.yml` (POWER-ETHERNET-MIB, for the Arubas). Not published on the host.
  - `switch-monitor`: `python:3.12-alpine` as the `docker` user. Every 5 minutes (`SWITCH_INTERVAL`)
    it runs `switch_check.py` as a fresh process, so a script update from the nightly scripts task
    applies at the next cycle: one exporter request per enabled switch, and once a day for switch1
    a GET of MikroTik's release feed (`https://upgrade.mikrotik.com/routeros/NEWESTa7.long-term`).
    Nothing it does changes a switch: the SNMP user is read-only.
- **What it writes** in `/mnt/docker/switch-monitor/`:
  - `status.json`: `{time, checker, ok, problems: [{key, severity, message}], switches}`. The
    collection point: host-maintenance's monitor reads it on each run (`[[status]]` in its
    `config/maintenance.toml`). `urgent` mails at once, `warn` goes to the 07:00 digest. Stale or
    unreadable is urgent there.
  - `state.json`: what one cycle hands the next (urgent sightings, each switch's last counters and
    uptime, counter warnings held for a day, release first-seen times, the feed's last answer).
    Rebuilt in one cycle if lost (a release's 7-day wait restarts), so a rebuild does not restore it.
- **What it calls a problem** (thresholds in `switch-monitor.toml`; those marked initial are tuned
  from the first day of readings):

  | Finding | Severity |
  | --- | --- |
  | Switch not answering SNMP (the exporter answers 500, or its walk times out) | urgent, after 2 checks in a row |
  | A watched port (`[switches.NAME.ports]`: uplinks, trunks, nas01, vmh01, vmh02) down while admin up, or not listed | urgent, after 2 checks in a row |
  | MikroTik health: temperature 75 C or more; fan under 1000 RPM; a fan or PSU state not ok | urgent, after 2 checks in a row |
  | PoE supply faulty (pethMainPseOperStatus 3) | urgent, after 2 checks in a row |
  | snmp-exporter not answering | warn, urgent from the 3rd check in a row |
  | Restarted (SNMP uptime under 24 h) | warn |
  | Errors (in + out) over 10/h on any port; discards over 1000/h on a watched port | warn, held 24 h |
  | A watched port went down and up between two checks (MikroTik link-down counter; elsewhere ifLastChange) | warn, held 24 h |
  | Temperature 65 C or more | warn |
  | Optic on a watched port: rx under -10 dBm, tx under -6 dBm, over 70 C, or a transmit fault | warn |
  | switch1: a newer RouterOS in its channel (long-term), first seen 7 days ago or more | warn |
  | switch1: routerboard firmware behind the installed RouterOS | warn |
  | PoE drawing over 80 % of the supply's nominal power | warn |
  | A staged test alert (`stage`) | urgent, at once |

  Rates are taken between two checks of the same boot: after a restart the counters start a new
  baseline, so a reboot never reads as an error burst. "Held 24 h" keeps a counter warning in
  `status.json` for a day after it was last seen, so the morning digest lists one from the night.
  sysUpTime is SNMP TimeTicks, a 32-bit count of hundredths of a second (RFC 2578 section 7.1.8),
  so it wraps after 497 days: a switch up that long reads as restarted for one day.

  switch2 and switch3 are end of life: there is no firmware to track, and no alert repeats it.
- **Not watched yet:** switch2 and switch3 have `enabled = false` until their SNMPv3 user is set and
  a first walk names their uplink ports and health readings (backlog item, step 6).
- **The SNMPv3 login:** user `asyla-monitor`, authPriv (SHA, AES), read-only, allowed from
  10.0.0.0/24 only (a subnet, not d03 alone, so the exporter can move without a switch change); set on switch1 by `tools/switch_snmp.py` in the asyla hub (plan by default, `--apply` after
  the operator's approval). The two passwords, `SWITCH_SNMP_AUTH_PASSWORD` and
  `SWITCH_SNMP_PRIV_PASSWORD`, are in OpenBao (`hubs/asyla/switch-snmp-auth-password`,
  `hubs/asyla/switch-snmp-priv-password`) and in no file here: `build_host.py` resolves them on
  the workstation and sends them over SSH stdin (`start_env` in `d03/host.toml`), and
  `switch-monitor.sh up` refuses to start without them. The exporter expands them into
  `snmp/auth.yml` from its environment (`--config.expand-environment-variables`, snmp_exporter
  v0.30.1 `config/config.go`). The same security trade as unifi-monitor's key: Docker keeps them in
  the exporter's container config on d03, readable by root and by anyone who can run
  `docker inspect` there; what they open is read-only on the switch. The checker never sees them.
- **Start or restart** (from the workstation; also after a password is rotated):

  ```bash
  cd ~/local/asyla && python3 core/tools/credentials.py exec SWITCH_SNMP_AUTH_PASSWORD SWITCH_SNMP_PRIV_PASSWORD -- python3 projects/asyla-hosts/scripts/build_host.py d03 build --only apps --app switch-monitor --apply
  ```

  `update` only pulls the images (like the other d03 apps); a new image applies on the next start
  with the passwords. `down`, `logs`, `verify` and `status` need none.
- **Check:** `switch-monitor.sh verify` (both containers running and healthy or starting,
  `status.json` under 15 minutes old); `switch-monitor.sh status` prints the current problems.
- **Test the alert path:** `switch-monitor.sh stage [MINUTES] [NOTE]` on d03 adds one urgent
  problem to `status.json` until it expires (default 75 minutes, so an hourly monitor run sees it);
  the monitor mails [URGENT], then [RESOLVED] after it expires. `unstage` ends it early.
- **Backup:** `backup` mirrors the data directory to `/mnt/nas/data1/docker/switch-monitor/mirror`
  (the d03 pattern, [../README.md](../README.md)). Nothing in it needs restoring; `restore = false`
  in the host spec.
- **Tests:** `python3 scripts/tests/test_switch_check.py`. The rules for theOrg, from the repo root:
  `docker run --rm -v "$PWD:/r:ro" -w /r --entrypoint promtool prom/prometheus:v2.48.1 test rules scripts/tests/switch_prometheus_rules_test.yml`
  (`check rules d03/apps/switch-monitor/prometheus-rules.yml` for the syntax alone).

## theOrg

The exporter's data goes to theOrg's **trends Prometheus**, the long-retention instance the Emporia
energy data goes to (operator, 2026-10-26: "data logs suitable for promethius should be sent to the
instance that the emporia data is going to"), not its operations one. theOrg's decision
(`decisions/asyla-network-monitoring.md`): asyla picks the exporters, and theOrg scrapes the targets
asyla lists. The trends instance finds targets by Docker label on its own host only, so d03 needs a
static job there: asked in theOrg's backlog (hand-off of 2026-10-26). When it can take it:

1. Publish the exporter: add `ports: ["9116:9116"]` to `snmp-exporter` in `compose.yml`, and allow
   the trends Prometheus's host (the Mini today, d06 later) to d03:9116 only. Nothing secret is served: the exporter's `/config`
   shows the passwords as `<secret>` (read 2026-10-25 against v0.30.1).
2. Hand theOrg this scrape job (the exporter's multi-target pattern; `instance` is the switch):

   ```yaml
   - job_name: asyla-switch-snmp
     scrape_interval: 5m
     scrape_timeout: 2m
     metrics_path: /snmp
     params: {auth: [asyla_v3]}
     static_configs:
       - targets: [192.168.88.1]
         labels: {switch: switch1, __param_module: "system,if_mib,mikrotik"}
       # switch2 10.0.0.41, switch3 10.0.0.42: "system,if_mib,poe_mib", once enabled here
     relabel_configs:
       - {source_labels: [__address__], target_label: __param_target}
       - {source_labels: [__param_target], target_label: instance}
       - {target_label: __address__, replacement: "d03.asyla.org:9116"}
   ```

3. Hand theOrg `prometheus-rules.yml`: the same findings with the same limits, for that job.
4. unifi-monitor's `unifi.prom` and att-monitor's `att.prom` go to the same instance, through a
   textfile exporter on d03 (not built yet).
