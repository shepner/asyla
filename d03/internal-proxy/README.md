# Internal reverse proxy (d03)

When **split DNS** (e.g. Pi-hole) points `tc-datalogger.asyla.org` to d03’s IP, this Caddy container serves that hostname on ports 80 and 443 and proxies to the TC_datalogger dashboard. Internal users can use the same URL as external (https://tc-datalogger.asyla.org) without going through Cloudflare.

- **TLS:** Self-signed certificate (Caddy `tls internal`). Browsers will show a one-time warning; accept to continue.
- **Backend:** `http://tc-dashboard:8080` on `tc_datalogger_net`.

## Prerequisites

- TC_datalogger is running (so `tc_datalogger_net` exists).
- Pi-hole (or your DNS) has a record: `tc-datalogger.asyla.org` → d03’s IP (e.g. 10.0.0.62).
- Ports 80 and 443 on d03 are free.

## Run

```bash
cd ~/scripts/d03/internal-proxy
docker compose up -d
```

## Add more hostnames

Edit `Caddyfile` and add blocks (same pattern: hostname, `tls internal`, `reverse_proxy` to the app). Restart:

```bash
docker compose restart
```

## Deploy/update

Run `~/update_scripts.sh` on d03 to pull the latest from the repo.
