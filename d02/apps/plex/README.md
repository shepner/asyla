# Plex (d02 app)

Compose-based Plex Media Server on d02, following the same pattern as TC_datalogger on d03. Uses the [LinuxServer Plex image](https://docs.linuxserver.io/images/docker-plex/).

- **Config**: `${DOCKER_DL}/plex/plexmediaserver` (e.g. `/mnt/docker/plex/plexmediaserver`)
- **Media**: `${DATA1}/media` (e.g. `/mnt/nas/data1/media`)
- **Backups**: `${DOCKER_D1}/plex/mirror/` (rsync mirror; daily history is nas01's ZFS snapshots of `data1/docker`)

Optional `.env` in `/mnt/docker/plex/`: `PLEX_CLAIM`, `DOCKER_MODS`, `VERSION` (docker|latest|public).

## Usage

```bash
~/scripts/d02/apps/plex/plex.sh up       # start
~/scripts/d02/apps/plex/plex.sh down     # stop
~/scripts/d02/apps/plex/plex.sh restart  # down then up
~/scripts/d02/apps/plex/plex.sh refresh  # pull latest images and start
~/scripts/d02/apps/plex/plex.sh backup   # rsync mirror to the NAS (see below)
~/scripts/d02/apps/plex/plex.sh logs
```

Switches can be combined, e.g. `down backup up` for an offline (guaranteed-clean) backup.

## Backups

`backup` rsyncs `${DOCKER_DL}/plex/` to **one mirror** at `${DOCKER_D1}/plex/mirror/` (`do_rsync_mirror_backup` in `docker/backup_lib.sh`). It keeps no extra copies: day-by-day history is nas01's periodic ZFS snapshot of `data1/docker` (daily at 00:00, kept 2 weeks, replicated to `backup/data1/docker`). Cron runs it daily at 04:00 through `docker/backup_all.sh`.

- A daily run only rewrites files that changed. It still has to check all ~826k entries, but lookups over NFS are sub-millisecond.
- `mirror/.backup-status` reads `OK <time>` after a successful run and `IN PROGRESS since <time>` while one runs (or if it died). A ZFS snapshot showing `IN PROGRESS` caught a partial copy; use the day before.
- A lock stops two backups to the same destination from overlapping, so a manual run started while cron's is going (or the reverse) exits with an error.
- The following Plex-churn directories are **excluded** (they regenerate themselves and previously blew tgz backups up to hundreds of GB):
  - `…/Plex Media Server/Cache/`
  - `…/Plex Media Server/Codecs/`
  - `…/Plex Media Server/Crash Reports/`
  - `…/Plex Media Server/Diagnostics/`
  - `…/Plex Media Server/Logs/`
  - `…/Plex Media Server/Updates/`
  - `…/Plug-in Support/Caches/`, `Crash Reports/`, `Logs/`
- Plex stays running during backup. SQLite WAL mode tolerates this for daily backups. For a guaranteed-consistent copy, run `plex.sh down backup up` (≈1 min downtime).

### Why not hardlink snapshots

Until 2026-09-16 this used `do_rsync_snapshot_backup` (a full `--link-dest` tree per day, 14 kept). Each run recreated ~406k directories and ~390k hardlinks, and pruning deleted a whole tree. Every one of those is a synchronous NFS round trip, ~28 ms on nas01's data1 (a single HDD RAIDZ1 with no SLOG), so each run took ~23 h and overlapped the next day's. Those trees duplicated the ZFS snapshots anyway.

### Restore

Stop Plex first (`plex.sh down`), then `plex.sh up` afterwards.

- **Latest backup:** on d02,
  `rsync -aH --delete /mnt/nas/data1/docker/plex/mirror/plexmediaserver/ /mnt/docker/plex/plexmediaserver/`
- **An earlier day:** snapshots live at `/mnt/data1/docker/.zfs/snapshot/auto-YYYY-MM-DD_00-00/plex/mirror/` on nas01. d02 can list snapshot names over NFS but cannot read inside them, and some files (e.g. `Preferences.xml`) are owner-only, so copy as **root on nas01** (TrueNAS shell) into a scratch dir under the export:
  `cp -a /mnt/data1/docker/.zfs/snapshot/auto-YYYY-MM-DD_00-00/plex/mirror /mnt/data1/docker/plex/restore-YYYY-MM-DD`
  then on d02 rsync `/mnt/nas/data1/docker/plex/restore-YYYY-MM-DD/plexmediaserver/` as above, and delete the scratch dir on nas01 (as root, not over NFS: deletes over NFS are the slow path).
  Check that snapshot's `.backup-status` says `OK` first.

The legacy script `~/scripts/docker/plex.sh` (docker run) is unchanged and can still be used on other hosts.
