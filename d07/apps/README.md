# d07 apps

d07 carries the network monitors, moved from d03 (asyla hub backlog
`2026-11-02-hosts-hosts-monitor-vm-d07-on-vmh03`). Each is a copy of d03's; both hosts run them side
by side until d07's are proven and host-maintenance reads them here, then d03's are removed.

All d07 apps use the same management pattern as d03's: a script accepting **up**, **down**,
**restart**, **backup**, **update**, **refresh**, and **logs**. `~/update_all.sh` discovers every
directory under `~/scripts/d07/apps/` and runs `backup` then `update` on each.

**backup** keeps one rsync mirror per app at `/mnt/nas/data1/docker/<App>/mirror` with
`do_rsync_mirror_backup` from `~/scripts/docker/backup_lib.sh` (the style Plex on d02 uses). A nightly
run only writes what changed. History comes from nas01: `data1/docker` is ZFS-snapshotted daily at
00:00, kept 2 weeks, and replicated to the backup pool. `mirror/.backup-status` says `OK <time>` after a
successful run and `IN PROGRESS ...` while one runs (or if it died).

Restore the latest backup by rsyncing `mirror/` back into `/mnt/docker/<App>/` with the app down. For an
earlier day, copy `/mnt/data1/docker/.zfs/snapshot/auto-YYYY-MM-DD_00-00/<App>/mirror` as **root on
nas01**; hosts can list snapshots over NFS but not read inside them. Full procedure:
[d02/apps/plex/README.md](../../d02/apps/plex/README.md) (Restore). None of these five needs it: each has
`restore = false` in `d07/host.toml`, as its state rebuilds in one check.

**backup** and **update** detach into a screen session only when a person runs them from a terminal.
Anything that waits for the result gets the foreground and the real exit code: host-maintenance
(sets `MAINT_FOREGROUND=1`), `update_all.sh` (already inside screen, `$STY` set), cron, and
non-interactive `ssh d07 '<app>.sh backup'`. Force it by hand with `MAINT_FOREGROUND=1 <app>.sh backup`.

## Owned by this repo

Deployed by `update_scripts.sh`, which mirrors `d07/` into `~/scripts/d07/`: files this repo no longer
has are deleted on the host unless a repo `.gitignore` matches them (`*.env` secrets, `__pycache__/`).
No other repo deploys onto d07, so `apps/` has no `.gitignore` of its own.

Every key is resolved from OpenBao on the workstation and sent over SSH stdin by `build_host.py`
(`start_env` in `d07/host.toml`); d07 keeps no secret on disk.

| App | Script | Notes |
|-----|--------|-------|
| **unifi-monitor** | `~/scripts/d07/apps/unifi-monitor/unifi-monitor.sh` | UniFi Site Manager check every 5 min (DAY, MKE) → `status.json` for host-maintenance, `unifi.prom` for Prometheus; `up` needs the key from OpenBao (build_host.py start_env); see its README |
| **unifi-backup** | `~/scripts/d07/apps/unifi-backup/unifi-backup.sh` | UniFi Network autobackups of DAY and MKE copied hourly to `/mnt/nas/data1/docker/unifi-backup/<console>/`, each checked to open → `status.json` for host-maintenance; `up` needs the key from OpenBao (build_host.py start_env); see its README |
| **att-monitor** | `~/scripts/d07/apps/att-monitor/att-monitor.sh` | AT&T gateway (BGW320) check every 5 min from its status pages (link, WAN address and gateway changes, reboots, optics, outages) → `status.json` for host-maintenance, `att.prom` for Prometheus; no key; see its README |
| **openevse-monitor** | `~/scripts/d07/apps/openevse-monitor/openevse-monitor.sh` | EV charger (OpenEVSE openevse01) check every 5 min from its `/status` (not answering, controller link, error states, fault counters; WiFi restarts counted, not reported) → `status.json` for host-maintenance, `openevse.prom` for theOrg's trends Prometheus; `up` needs the web login from OpenBao (build_host.py start_env); read-only; see its README |
| **switch-monitor** | `~/scripts/d07/apps/switch-monitor/switch-monitor.sh` | Switch check every 5 min over SNMPv3 (snmp_exporter, which theOrg's trends Prometheus scrapes through d07:9116, `[[port_proxy]] switch-snmp`; switch1 now, switch2/3 once their SNMP user is set) → `status.json` for host-maintenance; `up` needs the two SNMPv3 passwords from OpenBao (build_host.py start_env); see its README |
