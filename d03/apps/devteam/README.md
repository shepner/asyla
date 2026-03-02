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

## First-time setup

### 1. OpenBao

```bash
~/scripts/d03/apps/devteam/openbao/openbao.sh up
docker exec -it openbao bao operator init
# Save root token + unseal keys to Bitwarden
docker exec -it openbao bao operator unseal  # repeat 3x with different keys
docker exec -it openbao bao login             # use root token
docker exec -it openbao bao secrets enable -path=secret kv-v2
```

### 2. Plane

Copy `.env.example` to `.env` and set secure passwords before first start:

```bash
cd ~/scripts/d03/apps/devteam/plane
cp .env.example .env
# Edit .env: set POSTGRES_PASSWORD, RABBITMQ_PASSWORD, AWS keys, SECRET_KEY, LIVE_SERVER_SECRET_KEY
~/scripts/d03/apps/devteam/plane/plane.sh up
```

Access `https://plane.asyla.org` to complete initial setup (create admin account).

### 3. Uptime Kuma

```bash
~/scripts/d03/apps/devteam/uptime-kuma/uptime-kuma.sh up
```

Access `https://status.asyla.org` to create admin account and configure monitors.

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
