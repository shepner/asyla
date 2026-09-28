# d01 apps

All d01 apps live here. Each has the same management pattern: a script (`media.sh`, `cloudflared.sh`, …) with **up**, **down**, **logs**, and **pull**.
The internal Caddy is the exception: it comes from `asyla/projects/internal-access` (see below).
Folders deployed here by other repos must be listed in `apps/.gitignore`, or `update_scripts.sh` deletes them.

| App | Script | Notes |
|-----|--------|--------|
| **media** | `~/scripts/d01/apps/media/media.sh` | Sonarr, Radarr, Overseerr, Jackett, Transmission |
| **cloudflared** | `~/scripts/d01/apps/cloudflared/cloudflared.sh` | Cloudflare Tunnel; needs `.env` with TUNNEL_TOKEN |
| **internal-access** | `~/scripts/d01/apps/internal-access/internal-access.sh` | Caddy for split-DNS (ports 80/443). Source: `asyla/projects/internal-access` (`deploy-host.sh d01`), not this repo |
| **calibre** | `~/scripts/d01/apps/calibre/calibre.sh` | Calibre e-book manager (tunnel + Access) |
| **homebridge** | `~/scripts/d01/apps/homebridge/homebridge.sh` | Homebridge (tunnel + Access; host net + proxy) |
| **duplicati** | `~/scripts/d01/apps/duplicati/duplicati.sh` | Duplicati backup (internal proxy, optional tunnel) |
| **breeding-program** | `~/scripts/d01/apps/breeding-program/breeding-program.sh` | Breeding app (tunnel + its own Access app; LAN route via internal-access, trusted as the owner). See its README |

Start after boot (order: media, then cloudflared, then internal-access, then calibre if desired):

```bash
~/scripts/d01/apps/media/media.sh up
~/scripts/d01/apps/cloudflared/cloudflared.sh up
~/scripts/d01/apps/internal-access/internal-access.sh up
~/scripts/d01/apps/calibre/calibre.sh up
~/scripts/d01/apps/homebridge/homebridge.sh up
~/scripts/d01/apps/duplicati/duplicati.sh up
```
