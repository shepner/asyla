# Media stack (d01)

Combined Sonarr, Radarr, Overseerr, Jackett, Transmission and where-to-stream on d01. All share `media_net`; access via **cloudflared** (public) or **internal proxy** (split DNS).

## Prerequisites

- `~/scripts/docker/common.env` (DOCKER_DL, DOCKER_UID, DOCKER_GID, LOCAL_TZ, DATA1)
- `/mnt/docker` (local SSD, ext4) and `/mnt/nas/data1/media` (SMB/NFS) mounted
- d01 cloudflared and internal-access running and attached to `media_net`

## Layout

- **Config/data:** `/mnt/docker/sonarr`, `/mnt/docker/radarr`, `/mnt/docker/overseerr`, `/mnt/docker/jackett`, `/mnt/docker/transmission`
- **where-to-stream:** `/mnt/docker/where-to-stream/src` (the source, shipped by `push-where-to-stream.sh`, mounted
  read-only at `/app`) and `/mnt/docker/where-to-stream/data` (JustWatch cache and the page; owned by the docker user)
- **Library:** `/mnt/nas/data1/media` (map TV/Movies inside each app)
- **Downloads:** Transmission writes to `/mnt/docker/transmission/downloads`; Sonarr/Radarr use `.../downloads/complete`

## Run

```bash
~/scripts/d01/apps/media/media.sh up
```

The script automatically sources `~/scripts/docker/common.env` if it exists.

## Access

- **Via Cloudflare:** sonarr.asyla.org, radarr.asyla.org, overseerr.asyla.org, jackett.asyla.org, transmission.asyla.org,
  where-to-stream.asyla.org, all behind the `d01 media` Access application. Add a name with external-access
  `public-hostname.py add` (see `../cloudflared/README.md`, Adding Apps), and list it in `../cloudflared/apps.yml`.
- **Via internal proxy (split DNS):** same hostnames when Pi-hole points them to d01 (10.0.0.60)

## where-to-stream

A personal project (`~/local/personal/projects/where-to-stream`, Gitea `personal/where-to-stream`, private; its
README section "Container (d01 media stack)" is the interface). It reads the Radarr, Sonarr and Overseerr databases
read-only (their config dirs mounted as directories, since the databases are in WAL mode), looks the wishlist up on
JustWatch (outbound HTTPS to apis.justwatch.com), and serves a filterable page on port 8080 that refreshes every
24 hours. Endpoints: `/` the page, `/healthz`, `/status` (JSON: last refresh, result, counts, problems).

No image is built: `python:3.13-alpine` runs `/app/serve.py` as the docker user, read-only, all capabilities
dropped. `refresh`/`update` pull that public image with the others. It has no config, so it is not in
`backup`/`restore`; `/data` is a cache it rebuilds. On a rebuilt host, push the source before `up`, or the
container restarts until it is there.

Update it (after committing in the project):

```bash
~/local/asyla/projects/asyla-hosts/d01/apps/media/push-where-to-stream.sh   # workstation: HEAD -> src/, .git-sha
ssh d01 docker restart where-to-stream                                       # load the new code
ssh d01 docker exec where-to-stream cat /app/.git-sha                        # the commit it runs
```

`media.sh up` only creates the container the first time; it does not reload new source in a running one.
After a restart it serves the last page from `/data` at once and refreshes in the background
(`docker logs where-to-stream`: one line per refresh).

## Commands

- `media.sh up` — create dirs and start stack
- `media.sh down` — stop stack
- `media.sh backup` — tgz of app dirs to NFS backup
- `media.sh logs [service]` — follow logs
- `media.sh refresh` — pull latest images and start
- `media.sh update` — pull latest images and start (same as refresh)
- `media.sh reset-auth sonarr|radarr [--apply]` — forgotten login (no default exists; v4 requires one):
  stops the app, deletes `AuthenticationMethod` from its `config.xml` (copy kept as `config.xml.<stamp>.bak`),
  starts it; its page then asks for a new login. Dry without `--apply`. Servarr FAQ, "Help I have locked myself out".

## References

- [Sonarr](https://docs.linuxserver.io/images/docker-sonarr/) (8989)
- [Radarr](https://docs.linuxserver.io/images/docker-radarr/) (7878)
- [Overseerr](https://docs.linuxserver.io/images/docker-overseerr/) (5055)
- [Jackett](https://docs.linuxserver.io/images/docker-jackett/) (9117)
- [Transmission](https://docs.linuxserver.io/images/docker-transmission/) (9091 WebUI, 51413 peer)
