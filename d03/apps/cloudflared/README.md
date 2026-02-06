# Cloudflare Tunnel for d03

When **split DNS** points app hostnames to d03, applications are exposed via the Cloudflare Tunnel (no port forwarding).

**Deploying/updating on d03:** Run `~/update_scripts.sh` on the server. It installs `d03/` into `~/scripts/d03/`, including `apps/cloudflared/`. After update_scripts, ensure `~/scripts/d03/apps/cloudflared/.env` exists with your `TUNNEL_TOKEN` (copy from `.env.example`); `.env` is not in the repo.

## Files

- **docker-compose.yml**: cloudflared service definition
- **cloudflared.sh**: Management (up/down/logs/pull), same pattern as other d03 apps
- **apps.yml**: Configuration for all apps exposed via tunnel
- **.env.example**: Template for tunnel token

## Quick Start

1. **Get tunnel token** from Cloudflare Zero Trust → Networks → Tunnels
2. **Create .env**:
   ```bash
   cd ~/scripts/d03/apps/cloudflared
   cp .env.example .env
   # Edit .env and add TUNNEL_TOKEN
   ```
3. **Start cloudflared**:
   ```bash
   ~/scripts/d03/apps/cloudflared/cloudflared.sh up
   ```
4. **Verify**:
   ```bash
   docker logs cloudflared-d03
   ```

## Adding Apps

Use the script (from repo or after update_scripts):
```bash
cd ~/scripts/d03/scripts
./add-tunnel-app.sh <app-name> <hostname> <service> <port> [access]
```

Then configure Cloudflare (see script output or [runbook](../../docs/runbook-add-app.md)). Restart cloudflared:
```bash
~/scripts/d03/apps/cloudflared/cloudflared.sh restart
```
Use `cloudflared.sh restart` after adding an app network to the compose file.

## Documentation

- [Cloudflare tunnel setup](../../docs/cloudflare-tunnel.md)
- [Runbook: add app](../../docs/runbook-add-app.md)
- [Runbook: migrate from d01](../../docs/runbook-migrate-from-d01.md)
