# Internal reverse proxy (d01)

When **split DNS** (e.g. Pi-hole) points app hostnames to d01's IP (10.0.0.60), this Caddy container serves those hostnames on ports 80 and 443 and proxies to the apps. Internal users can use the same URL as external without going through Cloudflare.

- **TLS:** Self-signed certificate (Caddy `tls internal`). Browsers will show a one-time warning; accept to continue.
- **Backend:** Configure in Caddyfile per hostname (e.g. `reverse_proxy service-name:port`).

## Prerequisites

- Pi-hole (or your DNS) has records for app hostnames → d01's IP (10.0.0.60).
- Ports 80 and 443 on d01 are free.

## Run

```bash
~/scripts/d01/apps/internal-proxy/internal-proxy.sh up
```

Or: `cd ~/scripts/d01/apps/internal-proxy && ./start.sh`. Same management as other apps: `internal-proxy.sh down|logs|pull`. Networks are created automatically.

## Add hostnames

Edit `Caddyfile` and add blocks (hostname, `tls internal`, `reverse_proxy` to the app). Restart:

```bash
~/scripts/d01/apps/internal-proxy/internal-proxy.sh up
```

## Deploy/update

Run `~/update_scripts.sh` on d01 to pull the latest from the repo.
