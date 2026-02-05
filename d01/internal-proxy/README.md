# Internal reverse proxy (d01)

When **split DNS** (e.g. Pi-hole) points app hostnames to d01's IP (10.0.0.60), this Caddy container serves those hostnames on ports 80 and 443 and proxies to the apps. Internal users can use the same URL as external without going through Cloudflare.

- **TLS:** Self-signed certificate (Caddy `tls internal`). Browsers will show a one-time warning; accept to continue.
- **Backend:** Configure in Caddyfile per hostname (e.g. `reverse_proxy service-name:port`).

## Prerequisites

- `d01_internal` Docker network exists (create with `docker network create d01_internal` or start an app that uses it).
- Pi-hole (or your DNS) has records for app hostnames → d01's IP (10.0.0.60).
- Ports 80 and 443 on d01 are free.

## Run

```bash
cd ~/scripts/d01/internal-proxy
docker compose up -d
```

## Add hostnames

Edit `Caddyfile` and add blocks (hostname, `tls internal`, `reverse_proxy` to the app). Restart:

```bash
docker compose restart
```

## Deploy/update

Run `~/update_scripts.sh` on d01 to pull the latest from the repo.
