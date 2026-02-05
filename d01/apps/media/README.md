# Media stack (d01)

Combined Sonarr, Radarr, Overseerr, Jackett, and Transmission on d01. All share `media_net`; access via **cloudflared** (public) or **internal proxy** (split DNS).

## Prerequisites

- `~/scripts/docker/common.env` (DOCKER_DL, DOCKER_UID, DOCKER_GID, LOCAL_TZ, DATA1)
- `/mnt/docker` (iSCSI) and `/mnt/nas/data1/media` (SMB/NFS) mounted
- d01 cloudflared and internal-proxy running and attached to `media_net`

## Layout

- **Config/data:** `/mnt/docker/sonarr`, `/mnt/docker/radarr`, `/mnt/docker/overseerr`, `/mnt/docker/jackett`, `/mnt/docker/transmission`
- **Library:** `/mnt/nas/data1/media` (map TV/Movies inside each app)
- **Downloads:** Transmission writes to `/mnt/docker/transmission/downloads`; Sonarr/Radarr use `.../downloads/complete`

## Run

```bash
source ~/scripts/docker/common.env
~/scripts/d01/apps/media/media.sh up
```

## Access

- **Via Cloudflare:** sonarr.asyla.org, radarr.asyla.org, overseerr.asyla.org, jackett.asyla.org, transmission.asyla.org (configure Public Hostnames in Zero Trust)
- **Via internal proxy (split DNS):** same hostnames when Pi-hole points them to d01 (10.0.0.60)

## Commands

- `media.sh up` — create dirs and start stack
- `media.sh down` — stop stack
- `media.sh backup` — tgz of app dirs to NFS backup
- `media.sh logs [service]` — follow logs
- `media.sh pull` — pull images and up

## References

- [Sonarr](https://docs.linuxserver.io/images/docker-sonarr/) (8989)
- [Radarr](https://docs.linuxserver.io/images/docker-radarr/) (7878)
- [Overseerr](https://docs.linuxserver.io/images/docker-overseerr/) (5055)
- [Jackett](https://docs.linuxserver.io/images/docker-jackett/) (9117)
- [Transmission](https://docs.linuxserver.io/images/docker-transmission/) (9091 WebUI, 51413 peer)
