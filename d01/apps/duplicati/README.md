# Duplicati on d01

Duplicati backup runs on d01 and is reachable via the internal proxy (and optionally the cloudflared tunnel). Uses its own network `duplicati_net`.

- **URL:** `https://duplicati.asyla.org` (internal proxy only; no host port published).
- **Image:** [linuxserver/duplicati](https://docs.linuxserver.io/images/docker-duplicati)

## Commands

```bash
~/scripts/d01/apps/duplicati/duplicati.sh up    # start
~/scripts/d01/apps/duplicati/duplicati.sh down  # stop
~/scripts/d01/apps/duplicati/duplicati.sh logs  # follow logs
~/scripts/d01/apps/duplicati/duplicati.sh pull  # pull image and up
```

**Startup:** Duplicati can take 1–2 minutes to open the web UI. Once you see **"Server has started and is listening on *, port 8200"** in the logs, the app is up—logs will stay quiet until backups run or something errors; that’s normal. Use `docker ps` and check **STATUS**: `(healthy)` = UI reachable; `(health: starting)` = still starting; `(unhealthy)` = port check failing. Try opening https://duplicati.asyla.org (or your proxy URL) to confirm the UI loads.

## Volumes

Matches the original `docker/duplicati.sh`:

- `./config` → `/config` — Duplicati config and database
- `${DATA1}/media` → `/source/nas01/data1/media` — backup source (same path as original script)

## First-time setup

1. Ensure **internal-proxy** is running (so `duplicati_net` exists, or run duplicati first to create it).
2. Run `duplicati.sh up`.
3. For split-DNS: point `duplicati.asyla.org` to d01 (e.g. Pi-hole). Use **https://duplicati.asyla.org** (not http); accept the self-signed cert once. If the hostname doesn’t load, on d01 run: `docker exec caddy-internal-d01 cat /etc/caddy/Caddyfile | grep -A2 duplicati` (should show the duplicati block) and `docker network inspect duplicati_net --format '{{range .Containers}}{{.Name}} {{end}}'` (should include `caddy-internal-d01` and `duplicati`). If either is missing, run `update_scripts.sh` then `internal-proxy.sh restart`.
4. Optional: run **setup-tunnel-api.py** in the cloudflared app dir to add tunnel + DNS + Cloudflare Access for `duplicati.asyla.org`.

Set a strong web UI password in Duplicati settings (or use `DUPLICATI__WEBSERVICE_PASSWORD` in the compose).

**SETTINGS_ENCRYPTION_KEY:** The image warns if this is unset (encrypts the settings DB). The original script didn’t use it; the app runs fine without it. To silence the warning and encrypt settings, set the env var in the compose and recreate the container (see LinuxServer docs).
