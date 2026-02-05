# Duplicati on d01

Duplicati backup runs on d01 and is reachable via the internal proxy (and optionally the cloudflared tunnel). Uses its own network `duplicati_net`.

- **URL:** `https://duplicati.asyla.org` (internal proxy; add CNAME in split-DNS). Optionally expose via tunnel + Cloudflare Access with `setup-tunnel-api.py`.
- **Image:** [linuxserver/duplicati](https://docs.linuxserver.io/images/docker-duplicati)
- **Port:** 8200 (no host publish; proxy only)

## Commands

```bash
~/scripts/d01/apps/duplicati/duplicati.sh up    # start
~/scripts/d01/apps/duplicati/duplicati.sh down  # stop
~/scripts/d01/apps/duplicati/duplicati.sh logs  # follow logs
~/scripts/d01/apps/duplicati/duplicati.sh pull  # pull image and up
```

## Volumes

- `./config` → Duplicati config and database
- `./backups` → Local backup destination (use `/backups` in Duplicati when configuring local backups)
- `${DATA1}/media` → `/source/media` (example backup source; add more in compose if needed)

## First-time setup

1. Ensure **internal-proxy** is running (so `duplicati_net` exists, or run duplicati first to create it).
2. Run `duplicati.sh up`.
3. For split-DNS: point `duplicati.asyla.org` to d01 (e.g. Pi-hole). Then open `https://duplicati.asyla.org` and accept the self-signed cert once.
4. Optional: run **setup-tunnel-api.py** in the cloudflared app dir to add tunnel + DNS + Cloudflare Access for `duplicati.asyla.org`.

Set a strong web UI password in Duplicati settings (or use `DUPLICATI__WEBSERVICE_PASSWORD` in the compose).
