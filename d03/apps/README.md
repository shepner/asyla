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

Deployed by `update_scripts.sh`, which mirrors `d03/` into `~/scripts/d03/`: files this repo no longer
has are deleted on the host unless a repo `.gitignore` matches them (`*.env` secrets, and the folders in
`apps/.gitignore`).

| App | Script | Notes |
|-----|--------|-------|
| **gitea** | `~/scripts/d03/apps/gitea/gitea.sh` | Git server, internal only (gitea.asyla.org via internal-access). `USER_UID`/`USER_GID` are both 1003 to match the migrated data volume |
| **agent-commons** | `~/scripts/d03/apps/agent-commons/agent-commons.sh` | Problem/answer corpus; image pulled from the Gitea registry, overridable via `.env` `AGENT_COMMONS_IMAGE` |
| **breeding-research** | `~/scripts/d03/apps/breeding-research/breeding-research.sh` | Scraper + API; needs `.env` |
| **tc-datalogger** | `~/scripts/d03/apps/tc-datalogger/tc-datalogger.sh` | Torn City API → BigQuery stack; needs `.env` |
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
| **internal-access** | `asyla/projects/internal-access` | Caddy for split-DNS on ports 80/443; needs `host.env` with `CF_API_TOKEN` |

To add a tunnel hostname, edit `hosts/d03/apps.yml` in `asyla/projects/external-access` and run
`external-access.sh genconfig`. The old `d03/scripts/add-tunnel-app.sh` was removed: it wrote a
YAML schema the current generator does not accept.

## Start order

The proxy needs every app network to exist first, so start the apps before the edge.

```bash
~/scripts/d03/apps/gitea/gitea.sh up
~/scripts/d03/apps/agent-commons/agent-commons.sh up
~/scripts/d03/apps/breeding-research/breeding-research.sh up
~/scripts/d03/apps/tc-datalogger/tc-datalogger.sh up
~/scripts/d03/apps/internal-access/internal-access.sh up
~/scripts/d03/apps/external-access/external-access.sh up
```
