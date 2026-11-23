# Media stack (d01)

Combined Sonarr, Radarr, Seerr, Jackett, Transmission, where-to-stream and radarr-reconcile on d01. All share `media_net`; access via **cloudflared** (public) or **internal proxy** (split DNS).

## Prerequisites

- `~/scripts/docker/common.env` (DOCKER_DL, DOCKER_UID, DOCKER_GID, LOCAL_TZ, DATA1)
- `/mnt/docker` (local SSD, ext4) and `/mnt/nas/data1/media` (SMB/NFS) mounted
- d01 cloudflared and internal-access running and attached to `media_net`

## Layout

- **Config/data:** `/mnt/docker/sonarr`, `/mnt/docker/radarr`, `/mnt/docker/seerr`, `/mnt/docker/jackett`, `/mnt/docker/transmission`
- **Overseerr (retired):** `/mnt/docker/overseerr/config` is Overseerr's config as it was at the move to Seerr, kept
  for rollback only (see Seerr below); nothing runs on it
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

- **Via Cloudflare:** sonarr.asyla.org, radarr.asyla.org, overseerr.asyla.org (Seerr), jackett.asyla.org, transmission.asyla.org,
  where-to-stream.asyla.org, all behind the `d01 media` Access application. Add a name with external-access
  `public-hostname.py add` (see `../cloudflared/README.md`, Adding Apps), and list it in `../cloudflared/apps.yml`.
- **Via internal proxy (split DNS):** same hostnames when Pi-hole points them to d01 (10.0.0.60)

## Seerr

Seerr replaced Overseerr ([migration guide](https://docs.seerr.dev/migration-guide/),
[Docker](https://docs.seerr.dev/getting-started/docker/)). Image `ghcr.io/seerr-team/seerr:v3` (the major alias:
fixes arrive with `refresh`, a new major is a deliberate change), config at `/mnt/docker/seerr/config` →
`/app/config`, port 5055. It runs as the docker user (`user:`), not the image's `node` (UID 1000, no account on
d01), so its files belong to the same user as the rest of the stack; `init: true` because the image has no init.

- **The move:** `media.sh migrate-seerr` (dry run), then `--apply`: stops Overseerr, mirrors its config to
  `media-overseerr/mirror` and checks the copy (SQLite integrity, row counts), copies it to `seerr/config`, removes
  the stopped `overseerr` container (host-maintenance counts any stopped container in the project as unhealthy; the
  image stays) and starts Seerr, which migrates the copy on its first start (its `settings.old.json` is the settings
  before that). `up`/`refresh`/`restart` refuse to start while Overseerr has a database and Seerr has none, since
  Seerr on an empty dir sets itself up as a new instance.
- **Hostname:** Seerr carries the network alias `overseerr`, so overseerr.asyla.org (cloudflared and the internal
  Caddy, both to `overseerr:5055`) reaches it unchanged.
- **Rollback:** revert the change in this repo and sync d01; `docker rm -f seerr`; `media.sh up` recreates
  `overseerr` from its image (`lscr.io/linuxserver/overseerr`, v1.35.0-ls158 at the move) on its untouched config.
  Requests made in Seerr after the move are not in Overseerr.
- **Plex:** availability comes from Plex (d02:32400). Seerr matches Plex items by the same GUID rules as Overseerr,
  so items on Plex's legacy agents still have no TMDB id (asyla #1280).

## where-to-stream

A personal project (`~/local/personal/projects/where-to-stream`, Gitea `personal/where-to-stream`, private; its
README section "Container (d01 media stack)" is the interface). It reads the Radarr, Sonarr and Seerr databases
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

## radarr-reconcile

Movies reach the library outside Radarr (AnyStream, then filed by hand into
`Movies/HD|SD/<Letter>/Title (Year)/`), while Radarr keeps each wanted movie's path at an empty folder under
`AnyStream/` or `radarr/`. Radarr's own daily rescan only looks in that folder and never adds a folder it does
not know (root folders are not watched; "Unmapped Folders" stay unmapped until a manual Library Import), so the
movie stays "missing" in Radarr and on where-to-stream. Found 2026-11-22: 13 of 69 wanted movies were on disk.

`radarr_reconcile.py` (container `radarr-reconcile`, once a day, first pass 5 minutes after start) finds, for
each monitored movie with no file, the folder under `/movies/Movies` that holds a video and either names the
movie's TMDB/IMDb id in its `.nfo`, or has the movie's folder name or "Title (Year)" (ignoring case and
punctuation) and no `.nfo` naming another movie. Exactly one such folder, not already another movie's path, or
it skips and says why. Then it sets the movie's path to that folder (`moveFiles=false`: nothing moves) and runs
Radarr's `RescanMovie` for it. Logs (`docker logs radarr-reconcile`): one line per change or skip, one summary
per pass. Unhealthy while the last pass failed (a failed pass retries within the hour).

- **Dry run or apply:** `RECONCILE_APPLY` in `compose.yml` (0 reports only; 1 changes Radarr); 1 since
  2026-11-22 (operator). After changing it, `media.sh up` recreates the container.
- **One pass now:** `media.sh reconcile` (dry run) or `media.sh reconcile --apply`, whatever the service's
  setting.
- **Credential:** none stored. It reads Radarr's API key from Radarr's own `config.xml` (config dir mounted
  read-only) each pass and never prints it; asyla decision `radarr-reconcile-reads-radarrs-own-key`. A new key
  in Radarr is picked up on the next pass.
- **Not covered:** empty folders Radarr left behind (it no longer makes them: "Create empty movie folders" off,
  2026-11-22); movies not in Radarr at all; Seerr, which learns availability from Plex.
- **Tests:** `python3 scripts/tests/test_radarr_reconcile.py` (stand-in Radarr API, temporary library).

## Commands

- `media.sh up` — create dirs and start stack
- `media.sh down` — stop stack
- `media.sh backup` — per-service rsync mirror of each config dir to `$DOCKER_D1/media-<service>/mirror` (history: nas01 ZFS snapshots)
- `media.sh logs [service]` — follow logs
- `media.sh refresh` — pull latest images and start
- `media.sh update` — pull latest images only (no restart); `up` or `restart` applies them
- `media.sh migrate-seerr [--apply]` — the one-time move from Overseerr to Seerr (see Seerr; dry run unless `--apply`)
- `media.sh reconcile [--apply]` — one radarr-reconcile pass now (dry run unless `--apply`)
- `media.sh reset-auth sonarr|radarr [--apply]` — forgotten login (no default exists; v4 requires one):
  stops the app, deletes `AuthenticationMethod` from its `config.xml` (copy kept as `config.xml.<stamp>.bak`),
  starts it; its page then asks for a new login. Dry without `--apply`. Servarr FAQ, "Help I have locked myself out".

## References

- [Sonarr](https://docs.linuxserver.io/images/docker-sonarr/) (8989)
- [Radarr](https://docs.linuxserver.io/images/docker-radarr/) (7878)
- [Seerr](https://docs.seerr.dev/getting-started/docker/) (5055)
- [Jackett](https://docs.linuxserver.io/images/docker-jackett/) (9117)
- [Transmission](https://docs.linuxserver.io/images/docker-transmission/) (9091 WebUI, 51413 peer)
