# d01 apps

All d01 apps live here. Each has the same management pattern: a script (`media.sh`, `cloudflared.sh`, …) with **up**, **down**, **logs**, and **pull**.
The internal Caddy is the exception: it comes from `asyla/projects/internal-access` (see below).
Folders deployed here by other repos must be listed in `apps/.gitignore`, or `update_scripts.sh` deletes them.

| App | Script | Notes |
|-----|--------|--------|
| **media** | `~/scripts/d01/apps/media/media.sh` | Sonarr, Radarr, Overseerr, Jackett, Transmission |
| **cloudflared** | `~/scripts/d01/apps/cloudflared/cloudflared.sh` | Cloudflare Tunnel; needs `.env` with TUNNEL_TOKEN |
| **internal-access** | `~/scripts/d01/apps/internal-access/internal-access.sh` | Caddy for split-DNS (ports 80/443). Source: `asyla/projects/internal-access` (`deploy-host.sh d01`), not this repo |
| **calibre** | `~/scripts/d01/apps/calibre/calibre.sh` | Calibre e-book manager (tunnel + Access) |
| **homebridge** | `~/scripts/d01/apps/homebridge/homebridge.sh` | Homebridge (tunnel + Access; host net + proxy) |
| **duplicati** | `~/scripts/d01/apps/duplicati/duplicati.sh` | Duplicati backup (internal proxy, optional tunnel) |
| **breeding-program** | `~/scripts/d01/apps/breeding-program/breeding-program.sh` | Breeding app (tunnel + its own Access app; LAN route via internal-access, trusted as the owner). See its README |
| **gitea-runner** | `~/scripts/d01/apps/gitea-runner/gitea-runner.sh` | Gitea Actions runner, native (systemd); jobs run on the host as `docker`. Instance-wide; labels `asyla`, `d01`, `docker`. Symlink to the shared `docker/gitea-runner/`; see its README |

## Backups

`<app>.sh backup` keeps one rsync mirror per app with `do_rsync_mirror_backup` from
`~/scripts/docker/backup_lib.sh` (the style Plex on d02 uses): `/mnt/nas/data1/docker/<app>/mirror`,
`cloudflared-d01/mirror`, and `media-<service>/mirror` per media service. A nightly run only writes what
changed. History comes from nas01's daily ZFS snapshots of `data1/docker` (00:00, kept 2 weeks, replicated
to the backup pool). `mirror/.backup-status` says `OK <time>` after a successful run.

Restore the latest backup by rsyncing `mirror/` back with the app down. For an earlier day, copy
`/mnt/data1/docker/.zfs/snapshot/auto-YYYY-MM-DD_00-00/<app>/mirror` as **root on nas01**; d01 can list
snapshots over NFS but not read inside them. Full procedure:
[d02/apps/plex/README.md](../../d02/apps/plex/README.md) (Restore).

Until 2026-09-29 these were hardlink snapshot trees (`<YYYYMMDD-HHMMSS>/` plus `latest`, 14 kept) in the same
folders. They are no longer written or pruned; delete them by hand once the mirrors have two weeks of
snapshots (after 2026-10-14).

Start after boot (order: media, then cloudflared, then internal-access, then calibre if desired):

```bash
~/scripts/d01/apps/media/media.sh up
~/scripts/d01/apps/cloudflared/cloudflared.sh up
~/scripts/d01/apps/internal-access/internal-access.sh up
~/scripts/d01/apps/calibre/calibre.sh up
~/scripts/d01/apps/homebridge/homebridge.sh up
~/scripts/d01/apps/duplicati/duplicati.sh up
```
