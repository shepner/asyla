# d03 apps

All d03 apps use the same management pattern: a script accepting **up**, **down**, **restart**,
**backup**, **update**, **refresh**, and **logs**. `~/update_all.sh` discovers every directory
under `~/scripts/d03/apps/` and runs `backup` then `update` on each.

**backup** keeps one rsync mirror per app at `/mnt/nas/data1/docker/<App>/mirror` with
`do_rsync_mirror_backup` from `~/scripts/docker/backup_lib.sh` (the style Plex on d02 uses). A nightly
run only writes what changed. History comes from nas01: `data1/docker` is ZFS-snapshotted daily at
00:00, kept 2 weeks, and replicated to the backup pool. `mirror/.backup-status` says `OK <time>` after a
successful run and `IN PROGRESS ...` while one runs (or if it died).

Restore the latest backup by rsyncing `mirror/` back into `/mnt/docker/<App>/` with the app down. For an
earlier day, copy `/mnt/data1/docker/.zfs/snapshot/auto-YYYY-MM-DD_00-00/<App>/mirror` as **root on
nas01**; hosts can list snapshots over NFS but not read inside them. Full procedure:
[d02/apps/plex/README.md](../../d02/apps/plex/README.md) (Restore).

Until 2026-09-29 backups were `<App>-YYYYMMDD-HHMMSS.tgz` archives in `/mnt/nas/data1/docker`. Those are
no longer written or pruned; delete them by hand once the mirrors have two weeks of snapshots
(after 2026-10-14).

**backup** and **update** detach into a screen session only when a person runs them from a terminal.
Anything that waits for the result gets the foreground and the real exit code: host-maintenance
(sets `MAINT_FOREGROUND=1`), `update_all.sh` (already inside screen, `$STY` set), cron, and
non-interactive `ssh d03 '<app>.sh backup'`. Force it by hand with `MAINT_FOREGROUND=1 <app>.sh backup`.

## Owned by this repo

Gitea is not on d03: it moved to d04 on 2026-10-16 (`d04/apps/gitea/`). Its old data stays in
the old d03 (VM 103, `/mnt/docker/Gitea`) as the rollback copy.

Deployed by `update_scripts.sh`, which mirrors `d03/` into `~/scripts/d03/`: files this repo no longer
has are deleted on the host unless a repo `.gitignore` matches them (`*.env` secrets, and the folders in
`apps/.gitignore`).

| App | Script | Notes |
|-----|--------|-------|
| **ms-procedural-backup** | `~/scripts/d03/apps/ms-procedural-backup/ms-procedural-backup.sh` | Nightly pull of ms-procedural's corpus (Mac Mini) into the NAS mirror; backup-only, no containers. agent-commons, which used to run here, was retired 2026-10-08 (theOrg plan ms-procedural-rename.plan.md); its data is archived in `/mnt/nas/data1/docker/agent-commons/mirror` |
| **ms-chronicle-backup** | `~/scripts/d03/apps/ms-chronicle-backup/ms-chronicle-backup.sh` | Nightly pull of ms-chronicle's newest verified backup snapshot (Mac Mini) into `/mnt/nas/data1/docker/ms-chronicle/mirror`; backup-only, no containers, writes only inside that directory. It runs once host-maintenance's `config/maintenance.toml` lists it; needs `.env` (the backup token, delivered by memory-system `deliver-backup-token.sh`) and the mirror directory, which it does not create |
| **breeding-research** | `~/scripts/d03/apps/breeding-research/breeding-research.sh` | Scraper + API; needs `.env` |
| **tc-datalogger** | `~/scripts/d03/apps/tc-datalogger/tc-datalogger.sh` | Torn City API → Doltgres stack (`tc-doltgres`, database `torn_data`, data in `/mnt/docker/tc-datalogger/doltgres`); needs `.env` and `tc_db_password.secret` (host.toml `D03_TC_DATALOGGER_DB_PASSWORD`). `backup` first writes a Dolt backup to `doltgres-backup/` and restores it to a scratch database to check it, then runs `dolt_gc()`, then the mirror (which skips the live `doltgres/`); `gc` and `dbbackup` run those steps alone, `dbup` starts `tc-doltgres` only; `restore` restores the mirror, then `torn_data` from its Dolt backup. Cutover runbook: tc-datalogger `docs/d03-cutover.md` |
| **unifi-monitor** | `~/scripts/d03/apps/unifi-monitor/unifi-monitor.sh` | UniFi Site Manager check every 5 min (DAY, MKE) → `status.json` for host-maintenance, `unifi.prom` for Prometheus; `up` needs the key from OpenBao (build_host.py start_env); see its README |
| **unifi-backup** | `~/scripts/d03/apps/unifi-backup/unifi-backup.sh` | UniFi Network autobackups of DAY and MKE copied hourly to `/mnt/nas/data1/docker/unifi-backup/<console>/`, each checked to open → `status.json` for host-maintenance; `up` needs the key from OpenBao (build_host.py start_env); see its README |
| **att-monitor** | `~/scripts/d03/apps/att-monitor/att-monitor.sh` | AT&T gateway (BGW320) check every 5 min from its status pages (link, WAN address and gateway changes, reboots, optics, outages) → `status.json` for host-maintenance, `att.prom` for Prometheus; no key; see its README |
| **openevse-monitor** | `~/scripts/d03/apps/openevse-monitor/openevse-monitor.sh` | EV charger (OpenEVSE openevse01) check every 5 min from its `/status` (not answering, controller link, error states, fault counters, WiFi restarts) → `status.json` for host-maintenance, `openevse.prom` for theOrg's trends Prometheus; `up` needs the web login from OpenBao (build_host.py start_env); read-only; see its README |
| **switch-monitor** | `~/scripts/d03/apps/switch-monitor/switch-monitor.sh` | Switch check every 5 min over SNMPv3 (snmp_exporter, which theOrg's Prometheus scrapes later; switch1 now, switch2/3 once their SNMP user is set) → `status.json` for host-maintenance; `up` needs the two SNMPv3 passwords from OpenBao (build_host.py start_env); see its README |
| **gitea-runner** | `~/scripts/d03/apps/gitea-runner/gitea-runner.sh` | Gitea Actions runner, native (systemd); jobs run on the host as `docker`. Instance-wide; labels `asyla`, `d03`, `docker`. Symlink to the shared `docker/gitea-runner/`; see its README |

## Owned elsewhere — do not add them here

The edge stack lives in its own repos under `asyla/projects/` and is deployed straight to the
host with `scripts/deploy-host.sh d03` (`rsync --delete`). It lands in the same `apps/` directory
and `update_all.sh` maintains it alongside the rest, but this repo must **not** carry a copy —
two masters writing the same path is how the May 2026 drift happened.
They must be listed in `apps/.gitignore`, or `update_scripts.sh` deletes them.

| App | Source repo | Notes |
|-----|-------------|-------|
| **external-access** | `asyla/projects/external-access` | Cloudflare Tunnel; per-host config in `hosts/d03/`; needs `host.env` |
| **internal-access** | `asyla/projects/internal-access` | Caddy for split-DNS on ports 80/443; per-host config `hosts/d03/host.conf`, `CF_API_TOKEN` in `/mnt/docker/internal-proxy/.env`; `restore` before `up` on a rebuild |

To add a tunnel hostname, edit `hosts/d03/apps.yml` in `asyla/projects/external-access` and run
`external-access.sh genconfig`. The old `d03/scripts/add-tunnel-app.sh` was removed: it wrote a
YAML schema the current generator does not accept.

## Start order

The proxy needs every app network to exist first, so start the apps before the edge. `agent_commons_net` is kept although agent-commons is retired: internal-access and external-access still join it, until the edge drops it.

```bash
~/scripts/d03/apps/breeding-research/breeding-research.sh up
~/scripts/d03/apps/tc-datalogger/tc-datalogger.sh up
~/scripts/d03/apps/internal-access/internal-access.sh up
~/scripts/d03/apps/external-access/external-access.sh up
```
