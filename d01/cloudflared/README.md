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

## Adding Apps

When you add an app that should be exposed via the tunnel:

1. Ensure the app's compose file uses network `d01_internal` (or create an app-specific network and add it to cloudflared's `networks` in docker-compose.yml).
2. Add the app to `apps.yml`.
3. Add the app's network to `services.cloudflared.networks` in docker-compose.yml if not using d01_internal.
4. Configure Public Hostname in Cloudflare Zero Trust dashboard (or via API).
5. Restart cloudflared if you changed docker-compose.yml: `docker compose up -d`.
