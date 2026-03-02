# Devteam infrastructure (d03)

Supporting services for the multi-agent development team. All services run on d03 (10.0.0.62).

## Services

| Service | Hostname | Purpose | External |
|---------|----------|---------|----------|
| **OpenBao** | vault.asyla.org | Secrets management (API keys, credentials) | No (LAN only) |
| **Plane** | plane.asyla.org | Project management, ticketing, UAT approvals | Yes (Cloudflare Access) |
| **Uptime Kuma** | status.asyla.org | Process & service monitoring, alerts | Yes (Cloudflare Access) |

## Startup order

OpenBao must start before Plane (secrets bootstrap dependency).

```bash
~/scripts/d03/apps/devteam/openbao/openbao.sh up
~/scripts/d03/apps/devteam/plane/plane.sh up
~/scripts/d03/apps/devteam/uptime-kuma/uptime-kuma.sh up
```

## First-time setup (automated)

Run the deployment orchestrator. It handles everything and prompts when needed:

```bash
~/scripts/d03/apps/devteam/deploy-devteam.sh
```

This single script:
1. Starts OpenBao, initializes + unseals it, prompts you to save keys to Bitwarden
2. Stores your Cursor API key in OpenBao
3. Generates Plane `.env` with secure random passwords, starts Plane, runs setup
4. Starts Uptime Kuma, creates health monitors
5. Restarts internal-proxy and cloudflared
6. Prompts for Pi-hole DNS records
7. Verifies access

### Individual setup scripts (for partial runs)

If you need to re-run a specific step:

- `openbao/init-openbao.sh` — initialize and unseal (idempotent)
- `plane/generate-env.sh` — generate .env from template (skips if .env exists)
- `plane/setup-plane.sh` — create workspace, project, users (idempotent)
- `uptime-kuma/setup-monitors.sh` — create health monitors (idempotent)

## Data locations

| Service | Data path |
|---------|-----------|
| OpenBao | `/mnt/docker/Devteam/OpenBao/file`, `/mnt/docker/Devteam/OpenBao/logs` |
| Plane | `/mnt/docker/Devteam/Plane/{pgdata,redis,rabbitmq,uploads,logs/}` |
| Uptime Kuma | `/mnt/docker/Devteam/UptimeKuma/data` |

## Dependencies

- **internal-proxy** (Caddy): must join `openbao_net`, `plane_net`, `uptimekuma_net` networks
- **cloudflared**: entries for `plane` and `uptime-kuma` in `apps.yml` (OpenBao is internal only)
- **Pi-hole**: A records for `plane.asyla.org`, `vault.asyla.org`, `status.asyla.org` -> 10.0.0.62
