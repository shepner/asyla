# Internal reverse proxy (d03)

When **split DNS** (e.g. Pi-hole) points `tc-datalogger.asyla.org` to d03's IP, this Caddy container serves that hostname on ports 80 and 443 and proxies to the TC_datalogger dashboard.

- **TLS:** Let's Encrypt via Cloudflare DNS-01. No private CA; set `CF_API_TOKEN` in `.env` and browsers trust certs automatically.
- **Backend:** `http://tc-dashboard:8080` on `tc_datalogger_net`.

## First-time setup (one-time on d03)

1. **Create `.env`** with a Cloudflare API token (Zone:Read, DNS:Edit for asyla.org):
   ```bash
   cd ~/scripts/d03/apps/internal-proxy
   cp .env.example .env
   # Edit .env and set CF_API_TOKEN=your_token
   ```
2. **Start the proxy.** Caddy will obtain Let's Encrypt certs on first request:
   ```bash
   ~/scripts/d03/apps/internal-proxy/internal-proxy.sh up
   ```

## Prerequisites

- TC_datalogger is running (so `tc_datalogger_net` exists).
- Pi-hole (or your DNS) has `tc-datalogger.asyla.org` → d03's IP (e.g. 10.0.0.62).
- Ports 80 and 443 on d03 are free.
- asyla.org is on Cloudflare for DNS-01.

## Run

```bash
~/scripts/d03/apps/internal-proxy/internal-proxy.sh up
```

Same management: `internal-proxy.sh down|restart|logs|pull`.

## Add hostnames

Edit `Caddyfile`: add a block (hostname, `import internal_tls`, `reverse_proxy` to the app). Ensure the hostname exists in Cloudflare DNS. Add the app's network to docker-compose.yml if needed, then restart.

## Optional: private CA (no Cloudflare API)

See `gen-certs.sh`. Use a private CA and trust `certs/ca.crt` on workstations; switch compose to `caddy:latest` and mount certs (see script output).

## Deploy/update

Run `~/update_scripts.sh` on d03 to pull the latest from the repo.
