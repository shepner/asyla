# Plex (d02 app)

Compose-based Plex Media Server on d02, following the same pattern as TC_datalogger on d03. Uses the [LinuxServer Plex image](https://docs.linuxserver.io/images/docker-plex/).

- **Config**: `${DOCKER_DL}/plex/plexmediaserver` (e.g. `/mnt/docker/plex/plexmediaserver`)
- **Media**: `${DATA1}/media` (e.g. `/mnt/nas/data1/media`)
- **Backups**: `${DOCKER_D1}/plex/<YYYYMMDD-HHMMSS>/` (rsync snapshots; `latest` symlink points at the newest)

Optional `.env` in `/mnt/docker/plex/`: `PLEX_CLAIM`, `DOCKER_MODS`, `VERSION` (docker|latest|public).

## Usage

```bash
~/scripts/d02/apps/plex/plex.sh up       # start
~/scripts/d02/apps/plex/plex.sh down     # stop
~/scripts/d02/apps/plex/plex.sh restart  # down then up
~/scripts/d02/apps/plex/plex.sh refresh  # pull latest images and start
~/scripts/d02/apps/plex/plex.sh backup   # rsync snapshot to the NAS (see below)
~/scripts/d02/apps/plex/plex.sh logs
```

Switches can be combined, e.g. `down backup up` for an offline (guaranteed-clean) snapshot.

## Backups

`backup` makes an **incremental rsync snapshot** of `${DOCKER_DL}/plex/` to `${DOCKER_D1}/plex/<stamp>/`, using `--link-dest=…/plex/latest` so unchanged files are hardlinked from the previous snapshot. After a successful run, `${DOCKER_D1}/plex/latest` is repointed at the new snapshot.

- First run copies everything; subsequent runs typically transfer only megabytes of changes, even though the snapshot directory itself appears full-sized (the unchanged files are hardlinks).
- The following Plex-churn directories are **excluded** (they regenerate themselves and previously blew tgz backups up to hundreds of GB):
  - `…/Plex Media Server/Cache/`
  - `…/Plex Media Server/Codecs/`
  - `…/Plex Media Server/Crash Reports/`
  - `…/Plex Media Server/Diagnostics/`
  - `…/Plex Media Server/Logs/`
  - `…/Plex Media Server/Updates/`
  - `…/Plug-in Support/Caches/`, `Crash Reports/`, `Logs/`
- Retention: the script keeps the most-recent **14** snapshots by default. Override with `BACKUP_KEEP=N plex.sh backup`.
- Plex stays running during backup. SQLite WAL mode tolerates this for daily snapshots. For a guaranteed-consistent snapshot, run `plex.sh down backup up` (≈1 min downtime).
- Safe to schedule as a daily cron job — completes in minutes once the first full snapshot exists.

To restore: rsync (or copy) `${DOCKER_D1}/plex/<stamp>/plexmediaserver/` back to `${DOCKER_DL}/plex/plexmediaserver/` while Plex is stopped.

The legacy script `~/scripts/docker/plex.sh` (docker run) is unchanged and can still be used on other hosts.
