# Cloudflare Tunnel for d03

This directory contains the Cloudflare Tunnel configuration for d03.

**Deploying/updating on d03:** Run `~/update_scripts.sh` on the server (as root or with sudo). It pulls the repo and installs `d03/` into `~/scripts/d03/`, including this `cloudflared/` directory. Do not rely on ad-hoc `scp` from a workstation—use the repo as the source of truth. After update_scripts, ensure `~/scripts/d03/cloudflared/.env` exists with your `TUNNEL_TOKEN` (copy from `.env.example` if needed); `.env` is not in the repo.

## Files

- **docker-compose.yml**: cloudflared service definition
- **apps.yml**: Configuration file listing all apps exposed via tunnel
- **.env.example**: Template for tunnel token (copy to `.env` and add your token)
- **README.md**: This file

## Quick Start

1. **Get tunnel token** from Cloudflare Zero Trust dashboard
2. **Create .env file**:
   ```bash
   cp .env.example .env
   # Edit .env and add TUNNEL_TOKEN
   ```
3. **Start cloudflared**:
   ```bash
   docker compose up -d
   ```
4. **Verify**:
   ```bash
   docker logs cloudflared-d03
   ```

## Adding Apps

Use the automated script:
```bash
cd ~/scripts/d03/scripts
./add-tunnel-app.sh <app-name> <hostname> <service> <port> [access]
```

Then configure Cloudflare (see script output or [runbook](../docs/runbook-add-app.md)).

## Configuration

### apps.yml

Single source of truth for all exposed apps. Format:
```yaml
domain: asyla.org

apps:
  - app: app_name
    hostname: subdomain
    service: service_name
    port: 8080
    access: true
```

### docker-compose.yml

Defines cloudflared service and which app networks it connects to. When adding a new app:
1. Add app network to `services.cloudflared.networks`
2. Add network definition in `networks` section

The `add-tunnel-app.sh` script does this automatically.

## Documentation

- Full setup: [../docs/cloudflare-tunnel.md](../docs/cloudflare-tunnel.md)
- Adding apps: [../docs/runbook-add-app.md](../docs/runbook-add-app.md)
- Migrating from d01: [../docs/runbook-migrate-from-d01.md](../docs/runbook-migrate-from-d01.md)
