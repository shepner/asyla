# d01 apps

All d01 apps live here. Each has the same management pattern: a script (`media.sh`, `cloudflared.sh`, `internal-proxy.sh`) with **up**, **down**, **logs**, and **pull**.

| App | Script | Notes |
|-----|--------|--------|
| **media** | `~/scripts/d01/apps/media/media.sh` | Sonarr, Radarr, Overseerr, Jackett, Transmission |
| **cloudflared** | `~/scripts/d01/apps/cloudflared/cloudflared.sh` | Cloudflare Tunnel; needs `.env` with TUNNEL_TOKEN |
| **internal-proxy** | `~/scripts/d01/apps/internal-proxy/internal-proxy.sh` | Caddy for split-DNS (ports 80/443) |
| **calibre** | `~/scripts/d01/apps/calibre/calibre.sh` | Calibre e-book manager (tunnel + Access) |

Start after boot (order: media, then cloudflared, then internal-proxy, then calibre if desired):

```bash
~/scripts/d01/apps/media/media.sh up
~/scripts/d01/apps/cloudflared/cloudflared.sh up
~/scripts/d01/apps/internal-proxy/internal-proxy.sh up
~/scripts/d01/apps/calibre/calibre.sh up
```
