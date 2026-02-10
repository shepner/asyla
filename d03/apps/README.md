# d03 apps

All d03 apps use the same management pattern: a script with **up**, **down**, **restart**, **logs**, and **pull**.

| App | Script | Notes |
|-----|--------|--------|
| **cloudflared** | `~/scripts/d03/apps/cloudflared/cloudflared.sh` | Cloudflare Tunnel; needs `.env` with TUNNEL_TOKEN |
| **internal-proxy** | `~/scripts/d03/apps/internal-proxy/internal-proxy.sh` | Caddy for split-DNS (ports 80/443); needs `.env` with CF_API_TOKEN for Let's Encrypt |
| **TC_datalogger** | `~/scripts/d03/apps/TC_datalogger/tc_datalogger.sh` | Torn City API → BigQuery stack |
| **truenas-mcp** | `~/scripts/d03/apps/truenas-mcp/truenas-mcp.sh` | TrueNAS MCP server for Cursor/Claude; needs `.env` with TRUENAS_URL, TRUENAS_API_KEY. **Internal only — do not add to Cloudflare Tunnel.** |

Start after TC_datalogger is running:

```bash
~/scripts/d03/apps/TC_datalogger/tc_datalogger.sh up
~/scripts/d03/apps/cloudflared/cloudflared.sh up
~/scripts/d03/apps/internal-proxy/internal-proxy.sh up
```
