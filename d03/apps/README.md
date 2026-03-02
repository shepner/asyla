# d03 apps

All d03 apps use the same management pattern: a script with **up**, **down**, **restart**, **logs**, and **pull**.

| App | Script | Notes |
|-----|--------|--------|
| **cloudflared** | `~/scripts/d03/apps/cloudflared/cloudflared.sh` | Cloudflare Tunnel; needs `.env` with TUNNEL_TOKEN |
| **internal-proxy** | `~/scripts/d03/apps/internal-proxy/internal-proxy.sh` | Caddy for split-DNS (ports 80/443); needs `.env` with CF_API_TOKEN for Let's Encrypt |
| **TC_datalogger** | `~/scripts/d03/apps/TC_datalogger/tc_datalogger.sh` | Torn City API → BigQuery stack |
| **gitea** | `~/scripts/d03/apps/gitea/gitea.sh` | Git server; internal only (gitea / gitea.asyla.org via proxy) |
| **devteam/openbao** | `~/scripts/d03/apps/devteam/openbao/openbao.sh` | Secrets management; internal only (vault.asyla.org via proxy) |
| **devteam/plane** | `~/scripts/d03/apps/devteam/plane/plane.sh` | Project management; external (plane.asyla.org via tunnel + access) |
| **devteam/uptime-kuma** | `~/scripts/d03/apps/devteam/uptime-kuma/uptime-kuma.sh` | Monitoring; external (status.asyla.org via tunnel + access) |

Start order (proxy needs all app networks, devteam has internal dependencies):

```bash
~/scripts/d03/apps/TC_datalogger/tc_datalogger.sh up
~/scripts/d03/apps/gitea/gitea.sh up
~/scripts/d03/apps/devteam/openbao/openbao.sh up
~/scripts/d03/apps/devteam/plane/plane.sh up
~/scripts/d03/apps/devteam/uptime-kuma/uptime-kuma.sh up
~/scripts/d03/apps/cloudflared/cloudflared.sh up
~/scripts/d03/apps/internal-proxy/internal-proxy.sh up
```
