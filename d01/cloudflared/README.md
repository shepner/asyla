# Cloudflare Tunnel for d01

This directory contains the Cloudflare Tunnel configuration for d01.

**Deploying/updating on d01:** Run `~/update_scripts.sh` on the server (as root or with sudo). It pulls the repo and installs `d01/` into `~/scripts/d01/`, including this `cloudflared/` directory. After update_scripts, ensure `~/scripts/d01/cloudflared/.env` exists with your `TUNNEL_TOKEN` (copy from `.env.example` if needed); `.env` is not in the repo.

## Files

- **docker-compose.yml**: cloudflared service definition
- **apps.yml**: Configuration file listing all apps exposed via tunnel (add entries as you deploy apps)
- **.env.example**: Template for tunnel token (copy to `.env` and add your token)
- **README.md**: This file

## Quick Start

1. **Get tunnel token** from Cloudflare Zero Trust dashboard (create a new tunnel for d01 or use an existing one).
2. **Create .env file** on d01:
   ```bash
   cd ~/scripts/d01/cloudflared
   cp .env.example .env
   # Edit .env and add TUNNEL_TOKEN
   ```
3. **Ensure d01_internal network exists** (created by d01 docker-compose or by first app):
   ```bash
   docker network create d01_internal 2>/dev/null || true
   ```
4. **Start cloudflared**:
   ```bash
   docker compose up -d
   ```
5. **Verify**:
   ```bash
   docker logs cloudflared-d01
   ```

## Automated hostnames (config file) – no manual dashboard entries

To define all hostnames from `apps.yml` so you don’t add each one by hand in the dashboard:

1. **Create the tunnel once** in Zero Trust → Networks → Tunnels → Create tunnel → name it (e.g. `d01`). Choose **Cloudflared** as installer; copy the credentials JSON and save it in this directory as `credentials.json`. Note the tunnel UUID (in the JSON or in the dashboard URL).
2. **Set TUNNEL_ID** in `.env`: `TUNNEL_ID=your-tunnel-uuid`
3. **Generate config** from `apps.yml`: `./generate-config.sh` (writes `config.yml`).
4. **Start with config override**:  
   `docker compose -f docker-compose.yml -f docker-compose.config.yml up -d`
5. When you add or change apps in `apps.yml`, run `./generate-config.sh` again and restart:  
   `docker compose -f docker-compose.yml -f docker-compose.config.yml up -d`

Add `config.yml` and `credentials.json` to `.gitignore` (they contain secrets).

## Adding Apps

When you add an app that should be exposed via the tunnel:

1. Ensure the app’s compose uses a network that cloudflared is attached to (e.g. `media_net`), and add that network to cloudflared’s `networks` in docker-compose.yml if needed.
2. Add the app to `apps.yml` (hostname, service name, port).
3. **If using token mode:** add the Public Hostname in the Cloudflare Zero Trust dashboard.
4. **If using config mode:** run `./generate-config.sh` and restart cloudflared with the config override.
5. Restart cloudflared if you changed docker-compose or config.
