# Plex (d02 app)

Compose-based Plex Media Server on d02, following the same pattern as TC_datalogger on d03. Uses the [LinuxServer Plex image](https://docs.linuxserver.io/images/docker-plex/).

- **Config**: `${DOCKER_DL}/plex/plexmediaserver` (e.g. `/mnt/docker/plex/plexmediaserver`)
- **Media**: `${DATA1}/media` (e.g. `/mnt/nas/data1/media`)
- **Backups**: `${DOCKER_D1}/plex-<stamp>.tgz`

Optional `.env` in `/mnt/docker/plex/`: `PLEX_CLAIM`, `DOCKER_MODS`, `VERSION` (docker|latest|public).

## Usage

```bash
~/scripts/d02/apps/plex/plex.sh up      # start (default)
~/scripts/d02/apps/plex/plex.sh down
~/scripts/d02/apps/plex/plex.sh refresh # pull latest images and start
~/scripts/d02/apps/plex/plex.sh update  # pull latest images and start (same as refresh)
~/scripts/d02/apps/plex/plex.sh backup
~/scripts/d02/apps/plex/plex.sh logs
```

The legacy script `~/scripts/docker/plex.sh` (docker run) is unchanged and can still be used on other hosts.
