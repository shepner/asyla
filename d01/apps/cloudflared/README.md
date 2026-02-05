# Cloudflare Tunnel for d01

This directory contains the Cloudflare Tunnel configuration for d01.

**Deploying/updating on d01:** Run `~/update_scripts.sh` on the server (as root or with sudo). It pulls the repo and installs `d01/` into `~/scripts/d01/`, including `apps/cloudflared/`. After update_scripts, ensure `~/scripts/d01/apps/cloudflared/.env` exists with your `TUNNEL_TOKEN` (copy from `.env.example` if needed); `.env` is not in the repo.

## Files

- **docker-compose.yml**: cloudflared service definition
- **apps.yml**: Single source of truth for hostnames and services (used by both API and config-file flows)
- **cloudflared.sh**: Management (up/down/logs/pull), same pattern as apps/media/media.sh
- **setup-tunnel-api.py**: Full automation via Cloudflare API (tunnel, ingress, DNS, Access app for login)
- **generate-config.sh**: Generates local config.yml from apps.yml (for config-file mode)
- **.env.example**: Template for API credentials and tunnel token
- **README.md**: This file

## Full tunnel automation (API) – recommended

One script creates or updates the tunnel, pushes ingress from `apps.yml`, and creates/updates DNS CNAMEs. No manual hostname or DNS setup in the dashboard.

1. **Create an API token** in Cloudflare with:
   - **Account** → Cloudflare Tunnel → Edit
   - **Zone** → DNS → Edit
   - **Account** → Access: Apps and Policies → Edit (so the script can create the Access app for login)
   ([Create token](https://dash.cloudflare.com/profile/api-tokens); see [Create a tunnel (API)](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel-api/).)
2. **From your laptop or CI** (where you have the token), in this repo:
   ```bash
   cd d01/apps/cloudflared
   cp .env.example .env
   # Edit .env: set CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_ZONE_ID, CLOUDFLARE_API_TOKEN
   ./setup-tunnel-api.py
   ```
3. **Copy the printed `TUNNEL_TOKEN=...`** into `~/scripts/d01/apps/cloudflared/.env` on d01 (create .env if needed).
4. **On d01:** `~/scripts/d01/apps/cloudflared/cloudflared.sh up` (or `./start.sh`). The tunnel runs with remote config; no config.yml or credentials.json on the server.

When you add or change apps in `apps.yml`, run `./setup-tunnel-api.py` again (same .env with API credentials); then restart cloudflared on d01 if you like (config is pulled from Cloudflare).

The script also creates or updates a **Cloudflare Access** application for hostnames with `access: true` in `apps.yml`, so visitors must log in (e.g. One-time PIN or Google) before reaching the app.

## Quick Start (manual token)

1. **Get tunnel token** from Cloudflare Zero Trust dashboard (create a new tunnel for d01 or use an existing one).
2. **Create .env file** on d01:
   ```bash
   cd ~/scripts/d01/apps/cloudflared
   cp .env.example .env
   # Edit .env and add TUNNEL_TOKEN
   ```
3. **Start cloudflared** (same management as other apps: up/down/logs/pull):
   ```bash
   ~/scripts/d01/apps/cloudflared/cloudflared.sh up
   ```
   Or: `cd ~/scripts/d01/apps/cloudflared && ./start.sh`
4. **Verify**:
   ```bash
   docker logs cloudflared-d01
   ```

## Automated hostnames (config file) – no manual dashboard entries

To define all hostnames from `apps.yml` so you don’t add each one by hand in the dashboard:

1. **Create the tunnel once** in Zero Trust → Networks → Tunnels → Create tunnel → name it (e.g. `d01`). Choose **Cloudflared** as installer; copy the credentials JSON and save it in this directory as `credentials.json`. Note the tunnel UUID (in the JSON or in the dashboard URL).
2. **Set TUNNEL_ID** in `.env`: `TUNNEL_ID=your-tunnel-uuid`
3. **Generate config** from `apps.yml`: `./generate-config.sh` (writes `config.yml`).
4. **Start** (creates networks automatically, detects config mode):  
   `./start.sh`
5. When you add or change apps in `apps.yml`, run `./generate-config.sh` again and restart:  
   `./start.sh`

Add `config.yml` and `credentials.json` to `.gitignore` (they contain secrets).

## Protecting apps with Cloudflare Access

The tunnel exposes hostnames (e.g. sonarr.asyla.org, radarr.asyla.org); those apps have little or no built-in auth. **If you use the API automation** (above), the script creates an Access application and an “Allow authenticated” policy for hostnames with `access: true` in `apps.yml`. Otherwise, you can add Access manually:

1. In **Zero Trust** → **Access** → **Applications** → **Add an application**.
2. Choose **Self-hosted**.
3. **Application name**: e.g. `d01 media apps`. **Session Duration**: as you prefer (e.g. 24 hours).
4. **Application domain**: Add each hostname you want to protect, e.g.:
   - `sonarr.asyla.org`
   - `radarr.asyla.org`
   - `overseerr.asyla.org`
   - `jackett.asyla.org`
   - `transmission.asyla.org`
   You can create one Access application with multiple hostnames (add each under the same policy) or one application per hostname.
5. **Identity providers**: Enable at least one (e.g. **One-time PIN** for email, or Google/GitHub). Save.
6. **Policy**: Add a policy that defines who can reach the app (e.g. “Allow” for your email, or a group). Save.

After that, visiting any of those URLs from the internet will show the Cloudflare Access login; only after auth does the request go through the tunnel to the service. The `access: true` entries in `apps.yml` indicate which apps are intended to be protected this way.

## Adding Apps

When you add an app that should be exposed via the tunnel:

1. Ensure the app’s compose uses a network that cloudflared is attached to (e.g. `media_net`), and add that network to cloudflared’s `networks` in `apps/cloudflared/docker-compose.yml` if needed.
2. Add the app to `apps.yml` (hostname, service name, port).
3. **If using API automation:** run `./setup-tunnel-api.py` again (from a machine with API credentials); optionally restart cloudflared on d01.
4. **If using manual token mode:** add the Public Hostname and DNS CNAME in the Cloudflare dashboard.
5. **If using config file mode:** run `./generate-config.sh` and restart cloudflared with the config override.
6. Restart cloudflared if you changed docker-compose or config.
